#Requires -Version 5.1
<#
.SYNOPSIS
    One-shot installer for the MTPLX *client* side of the shared-models setup.
.DESCRIPTION
    Run this on each remote person's Windows machine. It does everything a
    remote user needs to use the five MTPLX models through their own local
    OpenCode, over Tailscale:

      1. Installs Tailscale            (winget install --id Tailscale.Tailscale)
      2. Installs OpenCode             (standalone Windows zip to ~/.opencode/bin)
      3. Installs both plugins: mtplx-session-headers (routing fixes) and
         mtplx-image-generation (a `generate_image` tool that calls the
         host's image job service — nothing model-related is installed here)
      4. Writes ~/.config/opencode/opencode.jsonc so all five MTPLX providers
         point at the host's Tailscale URL with your personal API key
      5. Logs Tailscale in (prints a URL you click exactly once)

    Only prompts and streamed completion tokens cross the wire — the session,
    files and tool output stay on this machine. That is what keeps it usable on a
    slow uplink.
.PARAMETER Base
    The host's Tailscale origin, no trailing path.
    (e.g. https://<host-tailnet-name>.ts.net)
.PARAMETER Key
    Your personal MTPLX API key, generated on the host with
    `./mtplx-router.sh key add <name>`. Shown once there.
.PARAMETER Hostname
    Optional friendly Tailscale name for this machine (defaults to computer name).
.PARAMETER Fresh
    Write a clean MTPLX-only config instead of merging into any existing
    opencode.jsonc. (An existing file is always backed up first.)
.PARAMETER SkipTailscale
    Skip the Tailscale install step (useful for re-running after manual login).
.PARAMETER SkipOpencode
    Skip the OpenCode install step.
.PARAMETER SkipImage
    Do not install the image-generation plugin at all (by default it is
    installed and calls the host's image job service over Tailscale).
.PARAMETER NoVerify
    Skip the network verification at the end.
.PARAMETER Help
    Show help text and exit.
.EXAMPLE
    .\mtplx-client-install.ps1 -Base https://<host-tailnet-name>.ts.net -Key mtr_XXXX
.EXAMPLE
    .\mtplx-client-install.ps1 -Base https://<host-tailnet-name>.ts.net -Key mtr_XXXX -Hostname alice-pc -Fresh
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, HelpMessage="Host's Tailscale URL, e.g. https://<host-tailnet-name>.ts.net")]
    [string]$Base,

    [Parameter(Mandatory=$true, HelpMessage="Your personal MTPLX API key")]
    [string]$Key,

    [Parameter(HelpMessage="Friendly Tailscale hostname (default: computer name)")]
    [string]$Hostname = "",

    [Parameter(HelpMessage="Write a clean MTPLX-only config instead of merging")]
    [switch]$Fresh,

    [Parameter(HelpMessage="Skip Tailscale install step")]
    [switch]$SkipTailscale,

    [Parameter(HelpMessage="Skip OpenCode install step")]
    [switch]$SkipOpencode,

    [Parameter(HelpMessage="Do not install the image-generation plugin at all")]
    [switch]$SkipImage,

    [Parameter(HelpMessage="Skip network verification at the end")]
    [switch]$NoVerify
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Pretty output helpers
# ---------------------------------------------------------------------------
function Say($text)  { Write-Output $text }
function Ok($text)   { Write-Output "  [OK] $text" }
function Info($text) { Write-Output "  [.] $text" }
function Warn($text) { Write-Output "  [!] $text" }
function Err($text)  { Write-Output "  [x] $text" -ErrorAction Continue }
function Step($text) { Write-Output "`n== $text ==" }

function Get-HelpText {
    Get-Help $MyInvocation.MyCommand.Path -Examples | Out-String | Write-Output
    Write-Output ""
    Write-Output "Usage: .\mtplx-client-install.ps1 -Base <url> -Key <key> [-Hostname <name>] [-Fresh]"
    Write-Output ""
    Write-Output "  -Base        Required. Host's Tailscale URL (no trailing slash)."
    Write-Output "  -Key         Required. Your personal MTPLX API key."
    Write-Output "  -Hostname    Optional. Tailscale name for this machine."
    Write-Output "  -Fresh       Write a clean config instead of merging."
    Write-Output "  -SkipTailscale  Skip Tailscale install."
    Write-Output "  -SkipOpencode   Skip OpenCode install."
    Write-Output "  -SkipImage      Do not install the image-generation plugin at all."
    Write-Output "  -NoVerify      Skip network verification."
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Test-Command($name) {
    return $null -ne (Get-Command $name -ErrorAction SilentlyContinue)
}

function Test-PathWritable($path) {
    try {
        $testFile = Join-Path $path "$([System.IO.Path]::GetRandomFileName())"
        [System.IO.File]::Create($testFile).Dispose()
        Remove-Item $testFile -Force -ErrorAction SilentlyContinue
        return $true
    } catch { return $false }
}

# ---------------------------------------------------------------------------
# Arguments (legacy --Base / --Key support)
# ---------------------------------------------------------------------------
if ($PSCmdlet.ParameterSetName -eq "") {
    $args = $args -replace '^--', '-'
    $Base = ""; $Key = ""
    for ($i = 0; $i -lt $args.Count; $i++) {
        switch ($args[$i]) {
            "-Base"         { $Base = $args[++$i]; break }
            "-Key"          { $Key = $args[++$i]; break }
            "-Hostname"     { $Hostname = $args[++$i]; break }
            "-Fresh"        { $Fresh = $true; break }
            "-SkipTailscale"{ $SkipTailscale = $true; break }
            "-SkipOpencode" { $SkipOpencode = $true; break }
            "-SkipImage"    { $SkipImage = $true; break }
            "-NoVerify"     { $NoVerify = $true; break }
            "-h", "-Help"   { Get-HelpText; exit 0 }
            default         { Err "unknown argument: $($args[$i])"; Get-HelpText; exit 2 }
        }
    }
    if (-not $Base -or -not $Key) {
        Err "both -Base and -Key are required."
        Get-HelpText
        exit 2
    }
}

# Tailscale hostname defaults to the computer's name.
if (-not $Hostname) {
    try {
        $Hostname = (Get-CimInstance Win32_ComputerSystem).Name
    } catch {
        $Hostname = $env:COMPUTERNAME
    }
}
$Hostname = $Hostname -replace '[^a-z0-9-]', '-' -replace '-+$', '' -replace '^-', ''
if ($Hostname.Length -gt 63) { $Hostname = $Hostname.Substring(0, 63) }
if ($Hostname.Length -lt 1) { $Hostname = "mtplx-client" }

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$HOME_DIR = $env:USERPROFILE
$OC_DIR = Join-Path $HOME_DIR ".config"
$OC_CONFIG_DIR = Join-Path $OC_DIR "opencode"
$OC_CONFIG_FILE = Join-Path $OC_CONFIG_DIR "opencode.jsonc"
$OC_BIN_DIR = Join-Path $HOME_DIR ".opencode"
$OC_BIN = Join-Path $OC_BIN_DIR "opencode.exe"
$PLUGIN_DIR = Join-Path $OC_CONFIG_DIR "plugins" "mtplx-session-headers"
$PLUGIN_INDEX = Join-Path $PLUGIN_DIR "index.js"
$PLUGIN_SERVER = Join-Path $PLUGIN_DIR "server.js"
$PLUGIN_PKG = Join-Path $PLUGIN_DIR "package.json"
$IMAGE_PLUGIN_DIR = Join-Path $OC_CONFIG_DIR "plugins" "mtplx-image-generation"
$IMAGE_PLUGIN_INDEX = Join-Path $IMAGE_PLUGIN_DIR "index.js"
$IMAGE_PLUGIN_PKG = Join-Path $IMAGE_PLUGIN_DIR "package.json"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
Step "Preflight"

# Windows check
$os = (Get-CimInstance Win32_OperatingSystem).Caption
if ($os -notmatch "Windows") {
    Err "This installer is for Windows only. Current OS: $os"
    exit 1
}
Ok "Windows detected"

# Need curl (or at least Invoke-WebRequest) and python3
if (-not (Test-Command "curl")) {
    Err "curl is required. Install it or run from PowerShell 7+ (it ships curl)."
    exit 1
}
Ok "curl available"

if (-not (Test-Command "python3")) {
    Err "python3 is required for config generation. Install Python from python.org or via winget install Python.Python.3.12"
    exit 1
}
Ok "python3 available"

# Check admin for winget / system-level installs
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if ($isAdmin) {
    Ok "Running as Administrator"
} else {
    Warn "Not running as Administrator — some steps may require elevation"
}

# ---------------------------------------------------------------------------
# Step 1/5: Install Tailscale
# ---------------------------------------------------------------------------
if ($SkipTailscale) {
    Step "1/5  Install Tailscale (skipped)"
    Info "-SkipTailscale set."
} else {
    Step "1/5  Install Tailscale"

    if (Test-Command "tailscale") {
        Ok "Tailscale CLI already installed"
    } else {
        Info "Installing Tailscale via winget..."
        $wingetResult = winget install --id Tailscale.Tailscale --accept-source-agreements --accept-package-agreements 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0 -or $wingetResult -match "Successfully installed") {
            Ok "Tailscale installed"
        } else {
            # Try alternate ID
            Info "Trying alternate winget ID..."
            $wingetResult = winget install --id Tailscale.Winget --accept-source-agreements --accept-package-agreements 2>&1 | Out-String
            if ($LASTEXITCODE -eq 0 -or $wingetResult -match "Successfully installed") {
                Ok "Tailscale installed (alternate ID)"
            } else {
                Err "winget install failed. Install Tailscale manually from https://tailscale.com/download/windows"
                Err $wingetResult
                exit 1
            }
        }

        # Refresh PATH for tailscale.exe
        $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "User") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "Machine")
        if (-not (Test-Command "tailscale")) {
            # Check common install locations
            $tsExe = "$env:ProgramFiles\Tailscale\Tailscale.exe"
            if (Test-Path $tsExe) {
                # Create a shim in a PATH location
                $shimDir = Join-Path $HOME_DIR ".opencode" "bin"
                if (-not (Test-Path $shimDir)) { New-Item -ItemType Directory -Path $shimDir -Force | Out-Null }
                $shimPath = Join-Path $shimDir "tailscale.cmd"
                @"
@"$tsExe" %*
"@ | Set-Content $shimPath -Encoding UTF8
                $env:PATH = "$shimDir;$env:PATH"
                Ok "Tailscale shim created at $shimPath"
            } else {
                Err "Tailscale installed but CLI not found. Try restarting your terminal."
                exit 1
            }
        }
        Ok "Tailscale CLI available"
    }
}

# ---------------------------------------------------------------------------
# Step 2/5: Install OpenCode
# ---------------------------------------------------------------------------
if ($SkipOpencode) {
    Step "2/5  Install OpenCode (skipped)"
    Info "-SkipOpencode set."
} else {
    Step "2/5  Install OpenCode"

    if (Test-Path $OC_BIN) {
        $ver = & $OC_BIN --version 2>&1 | Select-String -Pattern "opencode" | Select-Object -First 1
        Ok "OpenCode already installed: $ver"
    } else {
        Info "Downloading OpenCode for Windows..."

        # Detect architecture
        $arch = "x64"
        if ([Environment]::Is64BitOperatingSystem) {
            $procArch = (Get-CimInstance Win32_Processor).Architecture | Select-Object -First 1
            # 9 = x64, 12 = ARM64
            if ($procArch -eq 12) { $arch = "arm64" }
        }

        $downloadUrl = "https://github.com/sst/opencode/releases/latest/download/opencode_windows_${arch}.zip"
        $tempZip = Join-Path $env:TEMP "opencode-windows-${arch}.zip"

        Info "URL: $downloadUrl"
        Info "Architecture: $arch"

        try {
            # Download
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $downloadUrl -OutFile $tempZip -UseBasicParsing
            Ok "Downloaded ($([math]::Round((Get-Item $tempZip).Length / 1MB, 1)) MB)"

            # Create bin directory
            if (-not (Test-Path $OC_BIN_DIR)) {
                New-Item -ItemType Directory -Path $OC_BIN_DIR -Force | Out-Null
            }

            # Extract
            $extractDir = Join-Path $env:TEMP "opencode-extract"
            if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
            New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
            Expand-Archive -Path $tempZip -DestinationPath $extractDir -Force

            # Find the binary (may be in a subfolder)
            $exeFiles = Get-ChildItem $extractDir -Filter "opencode.exe" -Recurse
            if ($exeFiles.Count -eq 0) {
                Err "No opencode.exe found in downloaded zip"
                exit 1
            }

            $srcExe = $exeFiles[0].FullName
            Copy-Item $srcExe $OC_BIN -Force
            Ok "Extracted to $OC_BIN"

            # Cleanup
            Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
            Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue

            # Add to user PATH if not already there
            $userPath = [System.Environment]::GetEnvironmentVariable("PATH", "User")
            if ($userPath -notmatch [regex]::Escape($OC_BIN_DIR)) {
                [System.Environment]::SetEnvironmentVariable("PATH", "$userPath;$OC_BIN_DIR", "User")
                $env:PATH = "$userPath;$OC_BIN_DIR"
                Ok "Added to PATH"
            }
        } catch {
            Err "Failed to download/install OpenCode: $_"
            exit 1
        }
    }
}

# ---------------------------------------------------------------------------
# Step 3/5: Install MTPLX plugins
#
#   • mtplx-session-headers  (routing fixes)
#   • mtplx-image-generation (generate_image via the host's job service)
#
# Both talk to the host over Tailscale, so a cheap Windows box works fine:
# nothing model-related is installed on this machine.
# ---------------------------------------------------------------------------
Step "3/5  Install MTPLX plugins"

if (Test-Path $PLUGIN_INDEX) {
    Ok "mtplx-session-headers already installed"
} else {
    Info "Installing mtplx-session-headers..."

    if (-not (Test-Path $PLUGIN_DIR)) {
        New-Item -ItemType Directory -Path $PLUGIN_DIR -Force | Out-Null
    }

    # package.json — byte-identical to macOS version
    @"
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
"@ | Set-Content $PLUGIN_PKG -Encoding UTF8

    # index.js — OpenCode plugin entry point (byte-identical to macOS)
    @"
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
"@ | Set-Content $PLUGIN_INDEX -Encoding UTF8

    # server.js — server-side hooks (byte-identical to macOS)
    @"
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
"@ | Set-Content $PLUGIN_SERVER -Encoding UTF8

    Ok "Plugin installed to $PLUGIN_DIR"
}

if ($SkipImage) {
    Info "-SkipImage set: image-generation plugin not installed."
} else {
    if (-not (Test-Path $IMAGE_PLUGIN_DIR)) {
        New-Item -ItemType Directory -Path $IMAGE_PLUGIN_DIR -Force | Out-Null
    }

    # index.js — an HTTP client for the host's image job service. Written
    # from a non-expanding here-string, then __MTPLX_BASE__ and
    # __MTPLX_KEY__ are replaced with this host's URL and this user's key.
    $imgIndex = @'
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
// one sees its queue position here through context.progress; the file lands
// where the user asks (default ~/.mtplx/h3-image-mlx/out/ on this machine).
// No local model, no Apple Silicon needed — this works the same on Windows.
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

          // 3. Download the PNG to the requested path (default out dir).
          const wantPath =
            typeof input.output_path === "string" && input.output_path.trim()
              ? input.output_path.trim().replace(/^~/, os.homedir())
              : "";
          const stamp = new Date().toISOString().replace(/[-:T]/g, "").slice(0, 14);
          const generated = `h3-${stamp}-${Math.random().toString(36).slice(2, 6)}.png`;
          const asDir =
            wantPath.endsWith("/") ||
            wantPath.endsWith(path.sep) ||
            !wantPath.toLowerCase().endsWith(".png");
          const outPath = wantPath
            ? path.resolve(
                asDir
                  ? path.join(path.resolve(os.homedir(), wantPath), generated)
                  : path.resolve(os.homedir(), wantPath),
              )
            : path.join(OUT_DIR, generated);
          await mkdir(path.dirname(outPath), { recursive: true });
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
'@

    $imgPkg = @'
{
  "name": "mtplx-image-generation",
  "private": true,
  "type": "module",
  "main": "./index.js",
  "exports": {
    ".": "./index.js"
  }
}
'@

    $imgIndex = $imgIndex.Replace("__MTPLX_BASE__", $Base).Replace("__MTPLX_KEY__", $Key)
    if ($imgIndex -match '__MTPLX_') {
        Err "placeholder substitution failed in the image plugin."
        exit 1
    }
    Set-Content -Path $IMAGE_PLUGIN_INDEX -Value $imgIndex -Encoding UTF8
    Set-Content -Path $IMAGE_PLUGIN_PKG -Value $imgPkg -Encoding UTF8
    Ok "plugin written to $IMAGE_PLUGIN_DIR (host: $Base/image)"
}

# ---------------------------------------------------------------------------
# Step 4/5: Write OpenCode config
# ---------------------------------------------------------------------------
Step "4/5  Write OpenCode config"

# Ensure directories exist
if (-not (Test-Path $OC_CONFIG_DIR)) {
    New-Item -ItemType Directory -Path $OC_CONFIG_DIR -Force | Out-Null
}

# Backup existing config if present
$backupFile = $null
if (Test-Path $OC_CONFIG_FILE) {
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupFile = "$OC_CONFIG_FILE.bak-$timestamp"
    $n = 1
    while (Test-Path $backupFile) {
        $backupFile = "$OC_CONFIG_FILE.bak-$timestamp-$n"
        $n++
    }
    Copy-Item $OC_CONFIG_FILE $backupFile -Force
    Info "Backed up existing config → $(Split-Path $backupFile -Leaf)"
}

# Generate/merge the config in Python3 (handles JSONC comments + trailing commas,
# same logic as the macOS script).  We pass arguments via env vars to avoid
# quoting issues with PowerShell here-strings.
Info "Generating opencode.jsonc..."

$env:MTPLX_BASE = $Base
$env:MTPLX_KEY = $Key
$env:MTPLX_PLUGIN_DIR = $PLUGIN_DIR
$env:MTPLX_CFG_FILE = $OC_CONFIG_FILE
$env:MTPLX_FRESH = if ($Fresh) { "1" } else { "0" }
$env:MTPLX_IMAGE_PLUGIN_DIR = $IMAGE_PLUGIN_DIR
$env:MTPLX_SKIP_IMG = if ($SkipImage) { "1" } else { "0" }

$pythonScript = @'
import json, os, sys, urllib.request, urllib.error

base = os.environ["MTPLX_BASE"].rstrip("/")
key = os.environ["MTPLX_KEY"]
plugin_path = os.environ["MTPLX_PLUGIN_DIR"]
cfg_path = os.environ["MTPLX_CFG_FILE"]
fresh = os.environ.get("MTPLX_FRESH", "0") == "1"
image_plugin_path = os.environ["MTPLX_IMAGE_PLUGIN_DIR"]
skip_img = os.environ.get("MTPLX_SKIP_IMG", "1")


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


def strip_jsonc(text):
    """Strip // and /* */ comments and trailing commas, string-aware."""
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
            in_str = True
            out.append(c)
            i += 1
            continue
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
                i += 1
                continue
        out.append(c)
        i += 1
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
for prefix, name, display_key in [
    ("mtplx",           "MTPLX (Qwen3.5 9B)",                "Qwen3.5-9B-MTPLX-Optimized-Speed"),
    ("mtplx-27b",       "MTPLX (Qwen3.8 27B)",               "Qwen3.8-27B-MTPLX-Optimized-Speed"),
    ("mtplx-35b",       "MTPLX (Qwen3.6 35B-A3B)",           "Qwen3.6-35B-A3B-MTPLX-Optimized-Balance"),
    ("mtplx-inkling",   "MTPLX (Inkling 2 Mini)",            "Inkling-2-Mini-MTPLX-Optimized-Quality"),
    ("mtplx-flashnext", "MTPLX (Qwen3.8 Flash-Next 125B-A6B)","Qwen3.8-Flash-Next-MTPLX-Bare-Speed"),
]:
    p = model_map[prefix]
    provs[prefix] = (name, p["id"], display_key)


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
# Only list the image plugin when it was actually installed (or kept from
# an earlier run with it present on disk).
if skip_img == "0" or os.path.isdir(image_plugin_path):
    if image_plugin_path not in plugins:
        plugins.append(image_plugin_path)
else:
    plugins = [p for p in plugins if p != image_plugin_path]
cfg["plugins"] = plugins

with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")

print("wrote " + cfg_path)
'@

$pythonScriptFile = Join-Path $env:TEMP "mtplx-config-gen.py"
$pythonScript | Set-Content $pythonScriptFile -Encoding UTF8

try {
    $pyResult = python3 $pythonScriptFile 2>&1
    if ($LASTEXITCODE -eq 0) {
        Ok "Config written to $OC_CONFIG_FILE"
        if ($Fresh) {
            Info "mode: -Fresh (MTPLX-only config; other providers, if any, are in the backup)."
        } else {
            Info "mode: merge (your other providers, if any, were preserved)."
        }
    } else {
        Err "Python config generation failed: $pyResult"
        Err "Falling back to fresh config..."
        # Fallback: write a minimal config
        $fallback = @"
{
  "providers": {
    "mtplx": {
      "name": "MTPLX (Qwen3.5 9B)",
      "package": "@opencode/ai/providers/openai-compatible",
      "settings": {
        "baseURL": "$Base/mtplx/v1",
        "apiKey": "$Key"
      },
      "models": {
        "mtplx-qwen35-9b-optimized-speed": {
          "name": "Qwen3.5-9B-MTPLX-Optimized-Speed",
          "limit": {"context": 65536, "output": 16384}
        }
      }
    }
  },
  "compaction": {"auto": true, "buffer": "25%"},
  "plugins": ["$PLUGIN_DIR"]
}
"@
        $fallback | Set-Content $OC_CONFIG_FILE -Encoding UTF8
        Ok "Wrote fallback config"
    }
} finally {
    Remove-Item $pythonScriptFile -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Step 5/5: Log in to Tailscale
# ---------------------------------------------------------------------------
Step "5/5  Log in to Tailscale"

if (-not (Test-Command "tailscale")) {
    # winget may place tailscale.exe in Program Files without refreshing PATH.
    $tsExe = "$env:ProgramFiles\Tailscale\Tailscale.exe"
    $shimDir = Join-Path $HOME_DIR ".opencode" "bin"
    $shimPath = Join-Path $shimDir "tailscale.cmd"
    if (Test-Path $tsExe) {
        if (-not (Test-Path $shimDir)) { New-Item -ItemType Directory -Path $shimDir -Force | Out-Null }
        Set-Content $shimPath "@`"$tsExe`" %*" -Encoding UTF8
        $env:PATH = "$shimDir;$env:PATH"
        Ok "Created tailscale shim"
    } else {
        Warn "tailscale CLI not found on PATH."
        Info "Open the Tailscale app, then re-run this script — it is idempotent."
        exit 0
    }
}

# 0 = logged in, 1 = logged out, 2 = daemon unreachable
function Get-TailscaleState {
    $out = (tailscale status 2>&1 | Out-String)
    if ($out -match "could not connect|no such file|connection refused|not running") { return 2 }
    if ($out -match "logged out") { return 1 }
    return 0
}

switch (Get-TailscaleState) {
    1 {
        # logged out → run `tailscale up`, print the one-time URL, wait
        Info "Starting 'tailscale up' — this prints a one-time login URL."
        $tsUpLog = Join-Path $env:TEMP "mtplx-ts-up.log"
        $proc = Start-Process -FilePath "tailscale" -ArgumentList "up", "--hostname=$Hostname" -NoNewWindow -PassThru -RedirectStandardOutput $tsUpLog
        $url = ""
        for ($i = 0; $i -lt 30; $i++) {
            if (Test-Path $tsUpLog) {
                $content = Get-Content $tsUpLog -Raw -ErrorAction SilentlyContinue
                if ($content -match '(https://login\.tailscale\.com/[A-Za-z0-9/_-]+)') {
                    $url = $Matches[1]
                    break
                }
            }
            Start-Sleep -Seconds 1
            if (-not (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)) { break }
        }
        if ($url) {
            Write-Output ""
            Write-Output "  Open this URL in your browser and log in (one time):"
            Write-Output "      $url"
            Write-Output "  (If it looks expired, re-run this script — it is idempotent.)"
            Write-Output ""
            Start-Process $url 2>$null
        } else {
            Warn "No login URL appeared yet; check the Tailscale app in the system tray."
        }
        Info "Waiting for you to complete the login (up to ~10 minutes)…"
        $logged = 0
        for ($i = 0; $i -lt 300; $i++) {
            $check = tailscale status 2>&1 | Out-String
            if ($check -notmatch "logged out" -and $check -notmatch "NeedsLogin") {
                $logged = 1
                break
            }
            Start-Sleep -Seconds 2
        }
        Wait-Process -Id $proc.Id -ErrorAction SilentlyContinue
        Remove-Item $tsUpLog -ErrorAction SilentlyContinue
        if ($logged) {
            Ok "Tailscale is logged in. This machine is on the tailnet."
            tailscale status 2>&1 | ForEach-Object { "    $_" }
        } else {
            Warn "Not logged in yet. Complete the login, then re-run this script"
            Warn "(everything else is already installed, so it will just verify)."
            exit 0
        }
    }
    2 {
        Warn "The Tailscale daemon is not reachable yet."
        Warn "Open the Tailscale app (system-tray icon), give it a moment, then re-run."
        exit 0
    }
    default {
        Ok "Tailscale is already logged in."
    }
}

# ---------------------------------------------------------------------------
# Verify the connection
# ---------------------------------------------------------------------------
if ($NoVerify) {
    Step "Verify (skipped)"
    Info "-NoVerify set."
} else {
    Step "Verify the connection"

    # Check Tailscale connectivity
    Info "Checking Tailscale connectivity..."
    try {
        $health = curl -fsS -m 15 "${Base}/health" 2>&1
        if ($health) {
            Ok "Tailscale connectivity OK (health endpoint reachable)"
        } else {
            Warn "Health endpoint returned empty response"
        }
    } catch {
        Err "Cannot reach $Base/health — check Tailscale connection"
        Err $_
    }

    # Check model endpoint with key (Authorization: Bearer, matching macOS script)
    Info "Checking model endpoint with API key..."
    try {
        $models = curl -fsS -m 20 -H "Authorization: Bearer ${Key}" "${Base}/mtplx-27b/v1/models" 2>&1
        if ($models -match "mtplx-27b" -or $models -match "data") {
            Ok "key accepted — model list:"
            $models | python3 -c "import sys,json
try:
    d=json.load(sys.stdin)
    for m in d.get('data',[]): print('    - '+m.get('id','?'))
except Exception: print('    '+sys.stdin.read()[:200])" 2>$null
        } else {
            Warn "Model endpoint returned unexpected response: $models"
        }
    } catch {
        Err "the router rejected the key (or the 27B path is down)."
        Err "  → check the key; the host revokes with './mtplx-router.sh key rm <name>'."
    }

    Info "Checking the host-side image job service..."
    try {
        $imgHealth = curl -fsS -m 15 "${Base}/image/health" 2>&1
        if ($imgHealth) {
            Ok "image service reachable: $imgHealth"
        } else {
            Warn "Image service returned empty response at ${Base}/image/health."
        }
    } catch {
        Warn "Could not reach the image service at ${Base}/image/health."
        Warn "  → the host's mtplx-image service may not be running; generate_image"
        Warn "    will report that until the host restarts it."
    }

    # Verify OpenCode binary works
    if (Test-Path $OC_BIN) {
        try {
            $ocVer = & $OC_BIN --version 2>&1
            Ok "OpenCode works: $ocVer"
        } catch {
            Warn "OpenCode binary exists but may not run: $_"
        }
    }

    Step "Done"
    Write-Output ""
    Write-Output "All done. Next:"
    Write-Output "  1. Open a new terminal (so OpenCode is on PATH), then in any project:"
    Write-Output "         opencode"
    Write-Output "  2. It starts on MTPLX 27B by default; switch with /models,"
    Write-Output "     subagents run on 9B."
    Write-Output "  3. Ask it to generate an image — the generate_image tool runs"
    Write-Output "     on the host, so this machine never needs a model of its own."
    Write-Output ""
    Info "Your API key and the host URL live in $OC_CONFIG_FILE"
    Info "Re-run this script any time to re-verify or repair the setup."
    Write-Output ""
    Info "If you see 503 errors on the first Flash-Next request, that's normal"
    Info "(it loads ~99 GB and evicts other models). Subsequent requests will be fast."
    Write-Output ""
}
