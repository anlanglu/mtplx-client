// MTPLX media generation via MiniMax H3-Image / H3-Video, run on the host.
//
// Registers two agent-callable tools, `generate_image` and `generate_video`,
// that call the host's job services over the tailnet:
//
//   POST <base>/image|video/v1/jobs          -> submit, job id + queue pos
//   GET  <base>/image|video/v1/jobs/<id>     -> poll status (position too)
//   GET  <base>/image/v1/jobs/<id>/image     -> finished PNG
//   GET  <base>/video/v1/jobs/<id>/video     -> finished MP4
//
// The host serialises jobs behind one MLX lock, so any number of clients can
// fire at once; each one sees its queue position here through
// context.progress; files land where the user asks (defaults
// ~/.mtplx/h3-image-mlx/out and ~/.mtplx/h3-video-mlx/out on this machine).
// No local model, no Apple Silicon needed — this works the same on Windows.
//
// H3-Video jobs are long: one 5-second clip takes roughly 2.2-2.5 hours on
// the host and only 5-second clips are offered, so longer requests would
// exceed the host's 6-hour per-job timeout. Do not fire video jobs
// casually; confirm with the user before submitting one.
//
// The MTPLX installer replaces __MTPLX_BASE__ (host URL, e.g.
// https://<host>.<tailnet>.ts.net) and __MTPLX_KEY__ (your mtr_ key) when
// it writes this file. With placeholders left in place the tools still
// register, but return a clear "not installed" message.
import { existsSync } from "node:fs";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { Plugin } from "@opencode/plugin";

const BASE = "__MTPLX_BASE__"; // e.g. https://host.tailnet.ts.net
const KEY = "__MTPLX_KEY__";   // your mtr_... API key
const IMG_API = `${BASE}/image`;
const VID_API = `${BASE}/video`;

const IMG_OUT_DIR = path.join(os.homedir(), ".mtplx", "h3-image-mlx", "out");
const VID_OUT_DIR = path.join(os.homedir(), ".mtplx", "h3-video-mlx", "out");

const IMG_POLL_MS = 5000;
const IMG_TIMEOUT_MS = 60 * 60 * 1000; // queue + generation combined
const VID_POLL_MS = 60000;              // video jobs run for hours
const VID_TIMEOUT_MS = 7 * 60 * 60 * 1000; // outlasts the host's 6h job cap

const installed = !BASE.startsWith("__") && !KEY.startsWith("__");

const round32 = (value, fallback) => {
  const raw = Number.isInteger(value) ? value : fallback;
  const clamped = Math.min(4096, Math.max(256, raw));
  return Math.round(clamped / 32) * 32;
};

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// fetch with a JSON response; throws with the server's error message.
const request = async (url, init) => {
  const res = await fetch(url, init);
  if (!res.ok) {
    let detail = "";
    try {
      detail = (await res.json())?.error?.message || "";
    } catch {
      /* non-JSON error body */
    }
    throw new Error(`HTTP ${res.status}${detail ? `: ${detail}` : ""}`);
  }
  return res;
};

const jobStatus = async (api, jobId, signal) =>
  (
    await request(`${api}/v1/jobs/${jobId}`, {
      headers: { Authorization: `Bearer ${KEY}` },
      signal,
    })
  ).json();

// Read a local image and inline it as base64 for the host service;
// returns { name, data_base64 }.
const inlineImage = async (filePath) => {
  const buf = await readFile(filePath);
  if (buf.length > 16 * 1024 * 1024) {
    throw new Error(`${filePath} is over the 16 MB per-image limit.`);
  }
  return { name: path.basename(filePath), data_base64: buf.toString("base64") };
};

// Where the finished file should be stored: `wantPath` is the user's
// output_path option ("" = default dir). Paths without a matching
// extension are treated as directories and get a generated file name.
const resolveOutput = (wantPath, defaultDir, prefix, ext) => {
  const want = wantPath
    ? path.resolve(os.homedir(), wantPath.replace(/^~/, os.homedir()))
    : "";
  const stamp = new Date().toISOString().replace(/[-:T]/g, "").slice(0, 14);
  const generated = `${prefix}-${stamp}-${Math.random().toString(36).slice(2, 6)}.${ext}`;
  if (!want) return path.join(defaultDir, generated);
  const asDir =
    want.endsWith("/") ||
    want.endsWith(path.sep) ||
    !want.toLowerCase().endsWith(`.${ext}`);
  return asDir ? path.join(want, generated) : want;
};

export default Plugin.define({
  id: "mtplx.image-generation",
  async setup(ctx) {
    await ctx.tool.transform((editor) => {
      editor.add({
        name: "generate_image",
        description:
          "Generate or edit an image with MiniMax H3-Image, generated on the " +
          "MTPLX host over the tailnet. Text-to-image, or image editing when " +
          "reference images are given. Takes roughly 30-120s per 1024x1024 " +
          "image (longer if the queue is busy) and returns the path of the saved PNG.",
        input: {
          type: "object",
          properties: {
            prompt: {
              type: "string",
              description:
                "Describe the image to generate, or the edit to apply when references are given. " +
                "Be concrete: subject, style, lighting, composition.",
            },
            width: {
              type: "integer",
              description: "Output width in pixels, multiple of 32, 256-4096. Default 1024.",
            },
            height: {
              type: "integer",
              description: "Output height in pixels, multiple of 32, 256-4096. Default 1024.",
            },
            seed: {
              type: "integer",
              description: "Optional seed for reproducible output.",
            },
            references: {
              type: "array",
              items: { type: "string" },
              description:
                "Absolute paths to up to 16 reference images to edit. Provide when the task is to " +
                "edit or remix existing pictures rather than a fresh generation.",
            },
            output_path: {
              type: "string",
              description:
                "Optional path to store the PNG. Absolute, or relative to the home " +
                "directory; ~ is expanded. If it names a directory (or has no .png " +
                "extension), the file gets a generated name inside it; if it ends in " +
                ".png it is used as the file name. Default: ~/.mtplx/h3-image-mlx/out/.",
            },
          },
          required: ["prompt"],
          additionalProperties: false,
        },
        options: { codemode: false },
        execute: async (input, context) => {
          if (!installed) {
            return {
              content:
                "Image generation is not configured: this plugin still holds the " +
                "__MTPLX_BASE__/__MTPLX_KEY__ placeholders. Run the MTPLX client " +
                "installer, or edit ~/.config/opencode/plugins/mtplx-image-generation/index.js " +
                "and replace them with your host URL and mtr_ key.",
            };
          }
          const refs = Array.isArray(input.references)
            ? input.references.filter((r) => typeof r === "string").slice(0, 16)
            : [];
          const missing = refs.filter((r) => !existsSync(r));
          if (missing.length) {
            return { content: `Reference image(s) not found: ${missing.join(", ")}` };
          }

          // Read reference images and inline them as base64 for the host.
          let references = [];
          try {
            for (const refPath of refs) {
              references.push(await inlineImage(refPath));
            }
          } catch (e) {
            return { content: String(e.message || e) };
          }

          const deadline = Date.now() + IMG_TIMEOUT_MS;
          const body = {
            prompt: String(input.prompt),
            width: round32(input.width, 1024),
            height: round32(input.height, 1024),
          };
          if (Number.isInteger(input.seed)) body.seed = input.seed;
          if (references.length) body.references = references;

          // 1. Submit the job.
          let job;
          try {
            const res = await request(`${IMG_API}/v1/jobs`, {
              method: "POST",
              headers: {
                Authorization: `Bearer ${KEY}`,
                "Content-Type": "application/json",
              },
              body: JSON.stringify(body),
              signal: context.signal,
            });
            job = await res.json();
          } catch (e) {
            return {
              content:
                `Could not submit the image job to the MTPLX host (${IMG_API}): ` +
                `${String(e).slice(0, 300)}. Check Tailscale is up and the host's ` +
                "image service is running (`tailscale serve status` on the host).",
            };
          }

          // 2. Poll until done/failed, surfacing queue position.
          let status = job;
          while (status.status === "queued" || status.status === "running") {
            if (Date.now() > deadline) {
              return {
                content:
                  `Job ${job.job_id} is still ${status.status} after ` +
                  `${IMG_TIMEOUT_MS / 60000} minutes; check back with ` +
                  `GET ${IMG_API}/v1/jobs/${job.job_id}.`,
              };
            }
            const pos =
              typeof status.position === "number" ? status.position : null;
            await context.progress({
              status:
                status.status === "running"
                  ? "H3-Image is generating your image…"
                  : `Waiting for H3-Image (${pos === 0 ? "next in" : pos} in front of the queue)…`,
            });
            await sleep(IMG_POLL_MS);
            status = await jobStatus(IMG_API, job.job_id, context.signal);
          }

          if (status.status !== "done") {
            return {
              content: `Image job ${job.job_id} ${status.status}: ${status.error || "no further detail"}.`,
            };
          }

          // 3. Download the PNG to the requested path (default out dir).
          const outPath = resolveOutput(
            typeof input.output_path === "string" ? input.output_path.trim() : "",
            IMG_OUT_DIR,
            "h3",
            "png",
          );
          await mkdir(path.dirname(outPath), { recursive: true });
          const imgRes = await request(`${IMG_API}/v1/jobs/${job.job_id}/image`, {
            headers: { Authorization: `Bearer ${KEY}` },
            signal: context.signal,
          });
          await writeFile(outPath, Buffer.from(await imgRes.arrayBuffer()));

          return {
            content:
              `Image saved to ${outPath} (${status.width}x${status.height}` +
              `${Number.isInteger(status.seed) ? `, seed ${status.seed}` : ""}). ` +
              "Show it to the user by reading that file, and mention where it is. " +
              "Powered by MiniMax-H3-Image.",
          };
        },
      });

      editor.add({
        name: "generate_video",
        description:
          "Generate a short video clip (5 seconds, video + audio) with " +
          "MiniMax H3-Video, generated on the MTPLX host over the tailnet. " +
          "Each run takes roughly 2.2-2.5 hours (plus queue time) — confirm " +
          "with the user before firing one; it survives session restarts via " +
          "the job id. Returns the path of the saved MP4.",
        input: {
          type: "object",
          properties: {
            prompt: {
              type: "string",
              description:
                "Describe the clip to generate, or the edit to apply when a keyframe is given. " +
                "Be concrete: subject, motion, camera, style, sound.",
            },
            canvas: {
              type: "string",
              enum: ["16x9", "9x16", "1x1", "4x3", "3x4"],
              description:
                "Aspect ratio. H3 is trained for a 768-pixel short edge, so " +
                "16x9 renders 1344x768 etc. Default 16x9.",
            },
            keyframe: {
              type: "string",
              description:
                "Optional absolute path to an image to animate. Provide when " +
                "the task is to animate an existing picture rather than a " +
                "fresh generation.",
            },
            keyframe_anchor: {
              type: "string",
              enum: ["first", "last"],
              description:
                "Whether the keyframe is the first or last frame of the clip. Default first.",
            },
            seed: {
              type: "integer",
              description: "Optional seed for reproducible output.",
            },
            output_path: {
              type: "string",
              description:
                "Optional path to store the MP4. Absolute, or relative to the " +
                "home directory; ~ is expanded. If it names a directory (or " +
                "has no .mp4 extension), the file gets a generated name inside " +
                "it; if it ends in .mp4 it is used as the file name. " +
                "Default: ~/.mtplx/h3-video-mlx/out/.",
            },
          },
          required: ["prompt"],
          additionalProperties: false,
        },
        options: { codemode: false },
        execute: async (input, context) => {
          if (!installed) {
            return {
              content:
                "Video generation is not configured: this plugin still holds the " +
                "__MTPLX_BASE__/__MTPLX_KEY__ placeholders. Run the MTPLX client " +
                "installer, or edit ~/.config/opencode/plugins/mtplx-image-generation/index.js " +
                "and replace them with your host URL and mtr_ key.",
            };
          }

          const body = {
            prompt: String(input.prompt),
            canvas: ["16x9", "9x16", "1x1", "4x3", "3x4"].includes(input.canvas)
              ? input.canvas
              : "16x9",
          };
          if (Number.isInteger(input.seed)) body.seed = input.seed;

          // Keyframe editing: inline the image as base64 for the host.
          if (typeof input.keyframe === "string" && input.keyframe.trim()) {
            const kfPath = path.resolve(
              os.homedir(),
              input.keyframe.trim().replace(/^~/, os.homedir()),
            );
            if (!existsSync(kfPath)) {
              return { content: `Keyframe image not found: ${kfPath}` };
            }
            try {
              body.keyframe = await inlineImage(kfPath);
            } catch (e) {
              return { content: String(e.message || e) };
            }
            body.keyframe_anchor =
              input.keyframe_anchor === "last" ? "last" : "first";
          }

          // 1. Submit the job.
          let job;
          try {
            const res = await request(`${VID_API}/v1/jobs`, {
              method: "POST",
              headers: {
                Authorization: `Bearer ${KEY}`,
                "Content-Type": "application/json",
              },
              body: JSON.stringify(body),
              signal: context.signal,
            });
            job = await res.json();
          } catch (e) {
            return {
              content:
                `Could not submit the video job to the MTPLX host (${VID_API}): ` +
                `${String(e).slice(0, 300)}. Check Tailscale is up and the host's ` +
                "video service is running (`tailscale serve status` on the host).",
            };
          }

          // 2. Poll until done/failed; video jobs run for hours, so poll
          // coarsely and give up only after the host's own job timeout.
          let status = job;
          const deadline = Date.now() + VID_TIMEOUT_MS;
          while (status.status === "queued" || status.status === "running") {
            if (Date.now() > deadline) {
              return {
                content:
                  `Job ${job.job_id} is still ${status.status} after ` +
                  `${VID_TIMEOUT_MS / 60000} minutes; check back with ` +
                  `GET ${VID_API}/v1/jobs/${job.job_id}.`,
              };
            }
            const pos =
              typeof status.position === "number" ? status.position : null;
            await context.progress({
              status:
                status.status === "running"
                  ? "H3-Video is generating your clip (expect ~2.5 h)…"
                  : `Waiting for H3-Video (${pos === 0 ? "next in" : pos} in front of the queue)…`,
            });
            await sleep(VID_POLL_MS);
            status = await jobStatus(VID_API, job.job_id, context.signal);
          }

          if (status.status !== "done") {
            return {
              content: `Video job ${job.job_id} ${status.status}: ${status.error || "no further detail"}.`,
            };
          }

          // 3. Download the MP4 to the requested path (default out dir).
          const outPath = resolveOutput(
            typeof input.output_path === "string" ? input.output_path.trim() : "",
            VID_OUT_DIR,
            "h3-video",
            "mp4",
          );
          await mkdir(path.dirname(outPath), { recursive: true });
          const vidRes = await request(`${VID_API}/v1/jobs/${job.job_id}/video`, {
            headers: { Authorization: `Bearer ${KEY}` },
            signal: context.signal,
          });
          await writeFile(outPath, Buffer.from(await vidRes.arrayBuffer()));

          return {
            content:
              `Video saved to ${outPath} (${status.duration || 5}s, ` +
              `${status.canvas || "16x9"}` +
              `${Number.isInteger(status.seed) ? `, seed ${status.seed}` : ""}). ` +
              "Show it to the user by reading that file, and mention where it is. " +
              "Powered by MiniMax-H3-Video.",
          };
        },
      });
    });
  },
});
