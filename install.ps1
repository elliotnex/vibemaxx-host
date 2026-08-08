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
$WinSWUrl = "https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe"
# SHA-256 of the official WinSW v2.12.0 x64 release asset; the download is refused on mismatch.
$WinSWSha256 = "05b82d46ad331cc16bdc00de5c6332c1ef818df8ceefcd49c726553209b3a0da"

function Say([string]$msg)  { Write-Host "==> $msg" -ForegroundColor Cyan }
function Ok2([string]$msg)  { Write-Host "+ $msg" -ForegroundColor Green }
function Warn2([string]$msg) { Write-Host "!  $msg" -ForegroundColor Yellow }
function Die([string]$msg)  { Write-Host "x  $msg" -ForegroundColor Red; exit 1 }

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
  exit 0
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
$svcPath = "$npmPrefix;$env:USERPROFILE\.local\bin;%PATH%"

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

if ($NoService) {
  Say "Install complete (service skipped: -NoService)."
  Write-Host ""
  Write-Host "  Run the daemon in the foreground with:" -ForegroundColor Green
  Write-Host "    $runCmd"
  Write-Host ""
  Write-Host "  Connect URL : ws://${Bind}:$Port"
  Write-Host "  Token       : $Token"
  exit 0
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
    $ServiceCredential = Get-Credential -UserName $svcUser -Message "Password for the vibemaxx-host service account"
    if (-not $ServiceCredential) { Die "No credentials provided. Re-run, or use -ServiceAccount LocalSystem." }
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
Start-Service -Name $ServiceName

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
