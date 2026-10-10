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
$OllamaTuning = @("OLLAMA_MODELS", "OLLAMA_CONTEXT_LENGTH", "OLLAMA_FLASH_ATTENTION", "OLLAMA_KV_CACHE_TYPE", "OLLAMA_KEEP_ALIVE")
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

# Reloads PATH from Windows, so programs installed after this terminal (or
# WSL, which passes on the PATH it started with) opened are found.
function Refresh-Path {
  $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
}
Refresh-Path

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
    Refresh-Path
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

# A setting the running native Ollama uses, from its server log; $null if
# unknown. The Ollama app has its own settings (model location, context
# length) that it passes to the server, which can win over .env.
function Get-OllamaInUse([string]$key) {
  $log = Join-Path $env:LOCALAPPDATA "Ollama\server.log"
  try { $m = Select-String -LiteralPath $log -Pattern "${key}:(.*?) OLLAMA_" -ErrorAction Stop | Select-Object -Last 1 }
  catch { return $null }
  if (-not $m) { return $null }
  return $m.Matches[0].Groups[1].Value.Replace("\\", "\")
}

# Warns when native Ollama doesn't use a setting from .env.
function Check-OllamaSettings {
  $bad = @()
  foreach ($k in $OllamaTuning) {
    $want = EnvGet $k
    if (-not $want) { continue }
    $have = Get-OllamaInUse $k
    if ($null -eq $have) { return }
    if ($k -eq "OLLAMA_FLASH_ATTENTION") { if ($want -eq "1") { $want = "true" } elseif ($want -eq "0") { $want = "false" } }
    if ($have.TrimEnd("\") -ne $want.TrimEnd("\")) { $bad += "$k is '$have', .env says '$($want)'" }
  }
  if ($bad.Count -eq 0) { return }
  Warn "Ollama isn't using some settings from .env:"
  foreach ($b in $bad) { Say "      $b" }
  Say "The Ollama app's own Settings (Model location, Context length) can"
  Say "override them. Change those there to match, then quit and reopen Ollama."
}

# Folders holding Ollama models, up to 4 levels deep on each fixed drive
# (skipping system folders), so existing downloads can be reused.
function Find-ModelStores {
  $skip = @("Windows", "Program Files", "Program Files (x86)", "ProgramData", "`$Recycle.Bin",
    "System Volume Information", "Recovery", "AppData", "node_modules", ".git")
  $found = New-Object System.Collections.ArrayList
  function Walk([string]$dir, [int]$depth) {
    if ((Test-Path -LiteralPath (Join-Path $dir "manifests")) -and (Test-Path -LiteralPath (Join-Path $dir "blobs"))) {
      [void]$found.Add($dir); return
    }
    if ($depth -le 0) { return }
    foreach ($sub in [IO.Directory]::EnumerateDirectories($dir)) {
      if ($skip -contains [IO.Path]::GetFileName($sub)) { continue }
      try { Walk $sub ($depth - 1) } catch { }
    }
  }
  foreach ($drive in [IO.DriveInfo]::GetDrives()) {
    if ($drive.DriveType -ne "Fixed" -or -not $drive.IsReady) { continue }
    try { Walk $drive.RootDirectory.FullName 4 } catch { }
  }
  return $found
}

# Model names (name:tag) in an Ollama models folder.
function Get-StoreModels([string]$dir) {
  $root = Join-Path $dir "manifests"
  if (-not (Test-Path -LiteralPath $root)) { return @() }
  $names = @()
  foreach ($f in Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue) {
    $parts = $f.FullName.Substring($root.Length + 1).Split("\")
    if ($parts.Count -lt 2) { continue }
    $name = $parts[0..($parts.Count - 2)] -join "/"
    $name = $name -replace "^registry\.ollama\.ai/library/", "" -replace "^registry\.ollama\.ai/", ""
    $names += "$name`:$($parts[-1])"
  }
  return $names
}

function Get-FolderGb([string]$dir) {
  $blobs = Join-Path $dir "blobs"
  if (-not (Test-Path -LiteralPath $blobs)) { return 0 }
  $sum = (Get-ChildItem -LiteralPath $blobs -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
  return [math]::Round($sum / 1GB)
}

# Asks where Ollama keeps models. Returns "" for Ollama's default.
function Pick-ModelFolder([string]$current, [string]$mode) {
  $default = Join-Path $HOME ".ollama\models"
  $inUse = ""
  if ($mode -eq "native") { $inUse = "$(Get-OllamaInUse "OLLAMA_MODELS")".TrimEnd("\") }
  Say "Searching this PC for models Ollama already downloaded..."
  $list = @()
  $candidates = @($current) + @(Find-ModelStores)
  if ($mode -eq "native") { $candidates = @($default, $inUse) + $candidates }
  foreach ($d in $candidates) {
    if (-not $d) { continue }
    $d = $d.TrimEnd("\")
    if ($list -notcontains $d) { $list += $d }
  }
  for ($i = 0; $i -lt $list.Count; $i++) {
    $d = $list[$i]
    $note = ""
    if ($d -eq $default) { $note = "  (Ollama's default)" }
    if ($d -eq $inUse) { $note = "  (Ollama uses this now)" }
    Write-Host ("   {0}) {1}{2}" -f ($i + 1), $d, $note)
    $names = @(Get-StoreModels $d)
    if ($names.Count) {
      $shown = ($names | Select-Object -First 4) -join ", "
      if ($names.Count -gt 4) { $shown = "$shown, ..." }
      Say "      $($names.Count) models, $(Get-FolderGb $d) GB: $shown"
    } else { Say "      no models yet" }
  }
  $free = @()
  foreach ($drive in [IO.DriveInfo]::GetDrives()) {
    if ($drive.DriveType -eq "Fixed" -and $drive.IsReady) {
      $free += "{0} {1:N0} GB" -f $drive.Name.TrimEnd("\"), ($drive.AvailableFreeSpace / 1GB)
    }
  }
  Say "Free space: $($free -join ', ')"
  Say ""
  Say "Models take 2-65 GB each, so pick a drive with room. Picking a folder"
  Say "that already has models means those won't be downloaded again."
  if ($mode -eq "container") {
    Say "Enter a number or a folder path, or press Enter with nothing to keep"
    Say "models inside Docker."
  } else {
    Say "Enter a number or a folder path (created if missing)."
  }
  $def = $current
  if (-not $def -and $mode -eq "native") { $def = $inUse }
  if (-not $def -and $mode -eq "native") { $def = $default }
  while ($true) {
    $a = (Ask "Model folder" $def).Trim().Trim('"').TrimEnd("\")
    if ($a -match "^\d+$" -and [int]$a -ge 1 -and [int]$a -le $list.Count) { $a = $list[[int]$a - 1] }
    if (-not $a -and $mode -eq "container") { return "" }
    if ($a -match "^[A-Za-z]:\\") { break }
    Warn "Enter a number from the list or a full path like D:\Ollama Models."
  }
  if ($a -eq $default) { return "" }
  return $a
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
  Say "The first one becomes the default chat model."
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

# Largest power-of-two context whose cache fits in $left GB. Calibrated on
# qwen3:30b (about 8000 tokens per GB of f16 cache); models that need more
# are caught by Check-GpuFit after setup.
function Get-ContextSuggestion([double]$left, [string]$kv) {
  $factor = 1.0
  if ($kv -eq "q8_0") { $factor = 0.53 } elseif ($kv -eq "q4_0") { $factor = 0.28 }
  $tokens = $left * 8000 / $factor
  $ctx = 2048
  while ($ctx * 2 -le $tokens -and $ctx -lt 131072) { $ctx *= 2 }
  return $ctx
}

# Suggests GPU memory settings, leaving headroom for context and other apps.
# With web search on, it favours a 4-bit cache: search results fill the
# context, so twice the context matters more than exact recall.
function Configure-Memory([string]$models, [bool]$search) {
  $budget = (Get-MemoryBudget)[0]
  $largest = 0; $largestTag = ""
  $catalog = Get-Catalog
  foreach ($m in ($models -split "\s+" | Where-Object { $_ })) {
    foreach ($c in $catalog) {
      if ($c[0] -eq $m -and $c[1] -gt $largest) { $largest = $c[1]; $largestTag = $m }
    }
  }
  $left = [math]::Round($budget * 0.9 - $largest, 1)
  Say "Besides the model itself, Ollama needs memory for the conversation it"
  Say "keeps in context. Leave headroom: if it all doesn't fit in GPU memory,"
  Say "part of the model runs on the CPU and replies get much slower."
  Say "  Memory for models: $budget GB, keeping 10% free for Windows and other apps"
  if ($largestTag) { Say "  Largest model:     $largestTag, about $largest GB" }
  Say "  Left for context:  about $left GB"
  $now = Get-OllamaInUse "OLLAMA_CONTEXT_LENGTH"
  if ($now) { Say "  Ollama uses now:   $now tokens" }
  Say ""
  Say "Flash attention shrinks the context memory and is usually faster. With"
  Say "it on, the context can be stored at lower precision:"
  Say "  q8_0  about half the memory, little quality loss"
  Say "  q4_0  about a quarter; recalls details from long chats a bit less exactly"
  if ($search) { Say "Recommended with web search: q4_0, so search results get twice the room." }
  $faDef = "y"
  if ((EnvGet "OLLAMA_FLASH_ATTENTION") -eq "0") { $faDef = "n" }
  if (YesNo "Use flash attention?" $faDef) {
    $fa = "1"
    $kvDef = EnvGet "OLLAMA_KV_CACHE_TYPE"
    if (-not $kvDef) { if ($search) { $kvDef = "q4_0" } else { $kvDef = "q8_0" } }
    do { $kv = Ask "Context precision (q8_0 or q4_0)" $kvDef } until (@("q8_0", "q4_0") -contains $kv)
  } else { $fa = "0"; $kv = "" }
  $suggest = Get-ContextSuggestion $left $kv
  Say ""
  Say "About $suggest tokens of context fit in the room left. Lower is safer;"
  Say "0 leaves it to Ollama. After setup, setup checks that the model fits."
  if ($search) {
    Say "Web search needs 16384 or more. With 65536 or more, it sends whole pages"
    Say "(4 results) instead of excerpts, which gives better answers."
  }
  $def = EnvGet "OLLAMA_CONTEXT_LENGTH"
  if (-not $def) { $def = "$suggest" }
  do { $ctx = Ask "Context length in tokens" $def } until ($ctx -match "^\d+$")
  if ($ctx -eq "0") { $ctx = "" }
  return @($ctx, $fa, $kv)
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
  if ($cur -eq "external") { $cur = "auto" }
  if ((EnvGet "ENABLE_WEB_SEARCH") -ne "true" -or -not $cur) { $cur = "off" }
  Say "Web search lets models look things up online; it's on by default. The"
  Say "search queries, not your whole chat, go to the provider you pick."
  Say "  off         no web access (most private)"
  Say "  duckduckgo  no account or key needed; can be rate-limited if used heavily"
  Say "  brave       needs a Brave Search API key; reliable, independent index"
  Say "  tavily      needs a Tavily API key; built for AI, returns cleaner results"
  Say "  serpapi     needs a SerpAPI key; Google results, short snippets"
  Say "  auto        Tavily, then SerpAPI, then DuckDuckGo, switching automatically"
  Say "              when one fails or runs out of credits (add the keys you have)"
  Say "Not sure? Keep duckduckgo; pick off for no web access."
  do { $engine = Ask "Web search" $cur } until (@("off", "duckduckgo", "brave", "tavily", "serpapi", "auto") -contains $engine)
  $brave = EnvGet "BRAVE_SEARCH_API_KEY"
  $tavily = EnvGet "TAVILY_API_KEY"
  $serpapi = EnvGet "SERPAPI_API_KEY"
  if ($engine -eq "brave" -and (-not $brave -or -not (YesNo "Keep the saved Brave key?" "y"))) {
    Say "Get a key: sign up at https://api-dashboard.search.brave.com, choose a"
    Say "plan (see brave.com/search/api for current pricing), then open"
    Say "'API Keys' and copy the key."
    $brave = Ask-Secret "Paste the Brave Search API key (hidden)"
  }
  if ($engine -eq "auto") {
    Say "Add the keys you have; press Enter to skip one. Without any key, auto"
    Say "uses DuckDuckGo."
    if (-not $tavily -or -not (YesNo "Keep the saved Tavily key?" "y")) { $tavily = Ask-Secret "Tavily API key (hidden, Enter to skip)" }
    if (-not $serpapi -or -not (YesNo "Keep the saved SerpAPI key?" "y")) { $serpapi = Ask-Secret "SerpAPI key (hidden, Enter to skip)" }
  }
  if ($engine -eq "tavily" -and (-not $tavily -or -not (YesNo "Keep the saved Tavily key?" "y"))) {
    Say "Get a key: sign up at https://app.tavily.com; your key (starts with"
    Say "tvly-) is on the overview page. Check their site for current free limits."
    $tavily = Ask-Secret "Paste the Tavily API key (hidden)"
  }
  if ($engine -eq "serpapi" -and (-not $serpapi -or -not (YesNo "Keep the saved SerpAPI key?" "y"))) {
    Say "Get a key: sign up at https://serpapi.com, then copy the whole key from"
    Say "https://serpapi.com/manage-api-key. Check their site for current free limits."
    $serpapi = Ask-Secret "Paste the SerpAPI key (hidden)"
  }
  return @($engine, $brave, $tavily, $serpapi)
}

function Configure {
  Write-Host ""
  Write-Host "Open WebUI + Ollama setup (Windows)" -ForegroundColor Cyan
  Say "Answer each question, or press Enter to keep the value in [brackets]."
  Say "Nothing is changed until you confirm at the end."

  Step "1/7  Ollama"
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

  Step "2/7  Models"
  $modelsDir = Pick-ModelFolder (EnvGet "OLLAMA_MODELS") $mode
  Say ""
  $models = Pick-Models (EnvGet "OLLAMA_PULL_MODELS")

  Step "3/7  Local port"
  Say "Open WebUI listens on this machine only (127.0.0.1). Keep 3000 unless"
  Say "another app already uses it; then pick any free number like 3001 or 8080."
  do { $port = Ask "Port" (EnvGet "OPEN_WEBUI_PORT") } until ($port -match "^\d+$")

  Step "4/7  Remote access (Tailscale)"
  Say "Tailscale lets your phone and laptop reach this machine from anywhere at"
  Say "https://<pc-name>.<tailnet>.ts.net, without exposing anything to your"
  Say "Wi-Fi network or the internet. It's free for personal use: create an"
  Say "account at https://login.tailscale.com/start and install the app on each"
  Say "device. Say no only if you'll use Open WebUI on this machine alone."
  $tsDef = "y"
  if ((EnvGet "TAILSCALE_SERVE") -eq "false") { $tsDef = "n" }
  $ts = "false"
  if (YesNo "Set up Tailscale remote access?" $tsDef) { $ts = "true" }

  Step "5/7  Optional extras"
  $cloud = Configure-Cloud
  $search = Configure-Search

  Step "6/7  GPU memory"
  $searchOn = ($search[0] -ne "off")
  $memory = Configure-Memory $models $searchOn
  # Whole pages give better answers but need room: 4 pages plus the chat.
  $bypass = "false"; $results = "5"
  if ($searchOn -and $memory[0] -and [int]$memory[0] -ge 65536) { $bypass = "true"; $results = "4" }

  Step "7/7  Where settings live"
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
  $dirText = $modelsDir
  if (-not $dirText) { $dirText = "Ollama's default"; if ($mode -eq "container") { $dirText = "inside Docker" } }
  Say "Model folder:  $dirText"
  $ctxText = $memory[0]; if (-not $ctxText) { $ctxText = "Ollama default" }
  if ($memory[1] -eq "1") { $ctxText = "$ctxText tokens, flash attention, $($memory[2]) cache" }
  Say "Context:       $ctxText"
  Say "Local URL:     http://localhost:$port"
  Say "Tailscale:     $ts"
  Say "Cloud APIs:    $cloudText"
  $searchText = $search[0]
  if ($searchOn) { if ($bypass -eq "true") { $searchText = "$searchText, whole pages, $results results" } else { $searchText = "$searchText, excerpts, $results results" } }
  Say "Web search:    $searchText"
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
  EnvSet "DEFAULT_MODELS" (($models -split "\s+") | Where-Object { $_ } | Select-Object -First 1)
  EnvSet "OLLAMA_MODELS" $modelsDir
  EnvSet "OLLAMA_CONTEXT_LENGTH" $memory[0]
  EnvSet "OLLAMA_FLASH_ATTENTION" $memory[1]
  EnvSet "OLLAMA_KV_CACHE_TYPE" $memory[2]
  EnvSet "OPEN_WEBUI_PORT" $port
  EnvSet "TAILSCALE_SERVE" $ts
  EnvSet "OPENAI_API_BASE_URLS" $cloud[0]
  EnvSet "OPENAI_API_KEYS" $cloud[1]
  if ($cloud[0]) { EnvSet "ENABLE_OPENAI_API" "true" } else { EnvSet "ENABLE_OPENAI_API" "false" }
  if ($search[0] -eq "off") {
    EnvSet "ENABLE_WEB_SEARCH" "false"; EnvSet "WEB_SEARCH_ENGINE" ""
  } else {
    $engineValue = $search[0]; if ($engineValue -eq "auto") { $engineValue = "external" }
    EnvSet "ENABLE_WEB_SEARCH" "true"; EnvSet "WEB_SEARCH_ENGINE" $engineValue
  }
  EnvSet "BRAVE_SEARCH_API_KEY" $search[1]
  EnvSet "TAVILY_API_KEY" $search[2]
  EnvSet "SERPAPI_API_KEY" $search[3]
  EnvSet "BYPASS_WEB_SEARCH_EMBEDDING_AND_RETRIEVAL" $bypass
  EnvSet "WEB_SEARCH_RESULT_COUNT" $results
  EnvSet "ENABLE_PERSISTENT_CONFIG" $persist
  Ok "Saved .env"
}

# ------------------------------------------------------------------ apply

function Check-Docker {
  if (-not (Have "docker")) { Offer-Install "Docker Desktop" "Docker.DockerDesktop" }
  if (-not (Quiet "docker" @("compose", "version"))) { Fail "Docker Compose v2 is missing (the 'docker compose' command)." }
  if (-not (Quiet "docker" @("info"))) {
    $app = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"
    if (Test-Path -LiteralPath $app) {
      Say "Starting Docker Desktop (this can take a minute or two)..."
      Say "First time? Accept its license in the Docker Desktop window."
      Start-Process -FilePath $app
      for ($i = 0; $i -lt 60 -and -not (Quiet "docker" @("info")); $i++) { Start-Sleep -Seconds 3 }
    }
    if (-not (Quiet "docker" @("info"))) {
      Fail ("Docker isn't running. Start Docker Desktop, wait until it says 'Engine running', then run setup.cmd again. " +
        "Just installed it? Sign out of Windows and back in first.")
    }
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

# The Ollama app reads its settings from Windows user environment variables,
# not .env. Copy them over (empty in .env removes them) and restart Ollama
# if one changed.
function Sync-OllamaEnv {
  if ((EnvGet "OLLAMA_KV_CACHE_TYPE") -and (EnvGet "OLLAMA_FLASH_ATTENTION") -ne "1") {
    Warn "OLLAMA_KV_CACHE_TYPE only works with OLLAMA_FLASH_ATTENTION=1."
  }
  $changed = $false
  foreach ($k in $OllamaTuning) {
    $want = EnvGet $k
    if (-not $want) { $want = $null }
    if ($want -ne [Environment]::GetEnvironmentVariable($k, "User")) {
      [Environment]::SetEnvironmentVariable($k, $want, "User")
      $changed = $true
    }
    # Ollama started by this script inherits this process's environment.
    [Environment]::SetEnvironmentVariable($k, $want, "Process")
  }
  if (-not $changed) { return }
  Ok "Ollama settings saved to your Windows user environment variables"
  if (Ollama-Up) {
    Say "Restarting Ollama to apply them..."
    # Model runners too: left running, they keep holding GPU memory.
    Get-Process -Name "ollama app", "ollama", "llama-server", "ollama_llama_server" -ErrorAction SilentlyContinue |
      Stop-Process -Force -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 15 -and (Ollama-Up); $i++) { Start-Sleep -Seconds 1 }
    if (Ollama-Up) { Warn "Couldn't stop Ollama. Quit it from the system tray and start it again to apply them." }
  }
}

function Invoke-Ollama([string[]]$argv) {
  if ((EnvGet "OLLAMA_MODE") -eq "container") { return (Run "docker" (@("exec", "ollama", "ollama") + $argv)) }
  return (Run (Ollama-Exe) $argv)
}

# Python run inside the Open WebUI container, which reaches Ollama in both
# modes: loads a model, then prints its size, size in GPU memory and context.
$FitPy = "import json,os,sys,urllib.request as u; b=os.environ['OLLAMA_BASE_URL']; m=sys.argv[1]; u.urlopen(u.Request(b+'/api/generate',json.dumps({'model':m,'prompt':''}).encode()),timeout=600).read(); [print(x['size'],x['size_vram'],x.get('context_length',0)) for x in json.load(u.urlopen(b+'/api/ps',timeout=10))['models'] if x['name'] in (m,m+':latest')]"

# Loads the largest selected model and warns if part of it runs on the CPU.
function Check-GpuFit {
  $models = @((EnvGet "OLLAMA_PULL_MODELS") -split "\s+" | Where-Object { $_ })
  if ($models.Count -eq 0) { return }
  $pick = $models[0]; $size = 0
  foreach ($c in Get-Catalog) {
    if ($models -contains $c[0] -and $c[1] -gt $size) { $pick = $c[0]; $size = $c[1] }
  }
  Say "Loading $pick to check it fits in GPU memory..."
  $ErrorActionPreference = "Continue"
  $out = & docker exec open-webui python3 -c $FitPy $pick 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $out) { Warn "Couldn't load $pick to check its fit."; return }
  $f = "$out".Trim() -split "\s+"
  $total = [double]$f[0]; $vram = [double]$f[1]
  if ($vram -eq 0) { return }
  $gb = [math]::Round($total / 1e9, 1)
  if ($vram -ge $total) { Ok "$pick fits in GPU memory ($gb GB with $($f[2]) tokens of context)"; return }
  Warn "$pick doesn't fit: $([math]::Round(($total - $vram) / 1e9, 1)) of $gb GB runs on the CPU, so replies are slow."
  Say "Lower the context length, use the q4_0 cache, or pick a smaller model: setup.cmd configure"
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
  Step "Create your Open WebUI admin account"
  Say "Open WebUI (the chat website) has no accounts yet. This is a new login"
  Say "stored only on this computer, not your Tailscale, Docker or Ollama account."
  Say "The first account becomes the admin and sign-ups close after that; you"
  Say "add family members later. Create it now, before remote access is on."
  Say "The email is only a login name (Open WebUI never sends mail). The admin"
  Say "password guards everyone's chats, so use a strong one and save it in a"
  Say "password manager. There's no 'forgot password' link."
  Say "Opening http://localhost:$port"
  Start-Process "http://localhost:$port"
  while ($true) {
    $r = Read-Host "  Press Enter when the Open WebUI admin account exists (or type 'skip')"
    if ($r -eq "skip") { Warn "Skipped. Create the Open WebUI admin account before sharing access."; return }
    if (-not (Test-Onboarding $port)) { break }
    Warn "No account yet."
  }
  Ok "Open WebUI admin account exists"
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

# Search results go into the model's context. Too small a context and Ollama
# drops them, so the model answers from its outdated training data.
function Check-SearchContext {
  if ((EnvGet "ENABLE_WEB_SEARCH") -ne "true") { return }
  $raw = EnvGet "OLLAMA_CONTEXT_LENGTH"
  $ctx = 0
  if ($raw -match '^[0-9]+$') { $ctx = [int64]$raw }
  if ($ctx -ge 16384) { return }
  Warn "Web search works poorly with less than 16384 tokens of context (.env has '$raw');"
  Warn "search results get cut off. Raise OLLAMA_CONTEXT_LENGTH if the model fits: setup.cmd configure"
}

function Apply {
  if (-not (Test-Path -LiteralPath $EnvFile)) { Configure }
  $mode = EnvGet "OLLAMA_MODE"
  $hw = EnvGet "COMPOSE_PROFILES"
  $port = EnvGet "OPEN_WEBUI_PORT"
  if (-not (EnvGet "WEBUI_SECRET_KEY")) { EnvSet "WEBUI_SECRET_KEY" (New-Secret) }

  Step "Checking prerequisites"
  Check-Docker
  if ($mode -eq "native") { Sync-OllamaEnv; Check-NativeOllama; Check-OllamaSettings }
  Check-SearchContext

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
  Check-GpuFit

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
