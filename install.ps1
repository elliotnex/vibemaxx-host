# VibeMaxx host - one-line WINDOWS installer (vendored release, no npm on your machine).
#
# Installs the always-on `vibemaxx-host` daemon (agent/terminal sessions over WebSocket) on a
# 64-bit Windows 10 1809 / Windows Server 2019+ box, as a Windows service (WinSW) that starts
# at boot and restarts on crash. Your VibeMaxx desktop app then connects to it so sessions
# survive the app quitting or your other machines sleeping.
#
# It downloads a self-contained release zip (the daemon + its native modules + a bundled Node
# runtime) from this repo's GitHub Releases - the box never compiles anything and never talks
# to the npm registry.
#
# Run from an ELEVATED PowerShell:
#
#   Private, encrypted access via Tailscale (RECOMMENDED - install Tailscale + sign in first):
#     iex "& { $(irm https://raw.githubusercontent.com/elliotnex/vibemaxx-host/main/install.ps1) } -Tailscale"
#
#   Loopback only (reach it from this machine / an SSH tunnel):
#     irm https://raw.githubusercontent.com/elliotnex/vibemaxx-host/main/install.ps1 | iex
#
#   Or download first, read it, then run:
#     irm https://raw.githubusercontent.com/elliotnex/vibemaxx-host/main/install.ps1 -OutFile install.ps1
#     powershell -ExecutionPolicy Bypass -File .\install.ps1 -Tailscale
#
# Idempotent: re-run to update to the latest release (token, service registration, and data
# are preserved). Uninstall with -Uninstall (add -Purge to also delete the install dir + data).
#
# By default the service runs AS YOUR USER ACCOUNT (you are asked for your password once, at
# first install - Windows stores it, the installer never writes it to disk). That way agent
# CLIs (claude, codex, ...) and their sign-ins under your profile work unchanged. Use
# -ServiceAccount LocalSystem to avoid the prompt, at the cost of agents running as SYSTEM
# with an empty profile.
#
# Options:
#   -InstallAgent <name>     Install an agent CLI on this box: codex, claude-code, grok,
#                            antigravity, opencode, cursor. Repeatable / comma-separated.
#                            npm-based agents pull in Node.js LTS automatically if missing
#                            (the base install stays npm-free, like the Linux installer).
#   -AgentNpm <package>      Install an arbitrary npm global package as an agent. Repeatable.
#   -Tailscale               Bind the daemon to this machine's tailnet IP (private, encrypted;
#                            Tailscale must already be installed and signed in).
#   -Bind <ip>               Bind a specific interface (default 127.0.0.1; "tailscale" works too).
#   -Port <n>                Port to listen on (default 8765).
#   -Token <tok>             Use this bearer token instead of generating/reusing one.
#   -GitHubToken <tok>       GitHub token for authenticated git push/pull on the host (optional).
#   -InstallDir <path>       Install location (default C:\VibeMaxx\Host).
#   -ServiceAccount <a>      CurrentUser (default) or LocalSystem.
#   -Version <tag>           Release tag to install (default: latest).
#   -NoService               Download + extract + config only; prints a foreground run command.
#   -NoFirewall              Skip the firewall rule for non-loopback binds.
#   -Uninstall               Stop + remove the service (files and data kept).
#   -Purge                   With -Uninstall, also delete the install dir and the data dir.
#
# The VIBEMAXX_RELEASE_BASE_URL environment variable (or -ReleaseBaseUrl) overrides where the
# zip is fetched from: a mirror, an internal artifact store, or a local directory for
# air-gapped installs.

[CmdletBinding()]
param(
  [string[]]$InstallAgent = @(),
  [string[]]$AgentNpm = @(),
  [switch]$Tailscale,
  [string]$Bind = "127.0.0.1",
  [int]$Port = 8765,
  [string]$Token = "",
  [string]$GitHubToken = "",
  [string]$InstallDir = "C:\VibeMaxx\Host",
  [string]$DataDir = "",
  [string]$SpacesDir = "",
  [string]$ReposDir = "",
  [ValidateSet("CurrentUser", "LocalSystem")]
  [string]$ServiceAccount = "CurrentUser",
  [pscredential]$ServiceCredential,
  [string]$Version = "latest",
  [string]$ReleaseBaseUrl = "",
  [string]$WinSWPath = "",
  [switch]$NoService,
  [switch]$NoFirewall,
  [switch]$Uninstall,
  [switch]$Purge
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$RepoSlug = "elliotnex/vibemaxx-host"
$Asset = "vibemaxx-host-win-x64.zip"
$ServiceName = "vibemaxx-host"
# Node LTS MSI used ONLY when an npm-based agent is requested and npm is missing (the
# vendored daemon bundles its own node.exe and never needs this). Matches the bundled
# runtime's version line.
$NodeMsiUrl = "https://nodejs.org/dist/v24.14.0/node-v24.14.0-x64.msi"
$WinSWUrl = "https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe"
# SHA-256 of the official WinSW v2.12.0 x64 release asset; the download is refused on mismatch.
$WinSWSha256 = "05b82d46ad331cc16bdc00de5c6332c1ef818df8ceefcd49c726553209b3a0da"

function Say([string]$msg)  { Write-Host "==> $msg" -ForegroundColor Cyan }
function Ok2([string]$msg)  { Write-Host "+ $msg" -ForegroundColor Green }
function Warn2([string]$msg) { Write-Host "!  $msg" -ForegroundColor Yellow }
# NEVER `exit` in this script: the one-liner runs it via `iex` IN the user's console session,
# where `exit` terminates the PowerShell window itself (before the error can be read). Errors
# throw instead; the runner at the bottom prints them and only sets an exit code in file mode.
function Die([string]$msg)  { throw $msg }

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Robocopy([string]$src, [string]$dst) {
  & robocopy $src $dst /MIR /R:2 /W:2 /NFL /NDL /NJH /NJS /NP | Out-Null
  if ($LASTEXITCODE -ge 8) { Die "robocopy $src -> $dst failed (exit $LASTEXITCODE)" }
  $global:LASTEXITCODE = 0
}

function XmlEscape([string]$s) { return [System.Security.SecurityElement]::Escape($s) }

# Agent CLIs the desktop app offers, by key -> binary/kind/payload. Mirrors the app's
# runtimePresets WINDOWS install commands, the way install.sh's agent_spec mirrors the
# Linux ones. Vendor .ps1 installers are downloaded to a file and run from a temp cwd
# (never piped) so they can't eat their own script on stdin.
function Resolve-AgentSpec([string]$name) {
  switch -Regex ($name.ToLowerInvariant().Trim()) {
    "^codex$"                 { return @{ binary = "codex";        kind = "npm"; payload = "@openai/codex" } }
    "^(claude-code|claude)$"  { return @{ binary = "claude";       kind = "npm"; payload = "@anthropic-ai/claude-code" } }
    "^opencode$"              { return @{ binary = "opencode";     kind = "npm"; payload = "opencode-ai" } }
    "^(grok|grok-build)$"     { return @{ binary = "grok";         kind = "ps1"; payload = "https://x.ai/cli/install.ps1" } }
    "^(antigravity|agy)$"     { return @{ binary = "agy";          kind = "ps1"; payload = "https://antigravity.google/cli/install.ps1" } }
    "^(cursor|cursor-agent)$" { return @{ binary = "cursor-agent"; kind = "ps1"; payload = "https://cursor.com/install" } }
  }
  return $null
}

# npm is needed only for npm-based agents; the base install never uses it (the daemon
# bundles its own node.exe). Install Node LTS on demand: winget when present, else the
# pinned MSI. Returns $true when Node was installed by this call.
function Install-NodeNpmIfMissing {
  if (Get-Command npm -ErrorAction SilentlyContinue) { return $false }
  Say "npm not found - installing Node.js LTS (needed only for agent CLI installs)"
  $done = $false
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    & winget install --id OpenJS.NodeJS.LTS --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -eq 0) { $done = $true } else { Warn2 "winget install failed (exit $LASTEXITCODE) - falling back to the Node MSI" }
  }
  if (-not $done) {
    $msi = Join-Path ([System.IO.Path]::GetTempPath()) "vibemaxx-node-lts-x64.msi"
    Invoke-WebRequest -Uri $NodeMsiUrl -OutFile $msi -UseBasicParsing
    $p = Start-Process msiexec.exe -ArgumentList "/i", "`"$msi`"", "/qn", "/norestart" -Wait -PassThru
    Remove-Item $msi -Force -ErrorAction SilentlyContinue
    if ($p.ExitCode -ne 0) { Die "Node.js MSI install failed (exit $($p.ExitCode))." }
  }
  # The machine PATH changed under this running process - rebuild it so npm resolves now.
  $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
  if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    Die "npm still not found after installing Node.js. Open a NEW elevated PowerShell and re-run."
  }
  return $true
}

# Codex's Windows sandbox refuses to initialize under an elevated token - and hosted
# sessions ARE elevated when the service account is an administrator (service logons get
# the unfiltered token; LocalSystem always is). This box is the sandbox (same posture as
# the Linux VPS default), so turn Codex's own jail off. Create-if-missing only: an
# existing config on a personal machine is never rewritten, just advised about.
function Write-CodexConfig([string]$profileRoot) {
  $codexDir = Join-Path $profileRoot ".codex"
  $config = Join-Path $codexDir "config.toml"
  if (Test-Path $config) {
    $raw = Get-Content $config -Raw
    if ($raw -match 'sandbox_mode\s*=\s*"danger-full-access"') { return }
    Warn2 "$config exists without sandbox_mode = ""danger-full-access""."
    Warn2 "Codex sessions on this host will fail to start their sandbox under the service's elevated token"
    Warn2 "until you add:  approval_policy = ""never""  and  sandbox_mode = ""danger-full-access"""
    return
  }
  New-Item -ItemType Directory -Force -Path $codexDir | Out-Null
  @"
# Written by the VibeMaxx host installer. This box is the sandbox: agents run under the
# vibemaxx-host service, whose token is elevated (admin service account or LocalSystem),
# and Codex's own Windows sandbox refuses to start when elevated - so it is turned off
# here, matching the Linux VPS default posture.
approval_policy = "never"
sandbox_mode = "danger-full-access"
"@ | Out-File -FilePath $config -Encoding ascii
  Say "Disabled the Codex CLI sandbox in $config (the service's elevated token can't host it)"
}

# Best-effort local check that the service-account password is right BEFORE handing it to
# the SCM, which accepts anything and only fails at the first start with a logon failure
# (error 1069). The two usual causes: a Windows Hello PIN is NOT the password, and
# Microsoft-account machines need the MICROSOFT ACCOUNT password. Returns $true when
# validation isn't possible (odd domain/MSA setups) so it never blocks a correct password.
function Test-ServiceCredential([pscredential]$cred) {
  try {
    Add-Type -AssemblyName System.DirectoryServices.AccountManagement
    $nc = $cred.GetNetworkCredential()
    $isLocal = (-not $nc.Domain) -or $nc.Domain -eq "." -or $nc.Domain -ieq $env:COMPUTERNAME
    $ctxType = [System.DirectoryServices.AccountManagement.ContextType]::Domain
    if ($isLocal) { $ctxType = [System.DirectoryServices.AccountManagement.ContextType]::Machine }
    $ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext($ctxType)
    return $ctx.ValidateCredentials($nc.UserName, $nc.Password)
  } catch {
    return $true
  }
}

# The whole install runs inside this function so early-outs can `return` (an `exit` here
# would close the console when run via `irm | iex` — see the note on Die above). It reads
# the script params from the enclosing scope.
function Invoke-VibeMaxxHostInstall {

$SvcDir  = Join-Path $InstallDir "svc"
$LogsDir = Join-Path $InstallDir "logs"
$SvcExe  = Join-Path $SvcDir "$ServiceName.exe"
$SvcXml  = Join-Path $SvcDir "$ServiceName.xml"
$NodeExe = Join-Path $InstallDir "node\node.exe"

# --- Uninstall -----------------------------------------------------------------------------
if ($Uninstall) {
  if (-not (Test-Admin)) { Die "Uninstall needs an elevated PowerShell." }
  $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
  if ($svc) {
    Say "Stopping and removing service $ServiceName"
    if ($svc.Status -ne "Stopped") { Stop-Service -Name $ServiceName -Force }
    if (Test-Path $SvcExe) { & $SvcExe uninstall | Out-Null } else { & sc.exe delete $ServiceName | Out-Null }
  } else {
    Say "Service $ServiceName is not installed"
  }
  Get-NetFirewallRule -DisplayName "VibeMaxx Host" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
  if ($Purge) {
    if (-not $DataDir) { $DataDir = Join-Path $env:USERPROFILE ".vibemaxx-host" }
    Say "Purging $InstallDir and $DataDir"
    Remove-Item -Recurse -Force $InstallDir -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $DataDir -ErrorAction SilentlyContinue
    Ok2 "Uninstalled and purged."
  } else {
    Ok2 "Uninstalled. Files ($InstallDir) and data were kept - re-run the installer to restore."
  }
  return
}

# --- Preflight -------------------------------------------------------------------------------
if (-not $NoService -and -not (Test-Admin)) {
  Die "Installing the service needs an elevated PowerShell. Re-run as Administrator, or use -NoService."
}
if ($env:PROCESSOR_ARCHITECTURE -ne "AMD64") {
  Die "This release is win-x64 only (got $env:PROCESSOR_ARCHITECTURE). Windows-on-ARM needs its own build - open an issue."
}
# node-pty needs the ConPTY API, which shipped in Windows 10 1809 (build 17763). Read the
# build from the registry, not [Environment]::OSVersion (compatibility shims lie).
$osBuild = [int](Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").CurrentBuildNumber
if ($osBuild -lt 17763) {
  Die "This Windows build ($osBuild) predates ConPTY. The host daemon needs 64-bit Windows 10 1809 / Windows Server 2019 or newer."
}

if ($Tailscale) { $Bind = "tailscale" }
$TailscaleRequested = $false
if ($Bind -eq "tailscale" -or $Bind -eq "tailnet") {
  $TailscaleRequested = $true
  $tsCmd = Get-Command tailscale -ErrorAction SilentlyContinue
  if ($tsCmd) { $tsExe = $tsCmd.Source }
  elseif (Test-Path "$env:ProgramFiles\Tailscale\tailscale.exe") { $tsExe = "$env:ProgramFiles\Tailscale\tailscale.exe" }
  else { Die "Tailscale bind requested but tailscale.exe was not found. Install it (https://tailscale.com/download), sign in, then re-run." }
  $tsIp = (& $tsExe ip -4 2>$null | Select-Object -First 1)
  if (-not $tsIp) { Die "Could not read this machine's Tailscale IPv4. Is it signed in and running?" }
  $Bind = $tsIp.Trim()
  Say "Binding to Tailscale address $Bind"
}

if ($ServiceAccount -eq "LocalSystem") {
  if (-not $DataDir)   { $DataDir   = Join-Path $InstallDir "data" }
  if (-not $SpacesDir) { $SpacesDir = Join-Path $InstallDir "spaces" }
  if (-not $ReposDir)  { $ReposDir  = Join-Path $InstallDir "repos" }
} else {
  if (-not $DataDir)   { $DataDir   = Join-Path $env:USERPROFILE ".vibemaxx-host" }
  if (-not $SpacesDir) { $SpacesDir = Join-Path $env:USERPROFILE "vibemaxx\spaces" }
  if (-not $ReposDir)  { $ReposDir  = Join-Path $env:USERPROFILE "vibemaxx\repos" }
}

# --- 1. Resolve the release source -----------------------------------------------------------
if (-not $ReleaseBaseUrl -and $env:VIBEMAXX_RELEASE_BASE_URL) { $ReleaseBaseUrl = $env:VIBEMAXX_RELEASE_BASE_URL }
if ($ReleaseBaseUrl) {
  $BaseUrl = $ReleaseBaseUrl.TrimEnd("/")
} elseif ($Version -eq "latest") {
  $BaseUrl = "https://github.com/$RepoSlug/releases/latest/download"
} else {
  $BaseUrl = "https://github.com/$RepoSlug/releases/download/$Version"
}
$isHttp = $BaseUrl -match "^https?://"
if ($BaseUrl -match "^file:///") { $BaseUrl = ([Uri]$BaseUrl).LocalPath.TrimEnd("\"); $isHttp = $false }

function Fetch-ReleaseFile([string]$name, [string]$dest) {
  if ($isHttp) {
    Invoke-WebRequest -Uri "$BaseUrl/$name" -OutFile $dest -UseBasicParsing
  } else {
    Copy-Item (Join-Path $BaseUrl $name) $dest -Force
  }
}

# --- 2. Download + verify --------------------------------------------------------------------
$Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("vibemaxx-host-dl-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Force -Path $Tmp | Out-Null
$ZipPath = Join-Path $Tmp $Asset
Say "Downloading $Asset ($(if ($ReleaseBaseUrl) { $BaseUrl } else { $Version }))"
Fetch-ReleaseFile $Asset $ZipPath

$shaOk = $true
try { Fetch-ReleaseFile "$Asset.sha256" "$ZipPath.sha256" } catch { $shaOk = $false }
if ($shaOk) {
  $expected = ((Get-Content "$ZipPath.sha256" -Raw) -split "\s+")[0].ToLowerInvariant()
  $actual = (Get-FileHash $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($expected -ne $actual) { Die "Checksum mismatch - refusing to install. expected $expected, got $actual" }
  Ok2 "Checksum verified"
} else {
  Warn2 "No checksum published for this release - skipping integrity check."
}

Say "Extracting"
$Staging = Join-Path $Tmp "extracted"
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $Staging)
foreach ($required in @("host-dist\host\index.js", "node\node.exe", "node_modules\node-pty", "package.json")) {
  if (-not (Test-Path (Join-Path $Staging $required))) { Die "Release zip is missing $required - refusing to install." }
}

# --- 3. Stop the service, swap the payload in --------------------------------------------------
$existingSvc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existingSvc -and $existingSvc.Status -ne "Stopped") {
  Say "Stopping running service $ServiceName for update"
  Stop-Service -Name $ServiceName -Force
  Start-Sleep -Seconds 2
}

Say "Installing to $InstallDir"
New-Item -ItemType Directory -Force -Path $InstallDir, $SvcDir, $LogsDir | Out-Null
foreach ($dir in @("host-dist", "node_modules", "node", ".vibemaxxagents")) {
  if (Test-Path (Join-Path $Staging $dir)) {
    Invoke-Robocopy (Join-Path $Staging $dir) (Join-Path $InstallDir $dir)
  }
}
Copy-Item (Join-Path $Staging "package.json") (Join-Path $InstallDir "package.json") -Force
Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue

# --- 4. Token (kept across re-runs) ------------------------------------------------------------
function Read-XmlEnv([string]$name) {
  try {
    $x = [xml](Get-Content $SvcXml -Raw)
    $node = $x.service.env | Where-Object { $_.name -eq $name }
    if ($node -and $node.value) { return [string]$node.value }
  } catch { }
  return ""
}
if (-not $Token -and (Test-Path $SvcXml)) {
  $Token = Read-XmlEnv "VIBEMAXX_HOST_TOKEN"
  if ($Token) { Say "Reusing the existing token" }
}
if (-not $Token) {
  Say "Generating a new bearer token"
  $bytes = New-Object byte[] 32
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  $rng.GetBytes($bytes)
  $rng.Dispose()
  $Token = ($bytes | ForEach-Object { $_.ToString("x2") }) -join ""
}
if (-not $GitHubToken -and (Test-Path $SvcXml)) { $GitHubToken = Read-XmlEnv "VIBEMAXX_HOST_GITHUB_TOKEN" }

# --- 5. Service account + PATH for agent CLIs ---------------------------------------------------
# Services do not get your user PATH (HKCU), so bake the npm global prefix (where
# `npm install -g claude/codex/...` puts its shims on Windows) in explicitly. %PATH% expands
# to the machine PATH when the service environment is built.
$npmPrefix = Join-Path $env:APPDATA "npm"
$npmCmd = Get-Command npm -ErrorAction SilentlyContinue
if ($npmCmd) {
  $p = (& npm config get prefix 2>$null | Select-Object -First 1)
  if ($p) { $npmPrefix = $p }
}
# git is what the repo/clone/push channels shell out to. The trailing %PATH% below expands to
# the MACHINE PATH at service start, but recent Git-for-Windows installers default to a
# PER-USER install (git on the user PATH only) - invisible to the service, so clones fail with
# "Install Git...". Resolve git's actual dir now and bake it in; also fold in the installing
# user's User PATH so other per-user tools resolve too. (git is a real .exe, safe on PATH -
# unlike npm .cmd shims, which is why agent bins are prepended, not run by bare name.)
$svcPathParts = @($npmPrefix, "$env:USERPROFILE\.local\bin")
$gitCmd = Get-Command git.exe -ErrorAction SilentlyContinue
if ($gitCmd) { $svcPathParts += (Split-Path $gitCmd.Source) }
else { Warn2 "git not found on PATH - repo MaxxSpaces (clone/push/pull) will fail until Git for Windows is installed. Re-run this installer afterward." }
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath) { $svcPathParts += $userPath.Trim(";") }
$svcPath = ($svcPathParts -join ";") + ";%PATH%"

$svcUser = "$env:USERDOMAIN\$env:USERNAME"
if ($ServiceCredential) {
  $nc = $ServiceCredential.GetNetworkCredential()
  if ($nc.Domain) { $svcUser = "$($nc.Domain)\$($nc.UserName)" }
  elseif ($nc.UserName -match "\\") { $svcUser = $nc.UserName }
  else { $svcUser = ".\$($nc.UserName)" }
}

# --- 6. Write the WinSW config -------------------------------------------------------------------
function Write-ServiceXml([bool]$includePassword, [string]$plainPassword) {
  $envLines = @(
    "  <env name=""VIBEMAXX_HOST_TOKEN"" value=""$(XmlEscape $Token)""/>"
    "  <env name=""VIBEMAXX_HOST_BIND"" value=""$(XmlEscape $Bind)""/>"
    "  <env name=""VIBEMAXX_HOST_PORT"" value=""$Port""/>"
    "  <env name=""VIBEMAXX_HOST_DATA_DIR"" value=""$(XmlEscape $DataDir)""/>"
    "  <env name=""VIBEMAXX_HOST_SPACES_DIR"" value=""$(XmlEscape $SpacesDir)""/>"
    "  <env name=""VIBEMAXX_HOST_REPOS_DIR"" value=""$(XmlEscape $ReposDir)""/>"
    "  <env name=""PATH"" value=""$(XmlEscape $svcPath)""/>"
  )
  if ($GitHubToken) { $envLines += "  <env name=""VIBEMAXX_HOST_GITHUB_TOKEN"" value=""$(XmlEscape $GitHubToken)""/>" }

  $accountBlock = ""
  if ($ServiceAccount -eq "CurrentUser") {
    $parts = $svcUser -split "\\", 2
    $pwLine = ""
    if ($includePassword) { $pwLine = "    <password>$(XmlEscape $plainPassword)</password>`n" }
    $accountBlock = @"
  <serviceaccount>
    <domain>$(XmlEscape $parts[0])</domain>
    <user>$(XmlEscape $parts[1])</user>
$pwLine    <allowservicelogon>true</allowservicelogon>
  </serviceaccount>
"@
  }

  $dependBlock = ""
  $delayedBlock = ""
  if ($TailscaleRequested) {
    if (Get-Service -Name "Tailscale" -ErrorAction SilentlyContinue) { $dependBlock = "  <depend>Tailscale</depend>`n" }
    $delayedBlock = "  <delayedAutoStart/>`n"
  }

  $xml = @"
<!-- Generated by install.ps1 (github.com/$RepoSlug) - re-run it to regenerate. This file
     holds the bearer token: the svc dir is ACL-restricted to Administrators/SYSTEM/the
     service account. -->
<service>
  <id>$ServiceName</id>
  <name>VibeMaxx Host</name>
  <description>VibeMaxx host daemon - agent sessions over WebSocket (Connected mode). Sessions survive app/client shutdown because their PTYs are children of this service.</description>
  <executable>$(XmlEscape $NodeExe)</executable>
  <arguments>"$(XmlEscape (Join-Path $InstallDir 'host-dist\host\index.js'))"</arguments>
  <workingdirectory>$(XmlEscape $InstallDir)</workingdirectory>
$($envLines -join "`n")
  <logpath>$(XmlEscape $LogsDir)</logpath>
  <log mode="roll-by-size">
    <sizeThreshold>10240</sizeThreshold>
    <keepFiles>4</keepFiles>
  </log>
  <onfailure action="restart" delay="2 sec"/>
  <onfailure action="restart" delay="10 sec"/>
  <resetfailure>1 hour</resetfailure>
  <stoptimeout>15 sec</stoptimeout>
$delayedBlock$dependBlock$accountBlock</service>
"@
  [System.IO.File]::WriteAllText($SvcXml, $xml, (New-Object System.Text.UTF8Encoding($false)))
}

$runCmd = Join-Path $SvcDir "run-foreground.cmd"
$ghLine = ""
if ($GitHubToken) { $ghLine = "set ""VIBEMAXX_HOST_GITHUB_TOKEN=$GitHubToken""`r`n" }
@"
@echo off
rem Foreground run of the VibeMaxx host daemon (same env as the service). Ctrl+C to stop.
rem Generated by install.ps1; contains the bearer token - this dir is ACL'd.
set "VIBEMAXX_HOST_TOKEN=$Token"
set "VIBEMAXX_HOST_BIND=$Bind"
set "VIBEMAXX_HOST_PORT=$Port"
set "VIBEMAXX_HOST_DATA_DIR=$DataDir"
set "VIBEMAXX_HOST_SPACES_DIR=$SpacesDir"
set "VIBEMAXX_HOST_REPOS_DIR=$ReposDir"
set "PATH=$npmPrefix;$env:USERPROFILE\.local\bin;%PATH%"
$ghLine"$NodeExe" "$InstallDir\host-dist\host\index.js" %*
"@ | Out-File -FilePath $runCmd -Encoding ascii

$tokensCmd = Join-Path $InstallDir "vibemaxx-host.cmd"
@"
@echo off
rem VibeMaxx host CLI wrapper, e.g.:  vibemaxx-host.cmd tokens add "Elliot's iPhone"
set "VIBEMAXX_HOST_DATA_DIR=$DataDir"
"$NodeExe" "$InstallDir\host-dist\host\index.js" %*
"@ | Out-File -FilePath $tokensCmd -Encoding ascii

Write-ServiceXml $false ""

# Lock the svc dir down (it holds the token): Administrators + SYSTEM + the installing user
# full, the service account read; inherited Users-read from C:\ is cut.
Say "Restricting ACLs on $SvcDir"
$installer = "$env:USERDOMAIN\$env:USERNAME"
& icacls $SvcDir /inheritance:r /grant:r "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-18:(OI)(CI)F" "${installer}:(OI)(CI)F" | Out-Null
if ($ServiceAccount -eq "CurrentUser" -and $svcUser -ne $installer) {
  & icacls $SvcDir /grant:r "${svcUser}:(OI)(CI)RX" | Out-Null
}
& icacls $LogsDir /grant "*S-1-5-18:(OI)(CI)M" | Out-Null
if ($ServiceAccount -eq "CurrentUser") { & icacls $LogsDir /grant "${svcUser}:(OI)(CI)M" | Out-Null }

# --- 6b. Codex posture + requested agent CLIs ---------------------------------------------------
$agentProfileRoot = $env:USERPROFILE
if ($ServiceAccount -eq "LocalSystem") { $agentProfileRoot = Join-Path $env:SystemRoot "System32\config\systemprofile" }
Write-CodexConfig $agentProfileRoot

$agentRequests = @()
foreach ($name in ($InstallAgent | ForEach-Object { $_ -split "," })) {
  if (-not $name.Trim()) { continue }
  $spec = Resolve-AgentSpec $name
  if (-not $spec) { Die "Unknown agent '$name'. Known: codex, claude-code, grok, antigravity, opencode, cursor (or use -AgentNpm <package>)." }
  $agentRequests += $spec
}
foreach ($pkg in $AgentNpm) {
  if ($pkg.Trim()) { $agentRequests += @{ binary = ""; kind = "npm"; payload = $pkg.Trim() } }
}
if ($agentRequests.Count -gt 0) {
  if (($agentRequests | Where-Object { $_.kind -eq "npm" }).Count -gt 0) {
    Install-NodeNpmIfMissing | Out-Null
  }
  foreach ($req in $agentRequests) {
    Say "Installing agent: $($req.payload)"
    if ($req.kind -eq "npm") {
      & npm install -g $req.payload --no-audit --no-fund
      if ($LASTEXITCODE -ne 0) { Die "npm install -g $($req.payload) failed (exit $LASTEXITCODE)." }
    } else {
      # Download-then-run from a scratch cwd (mirrors install.sh: piping feeds the vendor
      # script its own text on stdin, and some installers drop files into the cwd).
      $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("vm-agent-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
      New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
      $vendor = Join-Path $tmpDir "vm-install.ps1"
      Invoke-WebRequest -Uri $req.payload -OutFile $vendor -UseBasicParsing
      Push-Location $tmpDir
      try {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $vendor
        if ($LASTEXITCODE -ne 0) { Die "Installer for $($req.payload) failed (exit $LASTEXITCODE)." }
      } finally {
        Pop-Location
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
      }
    }
    if ($req.binary) {
      # Verify against the same dirs baked onto the service PATH, not just this shell's.
      $probe = "$npmPrefix;$env:USERPROFILE\.local\bin;$env:Path"
      $found = $false
      foreach ($dir in ($probe -split ";")) {
        if ($dir -and ((Test-Path (Join-Path $dir "$($req.binary).cmd")) -or (Test-Path (Join-Path $dir "$($req.binary).exe")))) { $found = $true; break }
      }
      if ($found) { Ok2 "$($req.binary) installed - new host sessions will resolve it (service PATH already includes the install dirs)" }
      else { Warn2 "$($req.binary) not found on the service PATH dirs after install - check the installer output above." }
    }
  }
}

if ($NoService) {
  Say "Install complete (service skipped: -NoService)."
  Write-Host ""
  Write-Host "  Run the daemon in the foreground with:" -ForegroundColor Green
  Write-Host "    $runCmd"
  Write-Host ""
  Write-Host "  Connect URL : ws://${Bind}:$Port"
  Write-Host "  Token       : $Token"
  return
}

# --- 7. WinSW + service install --------------------------------------------------------------------
if (-not (Test-Path $SvcExe)) {
  if ($WinSWPath) {
    if (-not (Test-Path $WinSWPath)) { Die "WinSW not found at $WinSWPath" }
    Copy-Item $WinSWPath $SvcExe -Force
  } else {
    Say "Downloading WinSW v2.12.0"
    Invoke-WebRequest -Uri $WinSWUrl -OutFile $SvcExe -UseBasicParsing
    $actual = (Get-FileHash $SvcExe -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $WinSWSha256) {
      Remove-Item $SvcExe -Force
      Die "WinSW download hash mismatch (got $actual). Refusing to install it."
    }
  }
}

$svcExists = [bool](Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)
if (-not $svcExists -and $ServiceAccount -eq "CurrentUser") {
  # WinSW needs the account password ONCE, at install time (Windows stores it). It goes into
  # the XML only for the install call and is stripped right after, so it never rests on disk.
  # <allowservicelogon> makes WinSW grant the "Log on as a service" right.
  if (-not $ServiceCredential) {
    Say "The service will run as $svcUser - enter that account's password once."
    Warn2 "The account PASSWORD - not a Windows Hello PIN. Microsoft-account sign-ins need the Microsoft account password."
    $attempts = 0
    while ($true) {
      $ServiceCredential = Get-Credential -UserName $svcUser -Message "Password for the vibemaxx-host service account (NOT your PIN)"
      if (-not $ServiceCredential) { Die "No credentials provided. Re-run, or use -ServiceAccount LocalSystem." }
      $attempts++
      if (Test-ServiceCredential $ServiceCredential) { break }
      if ($attempts -ge 2) {
        Warn2 "Could not verify that password locally - continuing anyway. If the service fails to start with a logon failure, it was wrong."
        break
      }
      Warn2 "That password did not verify against this machine's $svcUser account - try again."
    }
  }
  Write-ServiceXml $true $ServiceCredential.GetNetworkCredential().Password
  try {
    Say "Installing service $ServiceName (as $svcUser)"
    & $SvcExe install
    if ($LASTEXITCODE -ne 0) { Die "WinSW install failed (exit $LASTEXITCODE). If the password was wrong, re-run; or set the account in services.msc -> vibemaxx-host -> Log On." }
  } finally {
    Write-ServiceXml $false ""   # strip the password from disk no matter what
  }
} elseif (-not $svcExists) {
  Say "Installing service $ServiceName (as LocalSystem)"
  & $SvcExe install
  if ($LASTEXITCODE -ne 0) { Die "WinSW install failed (exit $LASTEXITCODE)." }
} else {
  Say "Service already installed - config refreshed (picked up on start)"
}

# --- 7b. Boot resilience (set via sc.exe - authoritative regardless of WinSW XML) --------------
# When bound to a Tailscale/VPN IP, delay the auto-start so the tailnet adapter exists before
# the daemon binds (belt-and-suspenders with the daemon's own bind-retry). Always widen the
# SCM crash-recovery beyond WinSW's default so a transient boot failure keeps retrying instead
# of latching "stopped".
if ($TailscaleRequested) {
  & sc.exe config $ServiceName start= delayed-auto | Out-Null
}
& sc.exe failure $ServiceName reset= 60 actions= restart/5000/restart/15000/restart/30000 | Out-Null

# --- 8. Firewall -------------------------------------------------------------------------------
if ($Bind -ne "127.0.0.1" -and -not $NoFirewall) {
  Say "Adding firewall rule for TCP $Port"
  Get-NetFirewallRule -DisplayName "VibeMaxx Host" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
  if ($TailscaleRequested) {
    New-NetFirewallRule -DisplayName "VibeMaxx Host" -Direction Inbound -Action Allow `
      -Protocol TCP -LocalPort $Port -RemoteAddress "100.64.0.0/10" | Out-Null
  } else {
    New-NetFirewallRule -DisplayName "VibeMaxx Host" -Direction Inbound -Action Allow `
      -Protocol TCP -LocalPort $Port -Profile Private, Domain | Out-Null
  }
}

# --- 9. Start + health check ---------------------------------------------------------------------
Say "Starting service $ServiceName"
$started = $true
try {
  Start-Service -Name $ServiceName -ErrorAction Stop
} catch {
  $started = $false
  Warn2 "The service was installed but failed to start: $($_.Exception.Message)"
  $wrapperLog = Join-Path $LogsDir "$ServiceName.wrapper.log"
  if (Test-Path $wrapperLog) {
    Warn2 "Last lines of $wrapperLog :"
    Get-Content $wrapperLog -Tail 8 | ForEach-Object { Write-Host "    $_" }
  }
}
if (-not $started -and $ServiceAccount -eq "CurrentUser") {
  # On a per-user service this is nearly always error 1069 (logon failure): the password
  # given at install doesn't match the account. The SCM stores whatever it is handed and
  # only checks at start. Fix it in place: re-prompt, update the stored credentials
  # (Win32_Service.Change - the "log on as a service" right was already granted by WinSW),
  # and start again.
  Write-Host ""
  Warn2 "This is usually a LOGON FAILURE: the password doesn't match $svcUser."
  Warn2 "A Windows Hello PIN is NOT the password; Microsoft-account sign-ins need the Microsoft account password."
  $svcCim = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'"
  foreach ($try in 1..2) {
    $retryCred = Get-Credential -UserName $svcUser -Message "Re-enter the password for $svcUser to fix the service logon"
    if (-not $retryCred) { break }
    $rnc = $retryCred.GetNetworkCredential()
    $startName = ".\$($rnc.UserName)"
    if ($rnc.Domain) { $startName = "$($rnc.Domain)\$($rnc.UserName)" }
    Invoke-CimMethod -InputObject $svcCim -MethodName Change -Arguments @{ StartName = $startName; StartPassword = $rnc.Password } | Out-Null
    try {
      Start-Service -Name $ServiceName -ErrorAction Stop
      $started = $true
      Ok2 "Service credentials fixed - it's running."
      break
    } catch {
      Warn2 "Still failing: $($_.Exception.Message)"
    }
  }
}
if (-not $started) {
  Write-Host ""
  Write-Host "  Fix it with ONE of:" -ForegroundColor Yellow
  Write-Host "    1. services.msc -> VibeMaxx Host -> Properties -> Log On -> re-enter the account and"
  Write-Host "       password -> OK, then run:  Start-Service $ServiceName"
  Write-Host "    2. Re-run this installer (token and data are kept; it repairs the service in place)."
  Write-Host "    3. Re-run with -ServiceAccount LocalSystem (no password prompt, but agents then run"
  Write-Host "       as SYSTEM with an empty profile and each agent CLI needs signing in again)."
  Write-Host "  If the account has NO password, Windows blocks service logon by default - set one,"
  Write-Host "  or use option 3."
  Write-Host "  The daemon itself can be sanity-checked anytime with: $SvcDir\run-foreground.cmd"
  Die "Service $ServiceName did not start."
}

$health = "unreachable"
foreach ($i in 1..20) {
  Start-Sleep -Milliseconds 500
  try {
    $resp = Invoke-WebRequest -Uri "http://${Bind}:$Port/healthz" -UseBasicParsing -TimeoutSec 2
    if ($resp.StatusCode -eq 200) { $health = $resp.Content.Trim(); break }
  } catch { }
}
$svcStatus = (Get-Service -Name $ServiceName).Status
if ($health -ne "ok") {
  Warn2 "Health check did not return ok (service: $svcStatus). Logs: $LogsDir\$ServiceName.out.log / .err.log"
}

# --- Summary ----------------------------------------------------------------------------------------
Write-Host ""
Write-Host "VibeMaxx host is set up." -ForegroundColor Green
Write-Host ""
Write-Host "  Service     : $ServiceName ($svcStatus, runs as $(if ($ServiceAccount -eq 'CurrentUser') { $svcUser } else { 'LocalSystem' }))"
Write-Host "  Health      : http://${Bind}:$Port/healthz -> $health"
Write-Host "  Data dir    : $DataDir"
Write-Host "  Logs        : $LogsDir"
Write-Host ""
Write-Host "  Connect from the desktop app (Settings -> Connections -> Host connection):"
Write-Host "    URL   : ws://${Bind}:$Port"
Write-Host "    Token : $Token"
Write-Host ""
Write-Host "  Manage      : Stop-Service $ServiceName / Start-Service $ServiceName / Restart-Service $ServiceName"
Write-Host "  Device keys : $tokensCmd tokens add ""Elliot's iPhone"""
Write-Host "  Update      : re-run this installer (token + data are kept)"
Write-Host "  Uninstall   : re-run with -Uninstall (add -Purge to delete data too)"
Write-Host ""
if ($Bind -eq "127.0.0.1") {
  Warn2 "Loopback-only bind: other devices cannot reach it. Re-run with -Tailscale to bind your tailnet IP."
}
Warn2 "Windows sleeps by default, which suspends every hosted session. To keep the box awake on AC power:"
Write-Host "    powercfg /change standby-timeout-ac 0"

}

# Runner. Errors print in red and the console STAYS OPEN (vital for the `irm | iex` one-liner,
# where the window would otherwise vanish before the message could be read). When run as a
# file (powershell -File install.ps1), also report failure through the exit code.
try {
  Invoke-VibeMaxxHostInstall
} catch {
  Write-Host ""
  Write-Host "x  $($_.Exception.Message)" -ForegroundColor Red
  if ($PSCommandPath) { exit 1 }
}
