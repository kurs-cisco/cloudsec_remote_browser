#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
TF_ROOT="${REPO_ROOT}/infra/terraform/aws-standalone-rbi"
DEFAULT_CONFIG="${TF_ROOT}/configs/development-ap-south-1.env"

CONFIG_FILE="${DEFAULT_CONFIG}"
CONFIG_FILE_SET=0
INSTANCE_ID="${RBI_WINDOWS_SSM_INSTANCE_ID:-${KURS_SSM_INSTANCE_ID:-}}"
RDP_USER="${RBI_WINDOWS_RDP_USER:-}"
PROOF_URL="${RBI_WINDOWS_VISUAL_PROOF_URL:-}"
PROXY_SERVER="${RBI_WINDOWS_PROOF_PROXY_SERVER:-}"
PROXY_BYPASS_LIST="${RBI_WINDOWS_PROOF_PROXY_BYPASS_LIST:-}"
IGNORE_CERT_ERRORS="${RBI_WINDOWS_PROOF_IGNORE_CERT_ERRORS:-0}"
S3_URI="${RBI_WINDOWS_PROOF_S3_URI:-}"
TASK_NAME="${RBI_WINDOWS_PROOF_TASK_NAME:-CloudsecRbiCurrentRdpVisualProof}"
ARTIFACT_ROOT="${RBI_WINDOWS_PROOF_ARTIFACT_ROOT:-C:\\ProgramData\\CloudsecRbi\\VisualProof}"
RUN_ID="${RBI_WINDOWS_PROOF_RUN_ID:-rbi-rdp-proof-$(date -u '+%Y%m%dT%H%M%SZ')}"
TIMEOUT_SECONDS="${RBI_WINDOWS_PROOF_TIMEOUT_SECONDS:-240}"
VIDEO_SECONDS="${RBI_WINDOWS_PROOF_VIDEO_SECONDS:-24}"
DEBUG_PORT="${RBI_WINDOWS_PROOF_DEBUG_PORT:-9229}"
REQUIRE_WEBRTC_STATS="${RBI_WINDOWS_REQUIRE_WEBRTC_STATS:-1}"
REQUIRE_INPUT_LATENCY="${RBI_WINDOWS_REQUIRE_INPUT_LATENCY:-1}"
INPUT_ACK_P95_MS="${RBI_WINDOWS_INPUT_ACK_P95_MS:-220}"
CLICK_APPLY_P95_MS="${RBI_WINDOWS_CLICK_APPLY_P95_MS:-120}"

usage() {
  cat <<'EOF'
Run current-RDP Windows visual proof through SSM.

The SSM command registers and starts a Windows Scheduled Task with LogonType
Interactive. The proof itself runs in the logged-in RDP user's desktop session,
captures screenshots, video, console/CDP events, WebRTC stats, and summary JSON,
and fails when the desktop is locked or required artifacts are missing.

Usage:
  scripts/rbi-windows-rdp-visual-proof.sh [config-file] [options]

Options:
  --config <path>          Shell env config to source.
  --instance-id <id>       Windows EC2 managed instance ID. Defaults to
                           RBI_WINDOWS_SSM_INSTANCE_ID or KURS_SSM_INSTANCE_ID.
  --rdp-user <user>        Interactive Windows user. If omitted, the script
                           selects the active user from quser output.
  --url <url>              Viewer/proof URL. Defaults to https://$RBI_DOMAIN/viewer.
  --proxy-server <value>   Optional Chrome proxy-server value, for example
                           "http=proxy.example:80;https=proxy.example:443".
  --proxy-bypass-list <v>  Optional Chrome proxy bypass list, semicolon-delimited.
  --ignore-cert-errors     Add Chrome --ignore-certificate-errors for proof-only
                           interception environments without trusted SWG roots.
  --s3-uri <s3://...>      Optional S3 prefix for persisted artifacts.
  --timeout-seconds <n>    Max wait for the scheduled task summary. Default: 240.
  --video-seconds <n>      Desktop video capture duration. Default: 24.
  --artifact-root <path>   Windows artifact root. Default: C:\ProgramData\CloudsecRbi\VisualProof.
  --debug-port <port>      Browser remote debugging port. Default: 9229.
  --input-ack-p95-ms <n>   Fail when captured input ACK p95 exceeds this budget.
                           Default: 220.
  --click-apply-p95-ms <n> Fail when click-to-apply p95 exceeds this budget.
                           Default: 120.
  -h, --help               Show help.

Required on the Windows host:
  - An active, unlocked RDP desktop for the selected user.
  - Chrome or Edge.
  - ffmpeg.exe on PATH for gdigrab video capture.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "${cmd}" >/dev/null 2>&1 || die "missing required command: ${cmd}"
  done
}

resolve_config_file() {
  local candidate="$1"
  local workspace_root
  workspace_root="$(cd -- "${REPO_ROOT}/.." && pwd)"

  [[ -n "${candidate}" ]] || die "empty config path"

  if [[ "${candidate}" == /* ]]; then
    printf '%s\n' "${candidate}"
  elif [[ -f "${candidate}" ]]; then
    printf '%s\n' "${candidate}"
  elif [[ -f "${REPO_ROOT}/${candidate}" ]]; then
    printf '%s\n' "${REPO_ROOT}/${candidate}"
  elif [[ -f "${workspace_root}/${candidate}" ]]; then
    printf '%s\n' "${workspace_root}/${candidate}"
  else
    printf '%s\n' "${candidate}"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      [[ $# -ge 2 ]] || die "--config requires a path"
      CONFIG_FILE="$(resolve_config_file "$2")"
      CONFIG_FILE_SET=1
      shift 2
      ;;
    --instance-id)
      [[ $# -ge 2 ]] || die "--instance-id requires a value"
      INSTANCE_ID="$2"
      shift 2
      ;;
    --rdp-user)
      [[ $# -ge 2 ]] || die "--rdp-user requires a value"
      RDP_USER="$2"
      shift 2
      ;;
    --url)
      [[ $# -ge 2 ]] || die "--url requires a value"
      PROOF_URL="$2"
      shift 2
      ;;
    --proxy-server)
      [[ $# -ge 2 ]] || die "--proxy-server requires a value"
      PROXY_SERVER="$2"
      shift 2
      ;;
    --proxy-bypass-list)
      [[ $# -ge 2 ]] || die "--proxy-bypass-list requires a value"
      PROXY_BYPASS_LIST="$2"
      shift 2
      ;;
    --ignore-cert-errors)
      IGNORE_CERT_ERRORS=1
      shift
      ;;
    --s3-uri)
      [[ $# -ge 2 ]] || die "--s3-uri requires a value"
      S3_URI="$2"
      shift 2
      ;;
    --timeout-seconds)
      [[ $# -ge 2 ]] || die "--timeout-seconds requires a value"
      TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --video-seconds)
      [[ $# -ge 2 ]] || die "--video-seconds requires a value"
      VIDEO_SECONDS="$2"
      shift 2
      ;;
    --artifact-root)
      [[ $# -ge 2 ]] || die "--artifact-root requires a value"
      ARTIFACT_ROOT="$2"
      shift 2
      ;;
	    --debug-port)
	      [[ $# -ge 2 ]] || die "--debug-port requires a value"
	      DEBUG_PORT="$2"
	      shift 2
	      ;;
	    --input-ack-p95-ms)
	      [[ $# -ge 2 ]] || die "--input-ack-p95-ms requires a value"
	      INPUT_ACK_P95_MS="$2"
	      shift 2
	      ;;
	    --click-apply-p95-ms)
	      [[ $# -ge 2 ]] || die "--click-apply-p95-ms requires a value"
	      CLICK_APPLY_P95_MS="$2"
	      shift 2
	      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ "$1" == -* ]]; then
        die "unknown argument: $1"
      fi
      [[ "${CONFIG_FILE_SET}" == "0" ]] || die "multiple config files provided"
      CONFIG_FILE="$(resolve_config_file "$1")"
      CONFIG_FILE_SET=1
      shift
      ;;
  esac
done

[[ -f "${CONFIG_FILE}" ]] || die "config file not found: ${CONFIG_FILE}"

set -a
# shellcheck disable=SC1090
source "${CONFIG_FILE}"
set +a

AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-${RBI_REGION:-}}}"
AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-${AWS_REGION}}"
export AWS_REGION AWS_DEFAULT_REGION

if [[ -z "${PROOF_URL}" ]]; then
  [[ -n "${RBI_DOMAIN:-}" ]] || die "RBI_WINDOWS_VISUAL_PROOF_URL or RBI_DOMAIN is required"
  PROOF_URL="https://${RBI_DOMAIN}/viewer"
fi

[[ -n "${INSTANCE_ID}" ]] || die "--instance-id or RBI_WINDOWS_SSM_INSTANCE_ID is required"
[[ -n "${AWS_REGION}" ]] || die "AWS_REGION is required"
[[ "${TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]] || die "--timeout-seconds must be an integer"
[[ "${VIDEO_SECONDS}" =~ ^[0-9]+$ ]] || die "--video-seconds must be an integer"
[[ "${DEBUG_PORT}" =~ ^[0-9]+$ ]] || die "--debug-port must be an integer"
[[ "${INPUT_ACK_P95_MS}" =~ ^[0-9]+$ ]] || die "--input-ack-p95-ms must be an integer"
[[ "${CLICK_APPLY_P95_MS}" =~ ^[0-9]+$ ]] || die "--click-apply-p95-ms must be an integer"

require_cmd aws python3

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rbi-windows-rdp-proof.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT
PAYLOAD="${TMP_DIR}/ssm-payload.json"

export RBI_WINDOWS_PAYLOAD_PATH="${PAYLOAD}"
export RBI_WINDOWS_PROOF_URL_EFFECTIVE="${PROOF_URL}"
export RBI_WINDOWS_PROOF_PROXY_SERVER_EFFECTIVE="${PROXY_SERVER}"
export RBI_WINDOWS_PROOF_PROXY_BYPASS_LIST_EFFECTIVE="${PROXY_BYPASS_LIST}"
export RBI_WINDOWS_PROOF_IGNORE_CERT_ERRORS_EFFECTIVE="${IGNORE_CERT_ERRORS}"
export RBI_WINDOWS_PROOF_TASK_NAME_EFFECTIVE="${TASK_NAME}"
export RBI_WINDOWS_PROOF_ARTIFACT_ROOT_EFFECTIVE="${ARTIFACT_ROOT}"
export RBI_WINDOWS_PROOF_RUN_ID_EFFECTIVE="${RUN_ID}"
export RBI_WINDOWS_PROOF_TIMEOUT_SECONDS_EFFECTIVE="${TIMEOUT_SECONDS}"
export RBI_WINDOWS_PROOF_VIDEO_SECONDS_EFFECTIVE="${VIDEO_SECONDS}"
export RBI_WINDOWS_PROOF_DEBUG_PORT_EFFECTIVE="${DEBUG_PORT}"
export RBI_WINDOWS_PROOF_RDP_USER_EFFECTIVE="${RDP_USER}"
export RBI_WINDOWS_PROOF_S3_URI_EFFECTIVE="${S3_URI}"
export RBI_WINDOWS_REQUIRE_WEBRTC_STATS_EFFECTIVE="${REQUIRE_WEBRTC_STATS}"
export RBI_WINDOWS_REQUIRE_INPUT_LATENCY_EFFECTIVE="${REQUIRE_INPUT_LATENCY}"
export RBI_WINDOWS_INPUT_ACK_P95_MS_EFFECTIVE="${INPUT_ACK_P95_MS}"
export RBI_WINDOWS_CLICK_APPLY_P95_MS_EFFECTIVE="${CLICK_APPLY_P95_MS}"

python3 <<'PY'
import base64
import json
import os
from pathlib import Path

runner = r'''
param([Parameter(Mandatory=$true)][string]$ConfigPath)

$ErrorActionPreference = "Stop"
$Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$RunRoot = Join-Path $Config.ArtifactRoot $Config.RunId
$SummaryPath = Join-Path $RunRoot "summary.json"
$ConsoleEvents = New-Object System.Collections.ArrayList
$WebrtcSamples = New-Object System.Collections.ArrayList
$ScreenshotSamples = New-Object System.Collections.ArrayList
$BrowserProcess = $null
$FfmpegProcess = $null
$CdpSocket = $null
$ProofInputSent = $false
$CdpId = 0

New-Item -ItemType Directory -Force -Path $RunRoot | Out-Null

function Write-JsonFile {
  param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)]$Value)
  $Value | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Complete-Proof {
  param([string]$Status, [string]$Reason)
  $artifacts = @{}
  foreach ($name in @("screenshot-start.png","screenshot-after-navigation.png","screenshot-end.png","desktop.mp4","screenshot-sequence.json","console-events.json","webrtc-stats.json","browser-stdout.log","browser-stderr.log","ffmpeg-stdout.log","ffmpeg-stderr.log")) {
    $path = Join-Path $RunRoot $name
    $artifacts[$name] = @{
      path = $path
      exists = Test-Path -LiteralPath $path
      bytes = if (Test-Path -LiteralPath $path) { (Get-Item -LiteralPath $path).Length } else { 0 }
    }
  }
  $summary = [ordered]@{
    status = $Status
    reason = $Reason
    runId = $Config.RunId
    url = $Config.Url
    user = [Environment]::UserName
    machine = [Environment]::MachineName
    artifactRoot = $RunRoot
    proxyServerConfigured = [bool]$Config.ProxyServer
    proxyBypassConfigured = [bool]$Config.ProxyBypassList
    ignoreCertificateErrors = [bool]$Config.IgnoreCertificateErrors
    startedAtUtc = $script:StartedAtUtc
    completedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    desktopName = $script:DesktopName
    browserPath = $script:BrowserPath
    consoleEventCount = $ConsoleEvents.Count
    webrtcSampleCount = $WebrtcSamples.Count
    screenshotSampleCount = $ScreenshotSamples.Count
    usedFfmpeg = [bool]$script:UsedFfmpeg
    artifacts = $artifacts
  }
  Write-JsonFile -Path $SummaryPath -Value $summary
  Write-JsonFile -Path (Join-Path $RunRoot "console-events.json") -Value @($ConsoleEvents)
  Write-JsonFile -Path (Join-Path $RunRoot "webrtc-stats.json") -Value @($WebrtcSamples)
  Write-JsonFile -Path (Join-Path $RunRoot "screenshot-sequence.json") -Value @($ScreenshotSamples)
  if ($Status -eq "pass") { exit 0 }
  exit 1
}

function Get-InputDesktopName {
  $source = @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class DesktopApi {
  [DllImport("user32.dll", SetLastError=true)]
  public static extern IntPtr OpenInputDesktop(uint dwFlags, bool fInherit, uint dwDesiredAccess);
  [DllImport("user32.dll", SetLastError=true)]
  public static extern bool GetUserObjectInformation(IntPtr hObj, int nIndex, StringBuilder pvInfo, int nLength, ref int lpnLengthNeeded);
  [DllImport("user32.dll", SetLastError=true)]
  public static extern bool CloseDesktop(IntPtr hDesktop);
}
"@
  Add-Type -TypeDefinition $source -ErrorAction SilentlyContinue | Out-Null
  $DESKTOP_READOBJECTS = 0x0001
  $UOI_NAME = 2
  $desktop = [DesktopApi]::OpenInputDesktop(0, $false, $DESKTOP_READOBJECTS)
  if ($desktop -eq [IntPtr]::Zero) {
    return "unavailable"
  }
  try {
    $needed = 0
    $builder = New-Object System.Text.StringBuilder 256
    [void][DesktopApi]::GetUserObjectInformation($desktop, $UOI_NAME, $builder, $builder.Capacity, [ref]$needed)
    return $builder.ToString()
  } finally {
    [void][DesktopApi]::CloseDesktop($desktop)
  }
}

function Capture-Screenshot {
  param([Parameter(Mandatory=$true)][string]$Path)
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  try {
    $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bounds.Size)
    $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
  } finally {
    $graphics.Dispose()
    $bitmap.Dispose()
  }
}

function Find-Browser {
  $candidates = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
  )
  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) {
      return $candidate
    }
  }
  $cmd = Get-Command chrome.exe, msedge.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cmd) { return $cmd.Source }
  throw "Chrome or Edge was not found"
}

function Wait-HttpJson {
  param([Parameter(Mandatory=$true)][string]$Url, [int]$TimeoutSeconds = 20)
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    try {
      return Invoke-RestMethod -Uri $Url -TimeoutSec 2
    } catch {
      Start-Sleep -Milliseconds 500
    }
  } while ((Get-Date) -lt $deadline)
  throw "timed out waiting for $Url"
}

function Receive-CdpMessage {
  $buffer = New-Object byte[] 1048576
  $stream = New-Object System.IO.MemoryStream
  do {
    $segment = [ArraySegment[byte]]::new($buffer)
    $result = $script:CdpSocket.ReceiveAsync($segment, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
    if ($result.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) {
      throw "CDP socket closed"
    }
    $stream.Write($buffer, 0, $result.Count)
  } while (-not $result.EndOfMessage)
  $text = [Text.Encoding]::UTF8.GetString($stream.ToArray())
  if (-not $text) { return $null }
  return $text | ConvertFrom-Json
}

function Send-Cdp {
  param([Parameter(Mandatory=$true)][string]$Method, [hashtable]$Params = @{})
  $script:CdpId += 1
  $id = $script:CdpId
  $message = @{ id = $id; method = $Method; params = $Params } | ConvertTo-Json -Depth 64 -Compress
  $bytes = [Text.Encoding]::UTF8.GetBytes($message)
  $script:CdpSocket.SendAsync([ArraySegment[byte]]::new($bytes), [Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
  while ($true) {
    $event = Receive-CdpMessage
    if ($null -eq $event) { continue }
    if ($event.method -in @("Runtime.consoleAPICalled","Runtime.exceptionThrown","Log.entryAdded")) {
      [void]$ConsoleEvents.Add($event)
    }
    if ($event.id -eq $id) {
      if ($event.error) { throw ("CDP {0} failed: {1}" -f $Method, ($event.error | ConvertTo-Json -Compress)) }
      return $event.result
    }
  }
}

function Evaluate-Cdp {
  param([Parameter(Mandatory=$true)][string]$Expression, [switch]$AwaitPromise)
  $params = @{
    expression = $Expression
    returnByValue = $true
    awaitPromise = [bool]$AwaitPromise
  }
  $result = Send-Cdp -Method "Runtime.evaluate" -Params $params
  if ($result.exceptionDetails) {
    throw ("Runtime.evaluate failed: {0}" -f ($result.exceptionDetails | ConvertTo-Json -Depth 16 -Compress))
  }
  return $result.result.value
}

function Get-ObjectProperty($Object, [string]$Name) {
  if ($null -eq $Object) { return $null }
  if ($Object.PSObject.Properties.Name -contains $Name) {
    return $Object.$Name
  }
  return $null
}

function Invoke-ProofInput {
  $point = Evaluate-Cdp -AwaitPromise -Expression @"
(async () => {
  const video = document.querySelector('video');
  if (!video) return null;
  video.focus();
  const rect = video.getBoundingClientRect();
  if (!rect || rect.width < 20 || rect.height < 20) return null;
  return {
    x: Math.round(rect.left + Math.min(160, Math.max(20, rect.width * 0.35))),
    y: Math.round(rect.top + Math.min(120, Math.max(20, rect.height * 0.35)))
  };
})()
"@
  if (-not $point) {
    throw "unable to locate remote video for proof input"
  }
  $x = [double]$point.x
  $y = [double]$point.y
  foreach ($offset in @(0, 6, 12, 18)) {
    [void](Send-Cdp -Method "Input.dispatchMouseEvent" -Params @{ type = "mouseMoved"; x = $x + $offset; y = $y; button = "none" })
    Start-Sleep -Milliseconds 60
  }
  [void](Send-Cdp -Method "Input.dispatchMouseEvent" -Params @{ type = "mousePressed"; x = $x + 18; y = $y; button = "left"; buttons = 1; clickCount = 1 })
  Start-Sleep -Milliseconds 80
  [void](Send-Cdp -Method "Input.dispatchMouseEvent" -Params @{ type = "mouseReleased"; x = $x + 18; y = $y; button = "left"; buttons = 0; clickCount = 1 })
  Start-Sleep -Milliseconds 80
  [void](Send-Cdp -Method "Input.insertText" -Params @{ text = "rbi-proof" })
  [void]$ConsoleEvents.Add(@{ method = "proof.inputDispatched"; params = @{ x = $x + 18; y = $y; textLength = 9 } })
  $script:ProofInputSent = $true
}

try {
  $script:StartedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
  $script:DesktopName = Get-InputDesktopName
  if ($script:DesktopName -ne "Default") {
    Complete-Proof -Status "fail" -Reason "desktop locked or not on the interactive Default desktop: $script:DesktopName"
  }

  $script:BrowserPath = Find-Browser
  $ffmpeg = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
  $script:UsedFfmpeg = [bool]$ffmpeg
  if (-not $script:UsedFfmpeg) {
    [void]$ConsoleEvents.Add(@{ method = "proof.videoFallback"; params = @{ message = "ffmpeg.exe was not found on PATH; using screenshot sequence fallback" } })
  }

  Capture-Screenshot -Path (Join-Path $RunRoot "screenshot-start.png")

  $profileDir = Join-Path $RunRoot "browser-profile"
  New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
  $browserStdout = Join-Path $RunRoot "browser-stdout.log"
  $browserStderr = Join-Path $RunRoot "browser-stderr.log"
  $browserArgs = @(
    "--new-window",
    "--remote-debugging-port=$($Config.DebugPort)",
    "--user-data-dir=$profileDir",
    "--no-first-run",
    "--disable-default-apps",
    "about:blank"
  )
  if ($Config.ProxyServer) {
    $browserArgs += "--proxy-server=$($Config.ProxyServer)"
  }
  if ($Config.ProxyBypassList) {
    $browserArgs += "--proxy-bypass-list=$($Config.ProxyBypassList)"
  }
  if ($Config.IgnoreCertificateErrors) {
    $browserArgs += "--ignore-certificate-errors"
  }
  $BrowserProcess = Start-Process -FilePath $script:BrowserPath -ArgumentList $browserArgs -RedirectStandardOutput $browserStdout -RedirectStandardError $browserStderr -PassThru

  $ffmpegStdout = Join-Path $RunRoot "ffmpeg-stdout.log"
  $ffmpegStderr = Join-Path $RunRoot "ffmpeg-stderr.log"
  $videoPath = Join-Path $RunRoot "desktop.mp4"
  $sequenceDir = Join-Path $RunRoot "screenshot-sequence"
  New-Item -ItemType Directory -Force -Path $sequenceDir | Out-Null
  if ($script:UsedFfmpeg) {
    $ffmpegArgs = @("-y","-f","gdigrab","-framerate","20","-i","desktop","-t",[string]$Config.VideoSeconds,"-pix_fmt","yuv420p",$videoPath)
    $FfmpegProcess = Start-Process -FilePath $ffmpeg.Source -ArgumentList $ffmpegArgs -RedirectStandardOutput $ffmpegStdout -RedirectStandardError $ffmpegStderr -PassThru
  }

  $targets = Wait-HttpJson -Url "http://127.0.0.1:$($Config.DebugPort)/json/list" -TimeoutSeconds 30
  $target = @($targets | Where-Object { $_.type -eq "page" } | Select-Object -First 1)[0]
  if (-not $target -or -not $target.webSocketDebuggerUrl) {
    throw "no browser page target exposed by DevTools"
  }

  $script:CdpSocket = [System.Net.WebSockets.ClientWebSocket]::new()
  $script:CdpSocket.ConnectAsync([Uri]$target.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
  [void](Send-Cdp -Method "Page.enable")
  [void](Send-Cdp -Method "Runtime.enable")
  [void](Send-Cdp -Method "Log.enable")
  [void](Evaluate-Cdp -Expression "window.__rbiConsoleEvents=[];['log','warn','error','debug'].forEach(k=>{const o=console[k].bind(console);console[k]=(...a)=>{window.__rbiConsoleEvents.push({level:k,args:a.map(String),ts:Date.now()});o(...a)}});")
  [void](Send-Cdp -Method "Page.navigate" -Params @{ url = [string]$Config.Url })

  Start-Sleep -Seconds 5
  Capture-Screenshot -Path (Join-Path $RunRoot "screenshot-after-navigation.png")

  $sampleExpression = @"
(async () => {
  const dbg = window.__rbiViewerDebug || {};
  const video = document.querySelector('video');
  const sample = {
    href: location.href,
    title: document.title,
    readyState: document.readyState,
    timestamp: Date.now(),
    video: video ? {
      videoWidth: video.videoWidth,
      videoHeight: video.videoHeight,
      currentTime: video.currentTime,
      paused: video.paused,
      readyState: video.readyState
    } : null,
    sessionId: dbg.session && dbg.session.id || null,
    inputAckStats: dbg.inputAckStats || null,
    inputSloWindow: dbg.inputSloWindow || null,
    mediaRelayConfig: dbg.mediaRelayConfig || null,
    gatewayWebrtcConfig: dbg.gatewayWebrtcConfig || null,
    stage: dbg.stage || null,
    stats: []
  };
  if (dbg.peer && typeof dbg.peer.getStats === 'function') {
    const report = await dbg.peer.getStats();
    report.forEach((value) => {
      if (['inbound-rtp','candidate-pair','transport','remote-inbound-rtp'].includes(value.type)) {
        sample.stats.push(value);
      }
    });
  }
  sample.consoleEvents = window.__rbiConsoleEvents || [];
  return sample;
})()
"@

  $deadline = (Get-Date).AddSeconds([int]$Config.VideoSeconds)
  do {
    try {
	      $sample = Evaluate-Cdp -Expression $sampleExpression -AwaitPromise
	      if ($sample) { [void]$WebrtcSamples.Add($sample) }
	      $sampleHasDecodedFrame = $false
	      if ($sample -and $sample.video) {
	        $sampleHasDecodedFrame = ([int]$sample.video.videoWidth -gt 0 -and [int]$sample.video.videoHeight -gt 0 -and [int]$sample.video.readyState -ge 2)
	      }
	      if (-not $script:ProofInputSent -and $sample -and (($sample.stage -and ($sample.stage.stage -eq "first-frame" -or $sample.stage.stage -eq "live")) -or $sampleHasDecodedFrame)) {
	        Invoke-ProofInput
	      }
	      if (-not $script:UsedFfmpeg) {
        $sequencePath = Join-Path $sequenceDir ("frame-{0:D4}.png" -f $ScreenshotSamples.Count)
        Capture-Screenshot -Path $sequencePath
        $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $sequencePath
        [void]$ScreenshotSamples.Add(@{
          path = $sequencePath
          bytes = (Get-Item -LiteralPath $sequencePath).Length
          sha256 = $hash.Hash
          timestampUtc = (Get-Date).ToUniversalTime().ToString("o")
        })
      }
    } catch {
      [void]$ConsoleEvents.Add(@{ method = "proof.webrtcStatsFailed"; params = @{ message = $_.Exception.Message } })
    }
    Start-Sleep -Seconds 2
  } while ((Get-Date) -lt $deadline)

  try {
    $pageConsole = Evaluate-Cdp -Expression "window.__rbiConsoleEvents || []"
    if ($pageConsole) {
      [void]$ConsoleEvents.Add(@{ method = "proof.pageConsoleSnapshot"; params = $pageConsole })
    }
  } catch {}

  Capture-Screenshot -Path (Join-Path $RunRoot "screenshot-end.png")
  if ($FfmpegProcess -and -not $FfmpegProcess.HasExited) {
    if (-not $FfmpegProcess.WaitForExit(10000)) {
      $FfmpegProcess.Kill()
    }
  }

  Write-JsonFile -Path (Join-Path $RunRoot "console-events.json") -Value @($ConsoleEvents)
  Write-JsonFile -Path (Join-Path $RunRoot "webrtc-stats.json") -Value @($WebrtcSamples)
  Write-JsonFile -Path (Join-Path $RunRoot "screenshot-sequence.json") -Value @($ScreenshotSamples)

  $required = @("screenshot-start.png","screenshot-after-navigation.png","screenshot-end.png","console-events.json","webrtc-stats.json")
  if ($script:UsedFfmpeg) {
    $required += "desktop.mp4"
  } else {
    $required += "screenshot-sequence.json"
  }
  foreach ($name in $required) {
    $path = Join-Path $RunRoot $name
    if (-not (Test-Path -LiteralPath $path) -or (Get-Item -LiteralPath $path).Length -le 0) {
      Complete-Proof -Status "fail" -Reason "missing or empty artifact: $name"
    }
  }
  if (-not $script:UsedFfmpeg) {
    $uniqueHashes = @($ScreenshotSamples | ForEach-Object { $_.sha256 } | Sort-Object -Unique)
    if ($ScreenshotSamples.Count -lt 2 -or $uniqueHashes.Count -lt 2) {
      Complete-Proof -Status "fail" -Reason "screenshot sequence did not show changing desktop pixels"
    }
  }

  $proofText = ""
  try {
    $proofText = ((@($ConsoleEvents) + @($WebrtcSamples)) | ConvertTo-Json -Depth 64 -Compress)
  } catch {
    $proofText = ""
  }
  if ($proofText -match "viewer\.start_failed|Gateway offer failed|Failed to start") {
    Complete-Proof -Status "fail" -Reason "viewer reported RBI startup failure"
  }

  $gatewaySamples = @($WebrtcSamples | Where-Object {
    $_.gatewayWebrtcConfig -and
    ($_.gatewayWebrtcConfig.mediaPlaneMode -eq "gateway-webrtc-relay" -or $_.gatewayWebrtcConfig.protocol -eq "webrtc-srtp")
  })
  if ($gatewaySamples.Count -le 0) {
    Complete-Proof -Status "fail" -Reason "viewer did not enter gateway WebRTC/SRTP mode"
  }

  $frameSamples = @($WebrtcSamples | Where-Object {
    $_.video -and
    [int]$_.video.videoWidth -gt 0 -and
    [int]$_.video.videoHeight -gt 0 -and
    [int]$_.video.readyState -ge 2
  })
  if ($frameSamples.Count -le 0) {
    Complete-Proof -Status "fail" -Reason "no decoded remote video frame was observed"
  }

  $liveSamples = @($WebrtcSamples | Where-Object {
    ($_.stage -and ($_.stage.stage -eq "first-frame" -or $_.stage.stage -eq "live")) -or
    ($_.video -and [int]$_.video.videoWidth -gt 0 -and [int]$_.video.videoHeight -gt 0 -and [int]$_.video.readyState -ge 2)
  })
  if ($liveSamples.Count -le 0) {
    Complete-Proof -Status "fail" -Reason "viewer never reached first-frame or live stage"
  }

	  if ([string]$Config.RequireWebrtcStats -eq "1") {
	    $statsCount = 0
	    $videoInboundBytes = 0
    $decodedFrames = 0
    foreach ($sample in $WebrtcSamples) {
      if ($sample.stats) {
        $statsCount += @($sample.stats).Count
        foreach ($stat in @($sample.stats)) {
          if ($stat.type -eq "inbound-rtp" -and ($stat.kind -eq "video" -or $stat.mediaType -eq "video")) {
            if ($stat.PSObject.Properties.Name -contains "bytesReceived") {
              $videoInboundBytes += [int64]$stat.bytesReceived
            }
            if ($stat.PSObject.Properties.Name -contains "framesDecoded") {
              $decodedFrames += [int64]$stat.framesDecoded
            }
          }
        }
      }
    }
    if ($statsCount -le 0) {
      Complete-Proof -Status "fail" -Reason "no WebRTC stats were captured from window.__rbiViewerDebug.peer"
    }
    if ($videoInboundBytes -le 0 -and $decodedFrames -le 0) {
	      Complete-Proof -Status "fail" -Reason "WebRTC stats did not show inbound video bytes or decoded frames"
	    }
	  }

	  if ([string]$Config.RequireInputLatency -eq "1") {
	    if (-not $script:ProofInputSent) {
	      Complete-Proof -Status "fail" -Reason "proof input was not dispatched in the live viewer"
	    }
	    $maxAckP95 = 0
	    $maxClickApplyP95 = 0
	    $hasAckLatency = $false
	    foreach ($sample in $WebrtcSamples) {
	      $slo = Get-ObjectProperty $sample "inputSloWindow"
	      if (-not $slo) { continue }
	      $byClass = Get-ObjectProperty $slo "byClass"
	      if ($byClass) {
	        foreach ($prop in $byClass.PSObject.Properties) {
	          $ack = Get-ObjectProperty (Get-ObjectProperty $prop.Value "ackMs") "p95"
	          if ($null -ne $ack -and [double]$ack -gt 0) {
	            $hasAckLatency = $true
	            if ([double]$ack -gt $maxAckP95) { $maxAckP95 = [double]$ack }
	          }
	        }
	      }
	      $click = Get-ObjectProperty (Get-ObjectProperty $slo "clickToApplyMs") "p95"
	      if ($null -ne $click -and [double]$click -gt $maxClickApplyP95) {
	        $maxClickApplyP95 = [double]$click
	      }
	    }
	    if (-not $hasAckLatency) {
	      Complete-Proof -Status "fail" -Reason "input ACK latency was not captured"
	    }
	    if ($maxClickApplyP95 -le 0) {
	      Complete-Proof -Status "fail" -Reason "click-to-apply latency was not captured"
	    }
	    if ($maxAckP95 -gt [double]$Config.InputAckP95Ms) {
	      Complete-Proof -Status "fail" -Reason ("input ACK p95 {0}ms exceeded budget {1}ms" -f [math]::Round($maxAckP95), $Config.InputAckP95Ms)
	    }
	    if ($maxClickApplyP95 -gt [double]$Config.ClickApplyP95Ms) {
	      Complete-Proof -Status "fail" -Reason ("click-to-apply p95 {0}ms exceeded budget {1}ms" -f [math]::Round($maxClickApplyP95), $Config.ClickApplyP95Ms)
	    }
	    [void]$ConsoleEvents.Add(@{ method = "proof.inputLatency"; params = @{ ackP95Ms = [math]::Round($maxAckP95); clickApplyP95Ms = [math]::Round($maxClickApplyP95) } })
	  }

	  Complete-Proof -Status "pass" -Reason "visual proof artifacts captured"
} catch {
  try {
    if ($FfmpegProcess -and -not $FfmpegProcess.HasExited) { $FfmpegProcess.Kill() }
    if ($BrowserProcess -and -not $BrowserProcess.HasExited) { $BrowserProcess.CloseMainWindow() | Out-Null; Start-Sleep -Seconds 2; if (-not $BrowserProcess.HasExited) { $BrowserProcess.Kill() } }
  } catch {}
  Complete-Proof -Status "fail" -Reason ($_.Exception.Message)
} finally {
  try {
    if ($script:CdpSocket) { $script:CdpSocket.Dispose() }
  } catch {}
  try {
    if ($FfmpegProcess -and -not $FfmpegProcess.HasExited) { $FfmpegProcess.Kill() }
  } catch {}
  try {
    if ($BrowserProcess -and -not $BrowserProcess.HasExited) {
      $BrowserProcess.CloseMainWindow() | Out-Null
      Start-Sleep -Seconds 2
      if (-not $BrowserProcess.HasExited) { $BrowserProcess.Kill() }
    }
  } catch {}
}
'''

config = {
    "Url": os.environ["RBI_WINDOWS_PROOF_URL_EFFECTIVE"],
    "ProxyServer": os.environ.get("RBI_WINDOWS_PROOF_PROXY_SERVER_EFFECTIVE", ""),
    "ProxyBypassList": os.environ.get("RBI_WINDOWS_PROOF_PROXY_BYPASS_LIST_EFFECTIVE", ""),
    "IgnoreCertificateErrors": os.environ.get("RBI_WINDOWS_PROOF_IGNORE_CERT_ERRORS_EFFECTIVE", "0") == "1",
    "TaskName": os.environ["RBI_WINDOWS_PROOF_TASK_NAME_EFFECTIVE"],
    "ArtifactRoot": os.environ["RBI_WINDOWS_PROOF_ARTIFACT_ROOT_EFFECTIVE"],
    "RunId": os.environ["RBI_WINDOWS_PROOF_RUN_ID_EFFECTIVE"],
    "TimeoutSeconds": int(os.environ["RBI_WINDOWS_PROOF_TIMEOUT_SECONDS_EFFECTIVE"]),
    "VideoSeconds": int(os.environ["RBI_WINDOWS_PROOF_VIDEO_SECONDS_EFFECTIVE"]),
    "DebugPort": int(os.environ["RBI_WINDOWS_PROOF_DEBUG_PORT_EFFECTIVE"]),
    "RdpUser": os.environ.get("RBI_WINDOWS_PROOF_RDP_USER_EFFECTIVE", ""),
    "S3Uri": os.environ.get("RBI_WINDOWS_PROOF_S3_URI_EFFECTIVE", ""),
    "RequireWebrtcStats": os.environ.get("RBI_WINDOWS_REQUIRE_WEBRTC_STATS_EFFECTIVE", "1"),
    "RequireInputLatency": os.environ.get("RBI_WINDOWS_REQUIRE_INPUT_LATENCY_EFFECTIVE", "1"),
    "InputAckP95Ms": int(os.environ["RBI_WINDOWS_INPUT_ACK_P95_MS_EFFECTIVE"]),
    "ClickApplyP95Ms": int(os.environ["RBI_WINDOWS_CLICK_APPLY_P95_MS_EFFECTIVE"]),
}
runner_b64 = base64.b64encode(runner.encode("utf-16le")).decode("ascii")
config_json = json.dumps(config, separators=(",", ":"))
config_b64 = base64.b64encode(config_json.encode("utf-8")).decode("ascii")

bootstrap = rf'''
$ErrorActionPreference = "Stop"
$ConfigJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("{config_b64}"))
$Config = $ConfigJson | ConvertFrom-Json
$BaseDir = Join-Path $Config.ArtifactRoot "_harness"
$RunRoot = Join-Path $Config.ArtifactRoot $Config.RunId
New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null
New-Item -ItemType Directory -Force -Path $RunRoot | Out-Null
$RunnerPath = Join-Path $BaseDir "rbi-current-rdp-visual-proof.ps1"
$ConfigPath = Join-Path $RunRoot "config.json"
$SummaryPath = Join-Path $RunRoot "summary.json"
[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String("{runner_b64}")) | Set-Content -LiteralPath $RunnerPath -Encoding Unicode
$Config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8

function Get-ActiveRdpUser {{
  $lines = quser 2>$null
  foreach ($line in $lines) {{
    if ($line -match '^\s*>?(\S+)\s+(\S+|\d+)\s+(\d+)\s+Active\s+') {{
      return $matches[1]
    }}
  }}
  foreach ($line in $lines) {{
    if ($line -match '^\s*>?(\S+)\s+.*\s+Active\s+') {{
      return $matches[1]
    }}
  }}
  return ""
}}

$User = [string]$Config.RdpUser
if (-not $User) {{ $User = Get-ActiveRdpUser }}
if (-not $User) {{ throw "no active RDP user found; open an interactive RDP session or pass --rdp-user" }}

$Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$RunnerPath`" -ConfigPath `"$ConfigPath`""
$Principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Highest
$Task = New-ScheduledTask -Action $Action -Principal $Principal
Register-ScheduledTask -TaskName $Config.TaskName -InputObject $Task -Force | Out-Null
Start-ScheduledTask -TaskName $Config.TaskName

$Deadline = (Get-Date).AddSeconds([int]$Config.TimeoutSeconds)
do {{
  if (Test-Path -LiteralPath $SummaryPath) {{ break }}
  Start-Sleep -Seconds 2
}} while ((Get-Date) -lt $Deadline)

if (-not (Test-Path -LiteralPath $SummaryPath)) {{
  throw "interactive scheduled task did not produce summary before timeout; RDP may be locked, disconnected, or task principal may be invalid"
}}

$Summary = Get-Content -LiteralPath $SummaryPath -Raw | ConvertFrom-Json
if ($Config.S3Uri) {{
  $Aws = Get-Command aws.exe -ErrorAction SilentlyContinue
  if (-not $Aws) {{ $Aws = Get-Command aws -ErrorAction SilentlyContinue }}
  if (-not $Aws) {{ throw "S3 artifact upload requested but aws CLI is not available on the Windows host" }}
  $Dest = ([string]$Config.S3Uri).TrimEnd("/") + "/" + $Config.RunId + "/"
  & $Aws.Source s3 sync $RunRoot $Dest --only-show-errors
  if ($LASTEXITCODE -ne 0) {{ throw "S3 artifact upload failed to $Dest" }}
  $Summary | Add-Member -NotePropertyName s3Uri -NotePropertyValue $Dest -Force
  $Summary | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $SummaryPath -Encoding UTF8
}}

$Summary | ConvertTo-Json -Depth 64
if ($Summary.status -ne "pass") {{ exit 1 }}
'''

payload = {"commands": [bootstrap]}
Path(os.environ["RBI_WINDOWS_PAYLOAD_PATH"]).write_text(json.dumps(payload, indent=2), encoding="utf-8")
PY

AWS_CLI_ARGS=()
if [[ -n "${AWS_PROFILE:-}" ]]; then
  AWS_CLI_ARGS+=(--profile "${AWS_PROFILE}")
fi
AWS_CLI_ARGS+=(--region "${AWS_REGION}")

printf 'Config: %s\n' "${CONFIG_FILE}"
printf 'AWS profile: %s\n' "${AWS_PROFILE:-<unset>}"
printf 'AWS region: %s\n' "${AWS_REGION}"
printf 'Windows instance: %s\n' "${INSTANCE_ID}"
printf 'Proof URL: %s\n' "${PROOF_URL}"
printf 'Run ID: %s\n' "${RUN_ID}"
if [[ -n "${S3_URI}" ]]; then
  printf 'Artifact S3 prefix: %s/%s/\n' "${S3_URI%/}" "${RUN_ID}"
fi

COMMAND_ID="$(
  aws "${AWS_CLI_ARGS[@]}" ssm send-command \
    --instance-ids "${INSTANCE_ID}" \
    --document-name AWS-RunPowerShellScript \
    --comment "cloudsec-rbi-current-rdp-visual-proof:${RUN_ID}" \
    --parameters "file://${PAYLOAD}" \
    --query Command.CommandId \
    --output text
)"

printf 'SSM command: %s\n' "${COMMAND_ID}"

set +e
aws "${AWS_CLI_ARGS[@]}" ssm wait command-executed \
  --command-id "${COMMAND_ID}" \
  --instance-id "${INSTANCE_ID}"
WAIT_STATUS=$?
set -e

INVOCATION="$(
  aws "${AWS_CLI_ARGS[@]}" ssm get-command-invocation \
    --command-id "${COMMAND_ID}" \
    --instance-id "${INSTANCE_ID}" \
    --query '{Status:Status,ResponseCode:ResponseCode,Stdout:StandardOutputContent,Stderr:StandardErrorContent}' \
    --output json
)"

printf '%s\n' "${INVOCATION}"

INVOCATION_STATUS="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("Status",""))' <<<"${INVOCATION}")"
if [[ "${WAIT_STATUS}" -ne 0 || "${INVOCATION_STATUS}" != "Success" ]]; then
  exit 1
fi
