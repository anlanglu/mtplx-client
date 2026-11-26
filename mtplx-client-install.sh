#!/usr/bin/env bash
#
# mtplx-client-install.sh
#
# Version: 2026-11-26-2130
#
# One-shot installer for the MTPLX *client* side of the shared-models setup.
# Run this on each remote person's Mac. It does everything a remote user needs
# to use the five MTPLX models through their own local OpenCode, over Tailscale:
#
#   1. Installs Tailscale            (brew install --cask tailscale)
#   2. Installs OpenCode             (official installer, binary in ~/.opencode/bin)
#   3. Installs the mtplx-session-headers plugin (bundled below, self-contained)
#   4. Writes ~/.config/opencode/opencode.jsonc so all five MTPLX providers
#      point at the host's Tailscale URL with your personal API key
#   5. Logs Tailscale in (prints a URL you click exactly once)
#   6. Verifies the link: GET /health and, with your key, GET /mtplx-27b/v1/models
#
# Only prompts and streamed completion tokens cross the wire — the session,
# files and tool output stay on this machine. That is what keeps it usable on a
# slow uplink.
#
# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
#   ./mtplx-client-install.sh --base https://<host-tailnet-name>.ts.net --key mtr_XXXX
#                             [--hostname alice-mac]
#
#   --base URL      the host's Tailscale origin, no trailing path.
#                   (The host runs `tailscale serve --bg http://127.0.0.1:8100`;
#                    `tailscale serve status` prints the exact https name.)
#   --key KEY       your personal MTPLX API key, generated on the host with
#                   `./mtplx-router.sh key add <name>`. Shown once there.
#   --hostname H    optional friendly Tailscale name for this machine
#                   (defaults to the computer's name).
#
# Optional:
#   --fresh         write a clean MTPLX-only config instead of merging into any
#                   existing opencode.jsonc. (An existing file is always backed
#                   up to opencode.jsonc.bak-<timestamp> first, so nothing is
#                   lost either way.)
#   --skip-tailscale   / --skip-opencode   re-run a single part without redownloading
#   --no-verify         skip the network verification at the end
#   -h | --help
#
# Every step is idempotent — re-running the script is safe and just repairs
# whatever is missing.
#
# ---------------------------------------------------------------------------
set -euo pipefail

# ---------------------------------------------------------------------------
# Pretty output
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  B=$'\033[1m'; D=$'\033[0;2m'; G=$'\033[0;32m'; R=$'\033[0;31m'; O=$'\033[0;33m'
  C=$'\033[0m'
else
  B=""; D=""; G=""; R=""; O=""; C=""
fi
say()  { printf '%s\n' "${B}${*}${C}"; }
ok()   { printf '%s\n' "${G}  ✓${C} ${*}"; }
info() { printf '%s\n' "${D}  · ${*}${C}"; }
warn() { printf '%s\n' "${O}  ! ${*}${C}"; }
err()  { printf '%s\n' "${R}  ✗ ${*}${C}" >&2; }
step() { printf '\n%s\n' "${B}== ${*} ==${C}"; }

# ---------------------------------------------------------------------------
# Version
# ---------------------------------------------------------------------------
INSTALLER_VERSION="2026-11-26-2130"

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
BASE="" KEY="" HOSTNAME="" FRESH=0 SKIP_TS=0 SKIP_OC=0 NO_VERIFY=0
usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --base)          BASE="${2:-}"; shift 2 ;;
    --key)           KEY="${2:-}"; shift 2 ;;
    --hostname)      HOSTNAME="${2:-}"; shift 2 ;;
    --fresh)         FRESH=1; shift ;;
    --skip-tailscale) SKIP_TS=1; shift ;;
    --skip-opencode)  SKIP_OC=1; shift ;;
    --no-verify)     NO_VERIFY=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) err "unknown argument: $1"; usage; exit 2 ;;
  esac
done

# Tailscale hostname defaults to the computer's name.
if [ -z "$HOSTNAME" ]; then
  HOSTNAME="$(scutil --get ComputerName 2>/dev/null || hostname -s 2>/dev/null || echo mtplx-client)"
fi
# Normalise: tailscale wants a DNS-ish label.
HOSTNAME="$(printf '%s' "$HOSTNAME" | tr ' -' '--' | tr '[:upper:]' '[:lower:]')"

if [ -z "$BASE" ] || [ -z "$KEY" ]; then
  err "both --base and --key are required."
  echo
  usage
  exit 2
fi
BASE="${BASE%/}"   # strip a trailing slash
case "$BASE" in
  http*) : ;;
  *) BASE="https://$BASE" ;;
esac

say "MTPLX client installer (v${INSTALLER_VERSION})"
info "host origin : $BASE"
info "tailscale   : $HOSTNAME"
info "api key     : ${KEY:0:8}… (omitted)"

# ---------------------------------------------------------------------------
# 0. Preflight
# ---------------------------------------------------------------------------
step "Preflight"
if [ "$(uname -s)" != "Darwin" ]; then
  err "this installer targets macOS. (The shared host is a Mac; clients should be too for now.)"
  exit 1
fi
for tool in curl python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    err "required tool '$tool' is not installed."
    exit 1
  fi
done
ok "macOS + curl + python3 present"

# Homebrew (needed for the Tailscale cask).
need_brew() {
  if [ "$SKIP_TS" = "1" ]; then return 0; fi
  if command -v brew >/dev/null 2>&1; then return 0; fi
  warn "Homebrew not found — installing it (this downloads the installer)."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Add brew to PATH for Apple Silicon / Intel in this session.
  if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"; fi
  if [ -x /usr/local/bin/brew ]; then eval "$(/usr/local/bin/brew shellenv)"; fi
}
need_brew
if [ "$SKIP_TS" = "1" ]; then info "skipping Homebrew/Tailscale install (--skip-tailscale)"; else ok "Homebrew present"; fi

# Make sure the OpenCode binary directory is on PATH for this session.
export PATH="$HOME/.opencode/bin:$PATH"

# ---------------------------------------------------------------------------
# Helper: ensure ~/.opencode/bin is on PATH via shell profile
# Writes to every common profile file so it works regardless of shell
# type (login vs interactive) or shell (zsh vs bash).
# ---------------------------------------------------------------------------
ensure_opencode_path() {
  local entry='export PATH="$HOME/.opencode/bin:$PATH"'
  local rcfiles=("$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.bashrc")
  for rcfile in "${rcfiles[@]}"; do
    [ -z "$rcfile" ] && continue
    if [ -f "$rcfile" ] && grep -qF '$HOME/.opencode/bin' "$rcfile" 2>/dev/null; then
      continue  # already present in this file
    fi
    echo "" >> "$rcfile"
    echo "# MTPLX: OpenCode binary path" >> "$rcfile"
    echo "$entry" >> "$rcfile"
    ok "Added OpenCode to PATH in $rcfile"
  done
}

# ---------------------------------------------------------------------------
# 1. Tailscale
# ---------------------------------------------------------------------------
if [ "$SKIP_TS" = "1" ]; then
  step "Tailscale (skipped)"
  info "--skip-tailscale set."
else
  step "1/4  Install Tailscale"
  if brew list --cask tailscale >/dev/null 2>&1; then
    ok "Tailscale already installed."
  else
    info "brew install --cask tailscale  (you may be asked for your password)"
    brew install --cask tailscale
    ok "Tailscale installed."
  fi

  # The cask installs the menu-bar app; launching it starts the local daemon
  # that the `tailscale` CLI talks to.
  info "launching the Tailscale app so its daemon starts…"
  open -a Tailscale >/dev/null 2>&1 || true

  ts_status() { tailscale status 2>&1 || true; }
  daemon_ready() {
    local out
    out="$(ts_status)"
    # "ready" = the CLI reached a daemon (it says Logged out / in / a node),
    # as opposed to "could not connect to tailscaled".
    if printf '%s' "$out" | grep -qiE 'could not connect|no such file|connection refused|tailscaled is not running'; then
      return 1
    fi
    return 0
  }
  if daemon_ready; then
    ok "Tailscale daemon is running."
  else
    warn "Waiting for the Tailscale daemon to come up (up to ~90s)…"
    for _ in $(seq 1 30); do
      daemon_ready && { ok "Tailscale daemon is running."; break; }
      sleep 3
    done
    if ! daemon_ready; then
      warn "Still not connected. Open the Tailscale menu-bar app, make sure it"
      warn "appears in the top-right of the menu bar, then press Enter to continue."
      read -r -s _ || true
      daemon_ready || { err "Tailscale daemon is not reachable. Fix the app and re-run."; exit 1; }
      ok "Tailscale daemon is running."
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 2. OpenCode
# ---------------------------------------------------------------------------
if [ "$SKIP_OC" = "1" ]; then
  step "OpenCode (skipped)"
  info "--skip-opencode set."
else
  step "2/4  Install OpenCode"
  if command -v opencode >/dev/null 2>&1; then
    ok "OpenCode already installed: $(opencode --version 2>/dev/null | head -1 || true)"
    ensure_opencode_path
  else
    info "curl -fsSL https://opencode.ai/v2/install | bash"
    if curl -fsSL https://opencode.ai/v2/install | bash; then
      ok "OpenCode installed to ~/.opencode/bin."
    else
      warn "official installer failed; falling back to npm (needs Node.js)."
      command -v npm >/dev/null 2>&1 || { err "npm not found; install Node.js or re-run."; exit 1; }
      npm install -g @opencode/cli
      ok "OpenCode installed via npm."
    fi
    hash -r 2>/dev/null || true
    if ! command -v opencode >/dev/null 2>&1; then
      # The installer writes PATH into the shell rc, but not this session.
      if [ -x "$HOME/.opencode/bin/opencode" ]; then
        export PATH="$HOME/.opencode/bin:$PATH"
        ok "OpenCode found at ~/.opencode/bin (open a new terminal later for PATH)."
      else
        err "OpenCode installed but not found on PATH."
        exit 1
      fi
    fi
    ensure_opencode_path
  fi
fi

# ---------------------------------------------------------------------------
# 3. mtplx-session-headers plugin
# ---------------------------------------------------------------------------
step "3/4  Install MTPLX plugin"
PLUGIN_DIR="$HOME/.config/opencode/plugins/mtplx-session-headers"
mkdir -p "$PLUGIN_DIR"

cat > "$PLUGIN_DIR/index.js" <<'MTPLX_PLUGIN_INDEX'
const mtplxProviderID = (input) =>
  input?.model?.providerID || input?.provider?.id;
const mtplxProviderIDs = new Set(["mtplx", "mtplx-27b", "mtplx-35b", "mtplx-inkling", "mtplx-flashnext"]);

const mtplxInjectedOutputCap = 32000;
const mtplxRequestedOutputHeader = "x-mtplx-max-response-tokens";
const mtplxInjectedQwenTemperature = 0.55;
const mtplxInjectedQwenTopP = 1;

export const MTPLXSessionHeaders = async () => ({
  "chat.headers": async (input, output) => {
    output.headers ||= {};
    const providerID = mtplxProviderID(input);
    if (providerID && !mtplxProviderIDs.has(providerID)) return;
    output.headers["x-mtplx-client"] = "opencode";
    if (input?.sessionID) {
      output.headers["x-mtplx-session-id"] = String(input.sessionID);
    }
    if (input?.message?.id) {
      output.headers["x-mtplx-client-turn-id"] = String(input.message.id);
    }
  },
  "chat.params": async (input, output) => {
    const providerID = mtplxProviderID(input);
    if (providerID && !mtplxProviderIDs.has(providerID)) return;
    // OpenCode sends maxOutputTokens = min(limit.output, 32000) with every
    // request and hands this hook the model with its limit and headers.
    // MTPLX writes limit.output as OpenCode's reply reserve, half the window
    // and at most 32,000 (#480), so by default that value is OpenCode's own
    // and is stripped: the server's own limits apply. An answer cap the user
    // asked MTPLX for (--max-response-tokens) is the model's
    // x-mtplx-max-response-tokens header and is sent whole, past OpenCode's
    // 32,000 ceiling; a limit.output that is not MTPLX's reserve is sent the
    // same way. Any other value is a cap set in OpenCode itself and passes
    // through untouched.
    const positive = (value) => (Number.isInteger(value) && value > 0 ? value : null);
    const limit = input?.model?.limit;
    const configuredOutput = positive(limit?.output);
    const opencodeDefault = configuredOutput === null
      ? mtplxInjectedOutputCap
      : Math.min(configuredOutput, mtplxInjectedOutputCap);
    if (output.maxOutputTokens === opencodeDefault) {
      const context = positive(limit?.context);
      const mtplxReserve = context === null
        ? null
        : Math.min(mtplxInjectedOutputCap, Math.max(1, Math.floor(context / 2)));
      const requested = positive(Number(input?.model?.headers?.[mtplxRequestedOutputHeader]));
      output.maxOutputTokens = requested
        ?? (configuredOutput !== null && configuredOutput !== mtplxReserve
          ? configuredOutput
          : undefined);
    }
    // OpenCode <= 1.18.20 (Desktop 1.18.18 included) injects a qwen-keyed
    // sampler (temperature 0.55, topP 1) for any model id containing
    // "qwen"; 1.18.21 removed the rule. Strip exactly that injected pair so
    // the MTPLX server's family-native sampler applies; any other value is
    // a deliberate client choice and passes through untouched.
    const modelID = String(input?.model?.id ?? input?.model?.modelID ?? "").toLowerCase();
    if (modelID.includes("qwen")) {
      if (output.temperature === mtplxInjectedQwenTemperature) {
        output.temperature = undefined;
      }
      if (output.topP === mtplxInjectedQwenTopP) {
        output.topP = undefined;
      }
    }
  }
});
export default MTPLXSessionHeaders;
MTPLX_PLUGIN_INDEX

cat > "$PLUGIN_DIR/server.js" <<'MTPLX_PLUGIN_SERVER'
// Older V1 imports index.js; modern V1 and V2 resolve this entrypoint.
// No prompt, tool-schema or generation-option rewriting belongs here.
import { MTPLXSessionHeaders } from "./index.js";
export default {
  id: "mtplx.session-headers",
  server: MTPLXSessionHeaders,
  async setup(ctx) {
    const handler = (event) => {
      event.headers["x-mtplx-client"] = "opencode";
      event.headers["x-mtplx-session-id"] = String(event.sessionID);
      if (event.kind) event.headers["x-mtplx-request-kind"] = String(event.kind);
    };
    for (const providerID of ["mtplx", "mtplx-27b", "mtplx-35b", "mtplx-inkling", "mtplx-flashnext"]) {
      await ctx.session.hook("model.request", handler, { providerID });
    }
  }
};
MTPLX_PLUGIN_SERVER

cat > "$PLUGIN_DIR/package.json" <<'MTPLX_PLUGIN_PKG'
{
  "name": "mtplx-session-headers",
  "private": true,
  "type": "module",
  "main": "./index.js",
  "exports": {
    ".": "./index.js",
    "./server": "./server.js"
  }
}
MTPLX_PLUGIN_PKG

ok "plugin written to $PLUGIN_DIR"

# ---------------------------------------------------------------------------
# 4. opencode.jsonc
# ---------------------------------------------------------------------------
step "4/4  Write OpenCode config"
CONFIG_DIR="$HOME/.config/opencode"
CONFIG="$CONFIG_DIR/opencode.jsonc"
mkdir -p "$CONFIG_DIR"

if [ -f "$CONFIG" ]; then
  BACKUP="${CONFIG}.bak-$(date +%Y%m%d-%H%M%S)"
  n=1
  while [ -e "$BACKUP" ]; do BACKUP="${CONFIG}.bak-$(date +%Y%m%d-%H%M%S)-$n"; n=$((n+1)); done
  cp -p "$CONFIG" "$BACKUP"
  info "backed up existing config → $BACKUP"
fi

# Generate/merge the config in Python (handles JSONC comments + trailing commas).
# Discovers model IDs from the host at install time via /router/models (no auth).
python3 - "$BASE" "$KEY" "$PLUGIN_DIR" "$CONFIG" "$FRESH" <<'MTPLX_CFG'
import json, os, sys, urllib.request, urllib.error

base, key, plugin_path, cfg_path, fresh_s = sys.argv[1:6]
fresh = fresh_s == "1"   # argv strings are truthy in Python; parse explicitly
base = base.rstrip("/")

# ---------------------------------------------------------------------------
# Discover model IDs from the host (public endpoint, no auth required).
# ---------------------------------------------------------------------------
def fetch_models():
    url = f"{base}/router/models"
    try:
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read())
    except Exception as exc:
        print(f"ERROR: cannot reach {url}: {exc}", file=sys.stderr)
        print("The host is not reachable — model IDs cannot be discovered.", file=sys.stderr)
        print("Make sure the host is online and the Tailscale URL is correct.", file=sys.stderr)
        sys.exit(1)

models_resp = fetch_models()
model_map = {p["prefix"]: p for p in models_resp["providers"]}

# ---------------------------------------------------------------------------
# Strip // and /* */ comments (string-aware) and trailing commas (string-aware).
# ---------------------------------------------------------------------------
def strip_jsonc(text: str) -> str:
    out, i, n = [], 0, len(text)
    in_str = esc = False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True; out.append(c); i += 1; continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            i += 2
            while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                i += 1
            i += 2
            continue
        if c == ",":
            j = i + 1
            while j < n and text[j] in " \t\r\n":
                j += 1
            if j < n and text[j] in "}]":
                i += 1          # drop trailing comma
                continue
        out.append(c); i += 1
    return "".join(out)

def load():
    if os.path.exists(cfg_path):
        try:
            with open(cfg_path) as f:
                return json.loads(strip_jsonc(f.read()))
        except Exception:
            return None
    return None

# Build provs from discovered model IDs.
provs = {}
for prefix, name, mid_key, display_key in [
    ("mtplx",           "MTPLX (Qwen3.5 9B)",                "id",  "Qwen3.5-9B-MTPLX-Optimized-Speed"),
    ("mtplx-27b",       "MTPLX (Qwen3.8 27B)",               "id",  "Qwen3.8-27B-MTPLX-Optimized-Speed"),
    ("mtplx-35b",       "MTPLX (Qwen3.6 35B-A3B)",           "id",  "Qwen3.6-35B-A3B-MTPLX-Optimized-Balance"),
    ("mtplx-inkling",   "MTPLX (Inkling 2 Mini)",            "id",  "Inkling-2-Mini-MTPLX-Optimized-Quality"),
    ("mtplx-flashnext", "MTPLX (Qwen3.8 Flash-Next 125B-A6B)","id",  "Qwen3.8-Flash-Next-MTPLX-Bare-Speed"),
]:
    p = model_map[prefix]
    provs[prefix] = (name, p[mid_key], display_key)

def provider(pid, name, mid, display):
    return {
        "name": name,
        "package": "@opencode/ai/providers/openai-compatible",
        "settings": {
            "baseURL": f"{base}/{pid}/v1",
            "apiKey": key,
            "timeout": False,
            "chunkTimeout": 900000,
        },
        "headers": {"x-mtplx-client": "opencode"},
        "models": {
            mid: {
                "name": display,
                "compatibility": {"reasoningField": "reasoning_content"},
                "capabilities": {
                    "tools": True,
                    "input": ["text", "image"],
                    "output": ["text"],
                    "reasoning": {"supported": True},
                },
                "limit": {"context": 65536, "output": 16384},
            }
        },
    }

cfg = {} if fresh else (load() or {})
providers = cfg.get("providers", {})
for pid, (name, mid, display) in provs.items():
    providers[pid] = provider(pid, name, mid, display)
cfg["providers"] = providers

cfg.setdefault("$schema", "https://opencode.ai/config.json")
cfg["model"] = "mtplx-27b/mtplx-qwen38-27b-optimized-speed"
cfg["compaction"] = {"auto": True, "buffer": "25%"}
cfg["agents"] = {
    "general": {"mode": "subagent", "model": "mtplx/mtplx-qwen35-9b-optimized-speed"},
    "explore": {"mode": "subagent", "model": "mtplx/mtplx-qwen35-9b-optimized-speed"},
}
plugins = cfg.get("plugins", [])
if plugin_path not in plugins:
    plugins.append(plugin_path)
cfg["plugins"] = plugins

with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(f"wrote {cfg_path}")
MTPLX_CFG

ok "config written to $CONFIG"
if [ "$FRESH" = "1" ]; then
  info "mode: --fresh (MTPLX-only config; other providers, if any, are in the backup)."
else
  info "mode: merge (your other providers, if any, were preserved)."
fi

# ---------------------------------------------------------------------------
# 5. Tailscale login
# ---------------------------------------------------------------------------
step "Log in to Tailscale"
if ! command -v tailscale >/dev/null 2>&1; then
  # The Tailscale cask may place the CLI in several locations.
  # Try them all, then fall back to a broad find.
  found_ts=0

  # 1. Homebrew bin (wrapper script or symlink)
  for candidate in /opt/homebrew/bin/tailscale /usr/local/bin/tailscale; do
    if [ -x "$candidate" ]; then
      export PATH="$(dirname "$candidate"):$PATH"
      found_ts=1
      break
    fi
  done

  # 2. Inside the app bundle (Apple Silicon cask layout)
  if [ "$found_ts" -eq 0 ]; then
    for candidate in \
      /opt/homebrew/Caskroom/tailscale/*/Tailscale.app/Contents/MacOS/tailscale \
      /usr/local/Caskroom/tailscale/*/Tailscale.app/Contents/MacOS/tailscale; do
      if [ -x "$candidate" ]; then
        export PATH="$(dirname "$candidate"):$PATH"
        found_ts=1
        break
      fi
    done
  fi

  # 3. Broad find in common Tailscale install dirs
  if [ "$found_ts" -eq 0 ]; then
    for dir in /Applications/Tailscale.app/Contents/MacOS \
               /Applications/Tailscale.app/Contents/Resources \
               /opt/homebrew/Cellar/tailscale; do
      if [ -d "$dir" ]; then
        found=$(find "$dir" -maxdepth 1 -name tailscale -type f -executable 2>/dev/null | head -1)
        if [ -n "$found" ]; then
          export PATH="$(dirname "$found"):$PATH"
          found_ts=1
          break
        fi
      fi
    done
  fi

  if [ "$found_ts" -eq 0 ]; then
    warn "tailscale CLI not found on PATH."
    info "Open the Tailscale app, then re-run this script — it is idempotent."
    exit 0
  fi
  ok "Found tailscale CLI (added to PATH)"
fi

ts_status() { tailscale status 2>&1 || true; }
# 0 = logged in, 1 = logged out, 2 = daemon unreachable
ts_state() {
  local out
  out="$(ts_status)"
  if printf '%s' "$out" | grep -qiE 'could not connect|no such file|connection refused'; then
    echo 2
  elif printf '%s' "$out" | grep -qi 'logged out'; then
    echo 1
  else
    echo 0
  fi
}

case "$(ts_state)" in
  1)  # logged out → run `tailscale up`, print the one-time URL, wait
    info "Starting 'tailscale up' — this prints a one-time login URL."
    TS_UP_LOG="$(mktemp -t mtplx-ts-up.XXXXXX)"
    tailscale up --hostname="$HOSTNAME" >"$TS_UP_LOG" 2>&1 &
    UP_PID=$!
    URL=""
    for _ in $(seq 1 30); do
      URL="$(grep -oE 'https://login\.tailscale\.com/[A-Za-z0-9/_-]+' "$TS_UP_LOG" | head -1 || true)"
      [ -n "$URL" ] && break
      kill -0 "$UP_PID" 2>/dev/null || break
      sleep 1
    done
    if [ -n "$URL" ]; then
      say ""
      say "  Open this URL in your browser and log in (one time):"
      say "      $URL"
      say "  (If it looks expired, re-run this script — it is idempotent.)"
      say ""
    else
      warn "No login URL appeared yet; check the Tailscale app in the menu bar."
    fi
    info "Waiting for you to complete the login (up to ~10 minutes)…"
    logged=0
    for _ in $(seq 1 300); do
      [ "$(ts_state)" = "0" ] && { logged=1; break; }
      sleep 2
    done
    wait "$UP_PID" 2>/dev/null || true
    rm -f "$TS_UP_LOG"
    if [ "$logged" = "1" ]; then
      ok "Tailscale is logged in. This machine is on the tailnet."
      tailscale status | sed 's/^/    /' || true
    else
      warn "Not logged in yet. Complete the login, then re-run this script"
      warn "(everything else is already installed, so it will just verify)."
      exit 0
    fi
    ;;
  2)
    warn "The Tailscale daemon is not reachable yet."
    warn "Open the Tailscale app (menu-bar icon), give it a moment, then re-run."
    exit 0
    ;;
  *)
    ok "Tailscale is already logged in."
    ;;
esac

# ---------------------------------------------------------------------------
# 6. Verify
# ---------------------------------------------------------------------------
if [ "$NO_VERIFY" = "1" ]; then
  step "Verify (skipped)"
  info "--no-verify set."
else
  step "Verify the connection"
  say "  GET $BASE/health"
  if health="$(curl -fsS -m 15 "$BASE/health" 2>&1)"; then
    ok "router reachable: $health"
  else
    err "could not reach the router at $BASE/health"
    err "  → is the host's Mac on? did it run 'tailscale serve --bg http://127.0.0.1:8100'?"
    err "  → is this machine in the same tailnet?"
  fi

  say "  GET $BASE/mtplx-27b/v1/models   (with your key)"
  if models="$(curl -fsS -m 20 -H "Authorization: Bearer $KEY" "$BASE/mtplx-27b/v1/models" 2>&1)"; then
    ok "key accepted — model list:"
    printf '%s' "$models" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
    for m in d.get("data",[]): print("    - "+m.get("id","?"))
except Exception: print("    "+models[:200])'
  else
    err "the router rejected the key (or the 27B path is down)."
    err "  → check the key; the host revokes with './mtplx-router.sh key rm <name>'."
  fi
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
say ""
say "All done. Next:"
say "  1. Open a new terminal (so OpenCode is on PATH), then in any project:"
say "         opencode"
say "  2. It starts on MTPLX 27B by default; switch with /models, subagents run on 9B."
say ""
info "Your API key and the host URL live in $CONFIG"
info "Re-run this script any time to re-verify or repair the setup."
