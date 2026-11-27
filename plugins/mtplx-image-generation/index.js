// MTPLX image generation via MiniMax H3-Image, run locally through MLX.
//
// Registers one agent-callable tool, `generate_image`, that shells out to the
// `h3-image-mlx` CLI installed by the MTPLX client installer in
// ~/.mtplx/h3-image-mlx/.venv. There is no HTTP service for it: the CLI loads
// the weights per call, so jobs are serialised through a promise chain to keep
// memory use sane when several sessions ask at once.
//
// Needs macOS on Apple Silicon with the weights fetched
// (`h3-image-mlx fetch --model h3 --precision int8 --models ~/.mtplx/h3-image-mlx/models`).
// Anywhere else the tool still registers, but returns a clear "not available"
// message instead of failing obscurely.
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { Plugin } from "@opencode/plugin";

const H3_DIR = path.join(os.homedir(), ".mtplx", "h3-image-mlx");
const H3_BIN = path.join(H3_DIR, ".venv", "bin", "h3-image-mlx");
const H3_MODELS = path.join(H3_DIR, "models");
const H3_OUT = path.join(H3_DIR, "out");

const round32 = (value, fallback) => {
  const raw = Number.isInteger(value) ? value : fallback;
  const clamped = Math.min(4096, Math.max(256, raw));
  return Math.round(clamped / 32) * 32;
};

const runH3 = (args, signal) =>
  new Promise((resolve, reject) => {
    const child = spawn(H3_BIN, args, {
      env: { ...process.env, H3_ASYNC: "1", H3_PREFETCH: "1" },
      stdio: ["ignore", "pipe", "pipe"],
      signal,
    });
    let out = "";
    let err = "";
    child.stdout.on("data", (d) => { out = (out + String(d)).slice(-16000); });
    child.stderr.on("data", (d) => { err = (err + String(d)).slice(-8000); });
    // Hard ceiling: 30 minutes covers a cold load of the 21 GB DiT plus a
    // 4096px generation on a busy machine.
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error("h3-image-mlx timed out after 1800s"));
    }, 1_800_000);
    child.on("error", (e) => { clearTimeout(timer); reject(e); });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (code === 0) resolve({ out, err });
      else reject(new Error(`h3-image-mlx exited ${code}: ${(err || out).slice(-2000) || "no output"}`));
    });
  });

// One generation at a time; extra requests queue behind it (the CLI reloads
// gigabytes of weights per call, so two at once would thrash memory).
let chain = Promise.resolve();
const serial = (task) => {
  const run = chain.then(task, task);
  chain = run.catch(() => {});
  return run;
};

export default Plugin.define({
  id: "mtplx.image-generation",
  async setup(ctx) {
    await ctx.tool.transform((editor) => {
      editor.add({
        name: "generate_image",
        description:
          "Generate or edit an image with MiniMax H3-Image running locally via MLX. " +
          "Text-to-image, or image editing when reference images are given. " +
          "Takes about 20-120s per 1024x1024 image and returns the path of the saved PNG.",
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
          if (!existsSync(H3_BIN)) {
            return {
              content:
                `Image generation is not installed here: ${H3_BIN} was not found. ` +
                "Run the MTPLX client installer, or install python@3.12 and " +
                "`pip install h3-image-mlx` into ~/.mtplx/h3-image-mlx/.venv, then run " +
                "`h3-image-mlx fetch --model h3 --precision int8 " +
                `--models ${H3_MODELS} (about 49 GB of weights).`,
            };
          }
          const width = round32(input.width, 1024);
          const height = round32(input.height, 1024);
          const refs = Array.isArray(input.references)
            ? input.references.filter((r) => typeof r === "string").slice(0, 16)
            : [];
          const missing = refs.filter((r) => !existsSync(r));
          if (missing.length) {
            return { content: `Reference image(s) not found: ${missing.join(", ")}` };
          }
          const stamp = new Date().toISOString().replace(/[-:T]/g, "").slice(0, 14);
          const outPath = path.join(H3_OUT, `h3-${stamp}-${Math.random().toString(36).slice(2, 6)}.png`);
          return serial(async () => {
            await mkdir(H3_OUT, { recursive: true });
            await context.progress({ status: "loading H3-Image and generating…" });
            const args = [
              "generate",
              "--model", "h3",
              "--models", H3_MODELS,
              "--precision", "int8",
              "--dit-mode", "stream",
              "--prompt", String(input.prompt),
              "--output", outPath,
              "--width", String(width),
              "--height", String(height),
            ];
            if (Number.isInteger(input.seed)) args.push("--seed", String(input.seed));
            for (const ref of refs) args.push("--reference", ref);
            const { out, err } = await runH3(args, context.signal);
            if (!existsSync(outPath)) {
              return {
                content:
                  `h3-image-mlx finished without writing a file. Last output:\n${(out || err).slice(-1500)}`,
              };
            }
            return {
              content:
                `Image saved to ${outPath} (${width}x${height}` +
                `${Number.isInteger(input.seed) ? `, seed ${input.seed}` : ""}). ` +
                "Show it to the user by reading that file, and mention where it is. " +
                "Powered by MiniMax-H3-Image.",
            };
          });
        },
      });
    });
  },
});
