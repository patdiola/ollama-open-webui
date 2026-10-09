# Open WebUI + Ollama setup for Windows 10/11. macOS/Linux: run ./setup.sh
#
#   setup.cmd             first run: configure, then start everything
#                         later runs: apply .env (update images, pull models)
#   setup.cmd configure   change your answers, then apply
#   setup.cmd status      show what's running
#   setup.cmd stop        stop the containers (data is kept)
#
# All answers are saved to .env (gitignored). Nothing personal is written
# anywhere else. Compatible with Windows PowerShell 5.1.
param([string]$Command = "")

$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot

$EnvFile = Join-Path $PSScriptRoot ".env"
$ExampleFile = Join-Path $PSScriptRoot ".env.example"
$OllamaServices = @("ollama-cpu", "ollama-nvidia", "ollama-amd")
$script:TsUrl = ""

# ------------------------------------------------------------------ helpers

function Say([string]$m)  { Write-Host "  $m" }
function Ok([string]$m)   { Write-Host "  ok  " -ForegroundColor Green -NoNewline; Write-Host $m }
function Warn([string]$m) { Write-Host "  !!  " -ForegroundColor Yellow -NoNewline; Write-Host $m }
function Step([string]$m) { Write-Host ""; Write-Host "== $m" -ForegroundColor Cyan }
function Fail([string]$m) { Write-Host ""; Write-Host "Error: $m" -ForegroundColor Red; exit 1 }

function Ask([string]$q, [string]$def) {
  $hint = ""
  if ($def) { $hint = " [$def]" }
  $r = Read-Host "  $q$hint"
  if ([string]::IsNullOrWhiteSpace($r)) { return $def }
  return $r.Trim()
}

function Ask-Secret([string]$q) {
  $s = Read-Host "  $q" -AsSecureString
  $p = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($p) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p) }
}

function YesNo([string]$q, [string]$def) {
  $hint = "y/N"
  if ($def -eq "y") { $hint = "Y/n" }
  while ($true) {
    $r = Read-Host "  $q [$hint]"
    if ([string]::IsNullOrWhiteSpace($r)) { $r = $def }
    if ($r -match "^[Yy]") { return $true }
    if ($r -match "^[Nn]") { return $false }
  }
}

function Have([string]$name) { return [bool](Get-Command $name -ErrorAction SilentlyContinue) }

# Runs a native command, hiding its output. Returns $true on exit code 0.
function Quiet([string]$exe, [string[]]$argv) {
  $ErrorActionPreference = "Continue"
  & $exe @argv 2>&1 | Out-Null
  return ($LASTEXITCODE -eq 0)
}

# Runs a native command in this console, output shown. Returns $true on exit
# code 0. (Start-Process keeps progress bars and keeps output out of the
# function's return value.)
function Run([string]$exe, [string[]]$argv) {
  $p = Start-Process -FilePath $exe -ArgumentList $argv -NoNewWindow -Wait -PassThru
  return ($p.ExitCode -eq 0)
}

function Read-EnvLines([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return @() }
  return @([IO.File]::ReadAllLines($path))
}

# Value from .env, falling back to .env.example.
function EnvGet([string]$key) {
  foreach ($f in @($EnvFile, $ExampleFile)) {
    $hit = $null
    foreach ($line in (Read-EnvLines $f)) {
      if ($line.StartsWith("$key=")) { $hit = $line.Substring($key.Length + 1) }
    }
    if ($null -ne $hit) { return $hit.Trim().Trim('"').Trim("'") }
  }
  return ""
}

# Replaces or appends KEY=VALUE in .env (UTF-8 without BOM, LF endings).
# Values with spaces, $, # or quotes are single-quoted so Compose reads them literally.
function EnvSet([string]$key, [string]$value) {
  if ($value.Contains("'")) { Fail "$key can't contain a single quote." }
  if ($value -match '[\s$#"`\\]') { $value = "'$value'" }
  $out = New-Object System.Collections.Generic.List[string]
  $done = $false
  foreach ($line in (Read-EnvLines $EnvFile)) {
    if ($line.StartsWith("$key=")) {
      if (-not $done) { $out.Add("$key=$value") }
      $done = $true
    } else { $out.Add($line) }
  }
  if (-not $done) { $out.Add("$key=$value") }
  [IO.File]::WriteAllText($EnvFile, (($out -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
}

function New-Secret {
  $bytes = New-Object byte[] 32
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  $rng.GetBytes($bytes)
  $rng.Dispose()
  return (($bytes | ForEach-Object { $_.ToString("x2") }) -join "")
}

function Http-Ok([string]$url) {
  try {
    $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 3
    return ($r.StatusCode -eq 200)
  } catch { return $false }
}

function Offer-Install([string]$what, [string]$wingetId) {
  Warn "$what is not installed."
  if (-not (Have "winget")) { Fail "Install $what, then run setup.cmd again." }
  Say "Install command: winget install --id $wingetId -e"
  if (YesNo "Run it now?" "n") {
    if (-not (Run "winget" @("install", "--id", $wingetId, "-e", "--accept-package-agreements", "--accept-source-agreements"))) {
      Fail "Installing $what failed. Install it manually, then run setup.cmd again."
    }
    # Pick up PATH changes from the installer.
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
  } else {
    Fail "Install $what, then run setup.cmd again."
  }
}

# ------------------------------------------------------------- hardware

function Get-NvidiaGb {
  if (-not (Have "nvidia-smi")) { return 0 }
  try {
    $ErrorActionPreference = "Continue"
    $lines = & nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null
    $sum = 0
    foreach ($l in @($lines)) { $sum += [double]$l }
    return [math]::Round($sum / 1024)
  } catch { return 0 }
}

function Get-MemoryBudget {
  $vram = Get-NvidiaGb
  if ($vram -gt 0) { return @($vram, "$vram GB NVIDIA GPU memory") }
  $ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
  return @([math]::Round($ram * 0.5), "$ram GB RAM, no NVIDIA GPU detected (smaller models are faster)")
}

# ------------------------------------------------------------- configure

function Get-Catalog {
  $list = @()
  foreach ($line in [IO.File]::ReadAllLines((Join-Path $PSScriptRoot "models.txt"))) {
    if ($line -match "^\s*(#|$)") { continue }
    $p = $line.Split("|")
    $list += ,@($p[0], [double]$p[1], $p[2])
  }
  return $list
}

function Pick-Models([string]$current) {
  $budget = Get-MemoryBudget
  Say "Detected: $($budget[1])"
  Say ""
  $catalog = Get-Catalog
  for ($i = 0; $i -lt $catalog.Count; $i++) {
    $m = $catalog[$i]
    $fit = "big  "
    if ($m[1] * 1.2 -le $budget[0]) { $fit = "fits " }
    Write-Host ("   {0,2}) {1,-18} {2,5} GB  {3}{4}" -f ($i + 1), $m[0], $m[1], $fit, $m[2])
  }
  Say ""
  Say "How to choose: start with one or two models marked 'fits'. Bigger"
  Say "models are smarter but slower; a model marked 'big' still works, just"
  Say "slowly. Each one takes its size in disk space. You can add or remove"
  Say "models later with 'setup.cmd configure'. Browse more at ollama.com/library."
  Say ""
  Say "Enter numbers and/or any Ollama tags, separated by spaces (e.g. 2 5)."
  $answer = Ask "Models to download" $current
  $out = @()
  foreach ($c in ($answer -split "\s+" | Where-Object { $_ })) {
    if ($c -match "^\d+$") {
      $n = [int]$c
      if ($n -ge 1 -and $n -le $catalog.Count) { $out += $catalog[$n - 1][0] }
      else { Warn "No model number $c; skipped." }
    } else { $out += $c }
  }
  return ($out -join " ")
}

function Configure-Cloud {
  $urls = EnvGet "OPENAI_API_BASE_URLS"
  $keys = EnvGet "OPENAI_API_KEYS"
  if ($urls) {
    Say "Currently configured: $(@($urls.Split(';')).Count) cloud connection(s)."
    if (YesNo "Keep them?" "y") { return @($urls, $keys) }
  }
  $u = @(); $k = @()
  Say "Cloud models are optional. They're smarter than most local models, but"
  Say "chats sent to them leave your machine, and the provider bills you per use."
  Say "Skip this if you want everything private; you can add one later."
  if (-not (YesNo "Add a cloud model provider (OpenAI, OpenRouter, ...)?" "n")) { return @("", "") }
  while ($true) {
    Say "  1) OpenAI      GPT models, directly from OpenAI"
    Say "  2) OpenRouter  one key for many providers (Claude, GPT, Gemini, ...)"
    Say "  3) Other       any OpenAI-compatible API (Groq, Together, a local server)"
    $choice = Ask "Provider" "1"
    $url = ""
    switch ($choice) {
      "1" {
        $url = "https://api.openai.com/v1"
        Say "Get a key: sign in at https://platform.openai.com/api-keys, click"
        Say "'Create new secret key', and copy it (starts with sk-). API use is"
        Say "billed separately from ChatGPT; add credit under Settings > Billing."
      }
      "2" {
        $url = "https://openrouter.ai/api/v1"
        Say "Get a key: sign in at https://openrouter.ai/keys, click 'Create Key',"
        Say "and copy it (starts with sk-or-). Add credit at openrouter.ai/credits."
      }
      "3" {
        Say "Find the base URL in the provider's API docs (often ends in /v1),"
        Say "and create a key in their dashboard."
        $url = Ask "Base URL" ""
      }
      default { continue }
    }
    if (-not $url) { continue }
    $key = Ask-Secret "Paste the API key (hidden; it's saved only in .env)"
    if (-not $key) { Warn "No key entered; skipped."; continue }
    if ($key.Contains(";")) { Warn "Keys can't contain ';'. Skipped."; continue }
    $u += $url; $k += $key
    if (-not (YesNo "Add another provider?" "n")) { break }
  }
  return @(($u -join ";"), ($k -join ";"))
}

function Configure-Search {
  $cur = EnvGet "WEB_SEARCH_ENGINE"
  if ((EnvGet "ENABLE_WEB_SEARCH") -ne "true" -or -not $cur) { $cur = "off" }
  Say "Web search lets models look things up online. Optional; the search"
  Say "queries (not your whole chat) go to the provider you pick."
  Say "  off         no web access (most private)"
  Say "  duckduckgo  no account or key needed; can be rate-limited if used heavily"
  Say "  brave       needs a Brave Search API key; reliable, independent index"
  Say "  tavily      needs a Tavily API key; built for AI, returns cleaner results"
  Say "Not sure? Pick duckduckgo, or off."
  do { $engine = Ask "Web search" $cur } until (@("off", "duckduckgo", "brave", "tavily") -contains $engine)
  $brave = EnvGet "BRAVE_SEARCH_API_KEY"
  $tavily = EnvGet "TAVILY_API_KEY"
  if ($engine -eq "brave" -and (-not $brave -or -not (YesNo "Keep the saved Brave key?" "y"))) {
    Say "Get a key: sign up at https://api-dashboard.search.brave.com, choose a"
    Say "plan (see brave.com/search/api for current pricing), then open"
    Say "'API Keys' and copy the key."
    $brave = Ask-Secret "Paste the Brave Search API key (hidden)"
  }
  if ($engine -eq "tavily" -and (-not $tavily -or -not (YesNo "Keep the saved Tavily key?" "y"))) {
    Say "Get a key: sign up at https://app.tavily.com; your key (starts with"
    Say "tvly-) is on the overview page. Check their site for current free limits."
    $tavily = Ask-Secret "Paste the Tavily API key (hidden)"
  }
  return @($engine, $brave, $tavily)
}

function Configure {
  Write-Host ""
  Write-Host "Open WebUI + Ollama setup (Windows)" -ForegroundColor Cyan
  Say "Answer each question, or press Enter to keep the value in [brackets]."
  Say "Nothing is changed until you confirm at the end."

  Step "1/6  Ollama"
  Say "native:    the Ollama app for Windows. Recommended: simplest, and uses"
  Say "           NVIDIA and AMD graphics cards automatically."
  Say "container: Ollama inside Docker. Only if you prefer everything in Docker;"
  Say "           supports NVIDIA cards or CPU only."
  Say "Not sure? Press Enter for native."
  do { $mode = Ask "Ollama mode" (EnvGet "OLLAMA_MODE") } until (@("native", "container") -contains $mode)
  $hw = ""
  if ($mode -eq "container") {
    $hw = EnvGet "COMPOSE_PROFILES"
    if (-not $hw) { if ((Get-NvidiaGb) -gt 0) { $hw = "ollama-nvidia" } else { $hw = "ollama-cpu" } }
    Say "ollama-nvidia  NVIDIA graphics card (Docker Desktop passes it through)"
    Say "ollama-cpu     no NVIDIA card; works, but slowly"
    Say "The suggestion below was detected on this machine; press Enter to accept it."
    do { $hw = Ask "Ollama hardware" $hw } until (@("ollama-cpu", "ollama-nvidia") -contains $hw)
  }

  Step "2/6  Models"
  $models = Pick-Models (EnvGet "OLLAMA_PULL_MODELS")

  Step "3/6  Local port"
  Say "Open WebUI listens on this machine only (127.0.0.1). Keep 3000 unless"
  Say "another app already uses it; then pick any free number like 3001 or 8080."
  do { $port = Ask "Port" (EnvGet "OPEN_WEBUI_PORT") } until ($port -match "^\d+$")

  Step "4/6  Remote access (Tailscale)"
  Say "Tailscale lets your phone and laptop reach this machine from anywhere at"
  Say "https://<pc-name>.<tailnet>.ts.net, without exposing anything to your"
  Say "Wi-Fi network or the internet. It's free for personal use: create an"
  Say "account at https://login.tailscale.com/start and install the app on each"
  Say "device. Say no only if you'll use Open WebUI on this machine alone."
  $tsDef = "y"
  if ((EnvGet "TAILSCALE_SERVE") -eq "false") { $tsDef = "n" }
  $ts = "false"
  if (YesNo "Set up Tailscale remote access?" $tsDef) { $ts = "true" }

  Step "5/6  Optional extras"
  $cloud = Configure-Cloud
  $search = Configure-Search

  Step "6/6  Where settings live"
  Say "a) .env (recommended): your answers here, or edits to .env (by hand or by"
  Say "   an AI coding CLI), are applied on every start. Changes you make to the"
  Say "   same settings in Open WebUI's Admin Panel reset on restart."
  Say "b) Admin Panel: .env only sets things up the first time; afterwards you"
  Say "   manage settings in Open WebUI's web interface."
  Say "Pick a if you'd rather configure from files or with an AI CLI."
  $pcDef = "a"
  if ((EnvGet "ENABLE_PERSISTENT_CONFIG") -eq "true") { $pcDef = "b" }
  do { $pc = Ask "Choice" $pcDef } until (@("a", "b") -contains $pc)
  $persist = "false"
  if ($pc -eq "b") { $persist = "true" }

  Step "Summary"
  $modeText = $mode
  if ($hw) { $modeText = "$mode ($hw)" }
  $settingsFrom = ".env"
  if ($persist -eq "true") { $settingsFrom = "Admin Panel" }
  $modelText = $models; if (-not $modelText) { $modelText = "(none)" }
  $cloudText = $cloud[0]; if (-not $cloudText) { $cloudText = "(none)" }
  Say "Ollama:        $modeText"
  Say "Models:        $modelText"
  Say "Local URL:     http://localhost:$port"
  Say "Tailscale:     $ts"
  Say "Cloud APIs:    $cloudText"
  Say "Web search:    $($search[0])"
  Say "Settings from: $settingsFrom"
  if (-not (YesNo "Save to .env?" "y")) { Fail "Nothing saved." }

  if (-not (Test-Path -LiteralPath $EnvFile)) {
    $text = [IO.File]::ReadAllText($ExampleFile) -replace "`r`n", "`n"
    [IO.File]::WriteAllText($EnvFile, $text, (New-Object Text.UTF8Encoding $false))
  }
  if (-not (EnvGet "WEBUI_SECRET_KEY")) { EnvSet "WEBUI_SECRET_KEY" (New-Secret) }

  EnvSet "OLLAMA_MODE" $mode
  if ($mode -eq "container") {
    EnvSet "COMPOSE_PROFILES" $hw
    EnvSet "OLLAMA_BASE_URL" "http://ollama:11434"
  } else {
    EnvSet "COMPOSE_PROFILES" ""
    EnvSet "OLLAMA_BASE_URL" "http://host.docker.internal:11434"
  }
  EnvSet "OLLAMA_PULL_MODELS" $models
  EnvSet "OPEN_WEBUI_PORT" $port
  EnvSet "TAILSCALE_SERVE" $ts
  EnvSet "OPENAI_API_BASE_URLS" $cloud[0]
  EnvSet "OPENAI_API_KEYS" $cloud[1]
  if ($cloud[0]) { EnvSet "ENABLE_OPENAI_API" "true" } else { EnvSet "ENABLE_OPENAI_API" "false" }
  if ($search[0] -eq "off") {
    EnvSet "ENABLE_WEB_SEARCH" "false"; EnvSet "WEB_SEARCH_ENGINE" ""
  } else {
    EnvSet "ENABLE_WEB_SEARCH" "true"; EnvSet "WEB_SEARCH_ENGINE" $search[0]
  }
  EnvSet "BRAVE_SEARCH_API_KEY" $search[1]
  EnvSet "TAVILY_API_KEY" $search[2]
  EnvSet "ENABLE_PERSISTENT_CONFIG" $persist
  Ok "Saved .env"
}

# ------------------------------------------------------------------ apply

function Check-Docker {
  if (-not (Have "docker")) { Offer-Install "Docker Desktop" "Docker.DockerDesktop" }
  if (-not (Quiet "docker" @("compose", "version"))) { Fail "Docker Compose v2 is missing (the 'docker compose' command)." }
  if (-not (Quiet "docker" @("info"))) {
    Fail "Docker isn't running. Start Docker Desktop, wait until it says 'Engine running', then run setup.cmd again."
  }
  Ok "Docker is running"
}

function Ollama-Exe {
  if (Have "ollama") { return "ollama" }
  $p = Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama.exe"
  if (Test-Path -LiteralPath $p) { return $p }
  return ""
}

function Ollama-Up { return (Http-Ok "http://127.0.0.1:11434/api/version") }

function Check-NativeOllama {
  if (-not (Ollama-Exe)) { Offer-Install "Ollama" "Ollama.Ollama" }
  $exe = Ollama-Exe
  if (-not $exe) { Fail "Ollama was installed but isn't on PATH yet. Open a new terminal and run setup.cmd again." }
  if (-not (Ollama-Up)) {
    Say "Starting Ollama..."
    $app = Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama app.exe"
    if (Test-Path -LiteralPath $app) { Start-Process -FilePath $app }
    else { Start-Process -FilePath $exe -ArgumentList "serve" -WindowStyle Hidden }
    for ($i = 0; $i -lt 30 -and -not (Ollama-Up); $i++) { Start-Sleep -Seconds 1 }
    if (-not (Ollama-Up)) { Fail "Ollama didn't start. Open the Ollama app, then run setup.cmd again." }
  }
  Ok "Ollama is running"
}

function Invoke-Ollama([string[]]$argv) {
  if ((EnvGet "OLLAMA_MODE") -eq "container") { return (Run "docker" (@("exec", "ollama", "ollama") + $argv)) }
  return (Run (Ollama-Exe) $argv)
}

function Pull-Models {
  $models = EnvGet "OLLAMA_PULL_MODELS"
  if (-not $models) { Say "No models selected. Run 'setup.cmd configure' to pick some."; return }
  $ErrorActionPreference = "Continue"
  if ((EnvGet "OLLAMA_MODE") -eq "container") { $listing = & docker exec ollama ollama list 2>$null }
  else { $listing = & (Ollama-Exe) list 2>$null }
  $have = @($listing | Select-Object -Skip 1 | ForEach-Object { ($_ -split "\s+")[0] })
  foreach ($m in ($models -split "\s+" | Where-Object { $_ })) {
    if (-not $m.Contains(":")) { $m = "$m`:latest" }
    if ($have -contains $m) { Ok "$m already downloaded"; continue }
    Say "Downloading $m (this can take a while)..."
    if (-not (Invoke-Ollama @("pull", $m))) { Warn "Couldn't download $m. Check the tag at https://ollama.com/library" }
  }
}

function Test-Onboarding([string]$port) {
  try {
    $cfg = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/config" -TimeoutSec 5
    return ($cfg.onboarding -eq $true)
  } catch { return $false }
}

function First-Admin([string]$port) {
  if (-not (Test-Onboarding $port)) { return }
  Step "Create your admin account"
  Say "No accounts exist yet. The first account becomes the admin, and"
  Say "sign-ups close after that. Create it now, before remote access is on."
  Say "The email is only a login name (Open WebUI never sends mail), and the"
  Say "password protects every account, so use a strong one and save it in a"
  Say "password manager. There's no 'forgot password' link."
  Say "Opening http://localhost:$port"
  Start-Process "http://localhost:$port"
  while ($true) {
    $r = Read-Host "  Press Enter when the admin account exists (or type 'skip')"
    if ($r -eq "skip") { Warn "Skipped. Create the admin account before sharing access."; return }
    if (-not (Test-Onboarding $port)) { break }
    Warn "No account yet."
  }
  Ok "Admin account exists"
}

function Tailscale-Exe {
  if (Have "tailscale") { return "tailscale" }
  $p = Join-Path $env:ProgramFiles "Tailscale\tailscale.exe"
  if (Test-Path -LiteralPath $p) { return $p }
  return ""
}

function Setup-Tailscale([string]$port) {
  if (-not (Tailscale-Exe)) { Offer-Install "Tailscale" "Tailscale.Tailscale" }
  $ts = Tailscale-Exe
  if (-not $ts) { Fail "Open the Tailscale app and sign in, then run setup.cmd again." }
  if (-not (Quiet $ts @("status"))) {
    Fail "Tailscale isn't connected. Open Tailscale from the system tray, sign in, then run setup.cmd again."
  }
  Ok "Tailscale is connected"
  Say "Publishing Open WebUI to your tailnet with 'tailscale serve' (HTTPS)."
  Say "If asked, enable HTTPS certificates for your tailnet using the link shown."
  if (-not (Run $ts @("serve", "--bg", $port))) {
    Fail "tailscale serve failed. If it mentions access, run setup.cmd from an Administrator terminal."
  }
  $ErrorActionPreference = "Continue"
  $status = (& $ts serve status 2>$null) -join "`n"
  $m = [regex]::Match($status, "https://\S+")
  $script:TsUrl = "https://<pc-name>.<tailnet>.ts.net"
  if ($m.Success) { $script:TsUrl = $m.Value }
  Ok "Remote access: $script:TsUrl (your tailnet only)"
}

function Apply {
  if (-not (Test-Path -LiteralPath $EnvFile)) { Configure }
  $mode = EnvGet "OLLAMA_MODE"
  $hw = EnvGet "COMPOSE_PROFILES"
  $port = EnvGet "OPEN_WEBUI_PORT"
  if (-not (EnvGet "WEBUI_SECRET_KEY")) { EnvSet "WEBUI_SECRET_KEY" (New-Secret) }

  Step "Checking prerequisites"
  Check-Docker
  if ($mode -eq "native") { Check-NativeOllama }

  Step "Starting containers"
  # Remove an Ollama container from a previously chosen profile.
  foreach ($svc in $OllamaServices) {
    if ($svc -ne $hw) { Quiet "docker" @("compose", "--profile", $svc, "rm", "-s", "-f", $svc) | Out-Null }
  }
  if (-not (Run "docker" @("compose", "pull"))) { Fail "docker compose pull failed." }
  if (-not (Run "docker" @("compose", "up", "-d"))) { Fail "docker compose up failed." }
  Say "Waiting for Open WebUI..."
  $healthy = $false
  for ($i = 0; $i -lt 90; $i++) {
    if (Http-Ok "http://127.0.0.1:$port/health") { $healthy = $true; break }
    Start-Sleep -Seconds 2
  }
  if (-not $healthy) { Fail "Open WebUI didn't become healthy. See: docker compose logs open-webui" }
  Ok "Open WebUI is up at http://localhost:$port"

  Step "Models"
  Pull-Models

  First-Admin $port

  if ((EnvGet "TAILSCALE_SERVE") -eq "true") {
    Step "Remote access"
    Setup-Tailscale $port
  }

  Step "Done"
  Say "Local:   http://localhost:$port"
  if ($script:TsUrl) { Say "Remote:  $script:TsUrl" }
  Say "Family:  see docs\family-access.md"
  Say "Change settings: setup.cmd configure   (or ask an AI coding CLI; see AGENTS.md)"
}

function Show-Status {
  Run "docker" @("compose", "ps") | Out-Null
  if ((EnvGet "OLLAMA_MODE") -eq "native") {
    if (Ollama-Up) { Ok "Native Ollama is running" } else { Warn "Native Ollama is not running" }
  }
  $ts = Tailscale-Exe
  if ($ts) { Run $ts @("serve", "status") | Out-Null }
}

switch ($Command) {
  ""          { Apply }
  "configure" { Configure; Apply }
  "apply"     { Apply }
  "update"    { Apply }
  "status"    { Show-Status }
  "stop"      { Run "docker" @("compose", "down") | Out-Null }
  "help"      { Get-Content -LiteralPath $PSCommandPath -TotalCount 10 | ForEach-Object { $_ -replace "^# ?", "" } }
  default     { Fail "Unknown command '$Command'. Try: setup.cmd help" }
}
