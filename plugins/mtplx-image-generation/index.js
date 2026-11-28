// MTPLX image generation via MiniMax H3-Image, run on the MTPLX host.
//
// Registers one agent-callable tool, `generate_image`, that calls the host's
// image job service (mtplx-image-service.py) over the tailnet:
//
//   POST <base>/image/v1/jobs          -> submit, get job id + queue position
//   GET  <base>/image/v1/jobs/<id>     -> poll status (position while queued)
//   GET  <base>/image/v1/jobs/<id>/image -> download the finished PNG
//
// The host serialises jobs, so any number of clients can fire at once; each
// one sees its queue position here through context.progress and the file
// lands in ~/.mtplx/h3-image-mlx/out/ on this machine. No local model, no
// Apple Silicon needed — this works the same on Windows.
//
// The MTPLX installer replaces __MTPLX_BASE__ (host URL, e.g.
// https://<host>.<tailnet>.ts.net) and __MTPLX_KEY__ (your mtr_ key) when
// it writes this file. With placeholders left in place the tool still
// registers, but returns a clear "not installed" message.
import { existsSync } from "node:fs";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { Plugin } from "@opencode/plugin";

const BASE = "__MTPLX_BASE__"; // e.g. https://host.tailnet.ts.net
const KEY = "__MTPLX_KEY__";   // your mtr_... API key
const API = `${BASE}/image`;

const OUT_DIR = path.join(os.homedir(), ".mtplx", "h3-image-mlx", "out");
const POLL_MS = 5000;
const OVERALL_TIMEOUT_MS = 60 * 60 * 1000; // queue + generation combined

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

const jobStatus = async (jobId, signal) =>
  (
    await request(`${API}/v1/jobs/${jobId}`, {
      headers: { Authorization: `Bearer ${KEY}` },
      signal,
    })
  ).json();

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
          for (const refPath of refs) {
            const buf = await readFile(refPath);
            if (buf.length > 16 * 1024 * 1024) {
              return { content: `${refPath} is over the 16 MB per-reference limit.` };
            }
            references.push({
              name: path.basename(refPath),
              data_base64: buf.toString("base64"),
            });
          }

          const deadline = Date.now() + OVERALL_TIMEOUT_MS;
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
            const res = await request(`${API}/v1/jobs`, {
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
                `Could not submit the image job to the MTPLX host (${API}): ` +
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
                  `${OVERALL_TIMEOUT_MS / 60000} minutes; check back with ` +
                  `GET ${API}/v1/jobs/${job.job_id}.`,
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
            await sleep(POLL_MS);
            status = await jobStatus(job.job_id, context.signal);
          }

          if (status.status !== "done") {
            return {
              content: `Image job ${job.job_id} ${status.status}: ${status.error || "no further detail"}.`,
            };
          }

          // 3. Download the PNG to the local out directory.
          await mkdir(OUT_DIR, { recursive: true });
          const stamp = new Date().toISOString().replace(/[-:T]/g, "").slice(0, 14);
          const outPath = path.join(
            OUT_DIR,
            `h3-${stamp}-${Math.random().toString(36).slice(2, 6)}.png`,
          );
          const imgRes = await request(`${API}/v1/jobs/${job.job_id}/image`, {
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
    });
  },
});
