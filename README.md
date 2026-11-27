# MTPLX Client — Install Guide

This repo contains the client installer scripts that point your local OpenCode
at the shared MTPLX model router on the host MacBook. There are two installers:

| File | Platform |
|---|---|
| `mtplx-client-install.sh` | macOS (Apple Silicon) / Linux |
| `mtplx-client-install.ps1` | Windows |

## What you get

Five local MTPLX models run on the host via a FIFO RAM queue/router
(port 8100), exposed over Tailscale. You run your own OpenCode locally, so
only prompts and token streams cross the wire (~1.2 MB/s upload).

### Models

| Provider ID | Model | Session Bank |
|---|---|---|
| `mtplx` | Qwen3.5 9B (shared) | 6 GB |
| `mtplx-27b` | Qwen3.8 27B | 8 GB |
| `mtplx-35b` | Qwen3.6 35B-A3B | 6 GB |
| `mtplx-inkling` | Inkling 2 Mini | 6 GB |
| `mtplx-flashnext` | Qwen3.8 Flash-Next 125B-A6B | 6 GB |

Flash-Next loads ~99 GB and evicts other models — the first request triggers a
brief 503 on the other models. That's expected.

### Image generation (macOS only)

The installer also sets up **local image generation** with MiniMax H3-Image
(via an MLX port). An OpenCode plugin registers a `generate_image` tool on
your machine — the model runs on your own Apple Silicon Mac, nothing goes to
the host. A 1024×1024 image takes roughly 20–60 s depending on your machine;
you need ~50 GB free disk for the weights and 32 GB+ RAM recommended. The
weights are gated behind the MiniMax Community License (not usable in
US/EU/UK/South Korea, and not for improving other AI models) — accept it on
the Hugging Face repo and keep a HF token if you want the models. Windows
machines get everything except the image plugin (MLX requires Apple
Silicon); use `-SkipImage` / `--skip-image` to skip those steps.

## Prerequisites

1. **Tailscale access** — your machine must be in the host's tailnet. The
   installer installs Tailscale and logs you in, but you need tailnet
   credentials from the network owner.
2. **An API key** — ask the host admin to run:

   ```bash
   ./mtplx-router.sh key add <Your Name>
   ```

   They will give you the key value (`mtr_...`, shown once).

---

## Install on macOS

Copy `mtplx-client-install.sh` to your machine (clone this repo, scp, AirDrop,
etc.), then:

```bash
cd /tmp   # or wherever you put it
chmod +x mtplx-client-install.sh
./mtplx-client-install.sh \
  --base https://<host-tailnet-name>.ts.net \
  --key mtr_XXXXXXX
```

**What it does** (in order):

1. Installs Tailscale (via Homebrew cask) and logs in if needed
2. Installs OpenCode (latest release)
3. Installs the `mtplx-session-headers` plugin (byte-identical to host version)
   and the `mtplx-image-generation` plugin (see Image generation above; also
   shipped in this repo under `plugins/`)
4. Writes `~/.config/opencode/opencode.jsonc` with all 5 providers and both
   plugins
5. Installs MiniMax H3-Image: Homebrew `python@3.12`, a dedicated venv, the
   `h3-image-mlx` package, and the gated model weights (~49 GB). Use
   `--skip-image` to skip this; you must accept the MiniMax Community License
   on Hugging Face (and supply `--hf-token` if gated) to get the weights
6. Verifies connectivity to the router and the image tool

**Options:**
- `--fresh` — write a clean MTPLX-only config (preserves existing config as
  backup)
- Without `--fresh` — merges MTPLX providers into any existing config,
  preserving other providers

Re-run anytime to re-verify or repair.

## Install on Windows

Copy `mtplx-client-install.ps1` to your machine (clone this repo, scp, USB,
etc.), then open PowerShell 5.1+ (or PowerShell 7) as a regular user:

```powershell
Copy-Item mtplx-client-install.ps1 C:\Users\<user>\Downloads\
cd C:\Users\<user>\Downloads
.\mtplx-client-install.ps1 -Base "https://<host-tailnet-name>.ts.net" -Key "mtr_XXXXXXX"
```

**What it does** (in order):

1. Installs Tailscale (via winget) and logs in if needed
2. Downloads and extracts OpenCode for Windows
3. Installs the `mtplx-session-headers` plugin (byte-identical to host version)
4. Writes `%USERPROFILE%\.config\opencode\opencode.jsonc` with all 5 providers
5. Skips MiniMax H3-Image setup (MLX requires Apple Silicon) — pass
   `-SkipImage` to accept this; nothing else changes
6. Verifies connectivity to the router

**Options:**
- `-Fresh` — write a clean MTPLX-only config (preserves existing config as
  backup)
- Without `-Fresh` — merges MTPLX providers into any existing config,
  preserving other providers

Re-run anytime to re-verify or repair.

### Updating after the host changes models

The installer **discovers model IDs from the host at install time** instead
of shipping hardcoded values. If the host adds, removes, or renames models,
just re-run the same command — the script overwrites the MTPLX providers with
the discovered IDs and leaves any non-MTPLX providers untouched.

If the model IDs haven't changed (most of the time), re-running is a no-op and
harmless. You **don't need to do anything** if you already ran the installer —
your config is already correct.

---

## Using OpenCode

After installation, open a new terminal and run:

```bash
opencode
```

- Starts on **MTPLX 27B** by default
- Switch models with `/models`
- Subagents run on **9B** (`mtplx`)
- Ask for an image (e.g. "draw me a…") — on a Mac with H3-Image installed the
  agent uses the local `generate_image` tool; it is not a router model
- If you see 503 errors on the first Flash-Next request, that's normal
  (it loads ~99 GB and evicts other models). Subsequent requests will be fast.

Your API key and the host URL live in `~/.config/opencode/opencode.jsonc`
(`%USERPROFILE%\.config\opencode\opencode.jsonc` on Windows).

## Configuration Reference

All providers share these settings:

- **context**: 65536
- **KV cache**: q8
- **output**: 16384
- **compaction**: `{ "auto": true, "buffer": "25%" }`

## Troubleshooting

### "Could not connect" / "NeedsLogin"

Open the Tailscale app and log in. The installer handles this automatically on
first run.

### 503 on model requests

The router may be processing a queued request or loading Flash-Next. Wait a
moment and retry.

### Key rejected (401)

The host admin may have revoked your key. Ask them to run:

```bash
./mtplx-router.sh key rm <Your Name>
./mtplx-router.sh key add <Your Name>
```

Then re-run the client installer with the new key.

### Need help with the host side?

Router management, key creation, usage tracking, and Tailscale serve setup are
documented in the `mtplx-host` repo (`README.md`) — that's for the machine
running the models, not for you.
