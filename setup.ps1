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
# Windows PowerShell 5.1 may default to TLS 1.0, which current APIs refuse.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
Set-Location -LiteralPath $PSScriptRoot

$EnvFile = Join-Path $PSScriptRoot ".env"
$ExampleFile = Join-Path $PSScriptRoot ".env.example"
$OllamaServices = @("ollama-cpu", "ollama-nvidia", "ollama-amd")
$OllamaTuning = @("OLLAMA_MODELS", "OLLAMA_CONTEXT_LENGTH", "OLLAMA_FLASH_ATTENTION", "OLLAMA_KV_CACHE_TYPE", "OLLAMA_KEEP_ALIVE")
$script:TsUrl = ""

# ------------------------------------------------------------------ helpers

# Terminal UI. With a console, questions are arrow-key menus, checklists and
# toggles; with input or output redirected they fall back to plain prompts.
# Check marks and arrows only in Windows Terminal: the classic console font
# lacks them.
$script:Ui = $false
try { $script:Ui = (-not [Console]::IsInputRedirected) -and (-not [Console]::IsOutputRedirected) } catch { }
try { if ([Console]::IsOutputRedirected) { [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false } } catch { }
if ($env:WT_SESSION) { $script:Check = [string][char]0x2713; $script:Arrow = [string][char]0x276F }
else { $script:Check = "+"; $script:Arrow = ">" }
$script:Rule = New-Object String ([char]0x2500), 60
$script:Dot = [string][char]0x00B7
$script:KeyInfo = ""

function Say([string]$m)  { Write-Host "  $m" }
function Note([string]$m) { Write-Host "  $m" -ForegroundColor DarkGray }
function Ok([string]$m)   { Write-Host "  $($script:Check) " -ForegroundColor Green -NoNewline; Write-Host $m }
function Warn([string]$m) { Write-Host "  ! " -ForegroundColor Yellow -NoNewline; Write-Host $m }
function Fail([string]$m) { Write-Host ""; Write-Host "  Error: $m" -ForegroundColor Red; exit 1 }

# Section header, with space around it.
function Step([string]$m) {
  Write-Host ""; Write-Host ""
  Write-Host "  $m" -ForegroundColor Cyan
  Write-Host "  $($script:Rule)" -ForegroundColor DarkGray
  Write-Host ""
}

function Ask([string]$q, [string]$def) {
  Write-Host "  ? " -ForegroundColor Cyan -NoNewline
  $p = $q
  if ($def) { $p = "$q ($def)" }
  $r = Read-Host $p
  if ([string]::IsNullOrWhiteSpace($r)) { return $def }
  return $r.Trim()
}

function Ask-Secret([string]$q) {
  Write-Host "  ? " -ForegroundColor Cyan -NoNewline
  $s = Read-Host $q -AsSecureString
  $p = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($p) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p) }
}

function Get-Width {
  $w = 80
  try { $w = [Console]::BufferWidth - 1 } catch { }
  return $w
}

function Show-Cursor([bool]$on) { try { [Console]::CursorVisible = $on } catch { } }

# One menu row: label, then a grey hint cut to fit the window.
function Write-MenuRow([bool]$sel, [string]$mark, [string]$label, [string]$hint) {
  if ($label.Length -gt 34) { $label = $label.Substring(0, 33) + "~" }
  $lead = "    "
  if ($sel) { $lead = "  $($script:Arrow) " }
  $left = $lead + $mark + $label.PadRight(34) + " "
  $room = (Get-Width) - $left.Length
  if ($room -lt 0) { $room = 0 }
  if ($hint.Length -gt $room) { if ($room -gt 3) { $hint = $hint.Substring(0, $room - 3) + "..." } else { $hint = "" } }
  if ($sel) { Write-Host $left -ForegroundColor Cyan -NoNewline } else { Write-Host $left -NoNewline }
  Write-Host $hint.PadRight($room) -ForegroundColor DarkGray
}

# Replaces a finished menu (question line plus $rows rows) with its answer.
function Close-Menu([string]$q, [string]$answer, [int]$top, [int]$rows) {
  [Console]::SetCursorPosition(0, $top)
  for ($i = 0; $i -le $rows; $i++) { Write-Host (" " * (Get-Width)) }
  [Console]::SetCursorPosition(0, $top)
  Write-Host "  $($script:Check) " -ForegroundColor Green -NoNewline
  Write-Host "$q " -NoNewline
  Write-Host $answer -ForegroundColor White
  Show-Cursor $true
}

# YesNo "Question" y|n -> $true/$false. Left/right (or y/n), Enter confirms.
function YesNo([string]$q, [string]$def) {
  if (-not $script:Ui) {
    $hint = "y/N"
    if ($def -eq "y") { $hint = "Y/n" }
    while ($true) {
      $r = Read-Host "  ? $q [$hint]"
      if ([string]::IsNullOrWhiteSpace($r)) { $r = $def }
      if ($r -match "^[Yy]") { return $true }
      if ($r -match "^[Nn]") { return $false }
    }
  }
  $sel = ($def -eq "y")
  Show-Cursor $false
  $row = [Console]::CursorTop
  while ($true) {
    [Console]::SetCursorPosition(0, $row)
    Write-Host "  ? " -ForegroundColor Cyan -NoNewline
    Write-Host "$q   " -NoNewline
    if ($sel) {
      Write-Host "$($script:Arrow) Yes" -ForegroundColor Cyan -NoNewline
      Write-Host "     No   " -ForegroundColor DarkGray -NoNewline
    } else {
      Write-Host "  Yes   " -ForegroundColor DarkGray -NoNewline
      Write-Host "$($script:Arrow) No   " -ForegroundColor Cyan -NoNewline
    }
    $k = [Console]::ReadKey($true)
    if ($k.Key -eq "Enter") { break }
    if ("$($k.KeyChar)" -eq "y") { $sel = $true; break }
    if ("$($k.KeyChar)" -eq "n") { $sel = $false; break }
    if (@("LeftArrow", "RightArrow", "Tab") -contains "$($k.Key)") { $sel = -not $sel }
  }
  $answer = "No"
  if ($sel) { $answer = "Yes" }
  [Console]::SetCursorPosition(0, $row)
  Write-Host (" " * (Get-Width))
  Close-Menu $q $answer $row 0
  return $sel
}

function Split-Items([string[]]$items) {
  $vals = @(); $labels = @(); $hints = @()
  foreach ($it in $items) {
    $p = $it.Split([char]'|', 3)
    $vals += $p[0]; $labels += $p[1]; $hints += $p[2]
  }
  return @(, $vals) + @(, $labels) + @(, $hints)
}

# Choose "Question" DEFAULT @("value|label|hint", ...) -> the chosen value
function Choose([string]$q, [string]$def, [string[]]$items) {
  $parts = Split-Items $items
  $vals = $parts[0]; $labels = $parts[1]; $hints = $parts[2]
  $n = $vals.Count
  $sel = 0
  for ($i = 0; $i -lt $n; $i++) { if ($vals[$i] -eq $def) { $sel = $i } }
  if (-not $script:Ui) {
    Write-Host "  ? $q"
    for ($i = 0; $i -lt $n; $i++) { Write-Host ("     {0}) {1,-30} {2}" -f ($i + 1), $labels[$i], $hints[$i]) }
    while ($true) {
      $r = Read-Host ("     Choice [{0}]" -f ($sel + 1))
      if ([string]::IsNullOrWhiteSpace($r)) { return $vals[$sel] }
      if ($r -match '^\d+$' -and [int]$r -ge 1 -and [int]$r -le $n) { return $vals[[int]$r - 1] }
    }
  }
  Write-Host "  ? " -ForegroundColor Cyan -NoNewline
  Write-Host "$q  " -NoNewline
  Write-Host "Up/Down to move, Enter to choose" -ForegroundColor DarkGray
  Show-Cursor $false
  for ($i = 0; $i -lt $n; $i++) { Write-MenuRow ($i -eq $sel) "" $labels[$i] $hints[$i] }
  $top = [Console]::CursorTop - $n
  while ($true) {
    $k = [Console]::ReadKey($true)
    $c = "$($k.KeyChar)"
    if ($k.Key -eq "Enter") { break }
    if ($k.Key -eq "UpArrow" -or $c -eq "k") { $sel = ($sel + $n - 1) % $n }
    elseif ($k.Key -eq "DownArrow" -or $k.Key -eq "Tab" -or $c -eq "j") { $sel = ($sel + 1) % $n }
    elseif ($c -match '^[1-9]$' -and [int]$c -le $n) { $sel = [int]$c - 1 }
    [Console]::SetCursorPosition(0, $top)
    for ($i = 0; $i -lt $n; $i++) { Write-MenuRow ($i -eq $sel) "" $labels[$i] $hints[$i] }
  }
  Close-Menu $q $labels[$sel] ($top - 1) $n
  return $vals[$sel]
}

# Checklist "Question" "preselected values" @("value|label|hint", ...)
#   -> ticked values, space-separated, in list order
function Checklist([string]$q, [string]$pre, [string[]]$items) {
  $parts = Split-Items $items
  $vals = $parts[0]; $labels = $parts[1]; $hints = $parts[2]
  $n = $vals.Count
  $preList = @($pre -split "\s+")
  $on = @(); foreach ($v in $vals) { $on += ($preList -contains $v) }
  if (-not $script:Ui) {
    while ($true) {
      Write-Host "  ? $q"
      for ($i = 0; $i -lt $n; $i++) {
        $x = " "; if ($on[$i]) { $x = "x" }
        Write-Host ("     {0,2}) [{1}] {2,-28} {3}" -f ($i + 1), $x, $labels[$i], $hints[$i])
      }
      $r = Read-Host "     Numbers to tick or untick, Enter when done"
      if ([string]::IsNullOrWhiteSpace($r)) { break }
      foreach ($t in ($r -split "\s+")) {
        if ($t -match '^\d+$' -and [int]$t -ge 1 -and [int]$t -le $n) { $on[[int]$t - 1] = -not $on[[int]$t - 1] }
      }
    }
  } else {
    Write-Host "  ? " -ForegroundColor Cyan -NoNewline
    Write-Host "$q  " -NoNewline
    Write-Host "Up/Down to move, Space to tick, Enter when done" -ForegroundColor DarkGray
    Show-Cursor $false
    $sel = 0
    for ($i = 0; $i -lt $n; $i++) {
      $mark = "[ ] "; if ($on[$i]) { $mark = "[x] " }
      Write-MenuRow ($i -eq $sel) $mark $labels[$i] $hints[$i]
    }
    $top = [Console]::CursorTop - $n
    while ($true) {
      $k = [Console]::ReadKey($true)
      $c = "$($k.KeyChar)"
      if ($k.Key -eq "Enter") { break }
      if ($k.Key -eq "UpArrow" -or $c -eq "k") { $sel = ($sel + $n - 1) % $n }
      elseif ($k.Key -eq "DownArrow" -or $k.Key -eq "Tab" -or $c -eq "j") { $sel = ($sel + 1) % $n }
      elseif ($k.Key -eq "Spacebar" -or $c -eq "x") { $on[$sel] = -not $on[$sel] }
      [Console]::SetCursorPosition(0, $top)
      for ($i = 0; $i -lt $n; $i++) {
        $mark = "[ ] "; if ($on[$i]) { $mark = "[x] " }
        Write-MenuRow ($i -eq $sel) $mark $labels[$i] $hints[$i]
      }
    }
  }
  $out = @(); $names = @()
  for ($i = 0; $i -lt $n; $i++) { if ($on[$i]) { $out += $vals[$i]; $names += $labels[$i] } }
  if ($script:Ui) {
    $shown = "none"; if ($names.Count) { $shown = $names -join ", " }
    Close-Menu $q $shown ($top - 1) $n
  }
  return ($out -join " ")
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
  Note "Looking for models Ollama already downloaded on this PC..."
  $list = @()
  $candidates = @($current) + @(Find-ModelStores)
  if ($mode -eq "native") { $candidates = @($default, $inUse) + $candidates }
  foreach ($d in $candidates) {
    if (-not $d) { continue }
    $d = $d.TrimEnd("\")
    if ($list -notcontains $d) { $list += $d }
  }
  $items = @()
  if ($mode -eq "container") { $items += "|Inside Docker|Docker's own storage (default)" }
  foreach ($d in $list) {
    $names = @(Get-StoreModels $d)
    $hint = "empty"
    if ($names.Count) { $hint = "$($names.Count) models, $(Get-FolderGb $d) GB: " + (($names | Select-Object -First 3) -join ", ") }
    if ($d -eq $inUse) { $hint = "Ollama uses this now $($script:Dot) $hint" }
    elseif ($d -eq $default) { $hint = "Ollama's default $($script:Dot) $hint" }
    $items += "$d|$d|$hint"
  }
  $items += "other|Another folder...|type a path; created if missing"
  $free = @()
  foreach ($drive in [IO.DriveInfo]::GetDrives()) {
    if ($drive.DriveType -eq "Fixed" -and $drive.IsReady) {
      $free += "{0} {1:N0} GB" -f $drive.Name.TrimEnd("\"), ($drive.AvailableFreeSpace / 1GB)
    }
  }
  Say "Models take 2-65 GB each. Pick a drive with room, or a folder that"
  Say "already holds models so they aren't downloaded again."
  Note "Free space: $($free -join ', ')"
  Write-Host ""
  $def = $current
  if (-not $def -and $mode -eq "native") { $def = $inUse }
  if (-not $def -and $mode -eq "native") { $def = $default }
  $d = Choose "Where should models live?" $def $items
  if ($d -eq "other") {
    while ($true) {
      $d = Ask "Folder path" ""
      $d = "$d".Trim().Trim('"').TrimEnd("\")
      if ($d -match '^[A-Za-z]:\\') { break }
      Warn "Enter a full path, like D:\Ollama Models."
    }
  }
  if ($d -eq $default) { return "" }
  return $d
}

# Asks which models to download. Returns them space-separated, default chat
# model first.
function Pick-Models([string]$current) {
  $budget = Get-MemoryBudget
  Say "Detected: $($budget[1])."
  Say "Models marked 'fits' run fully on this PC's GPU and are fast; bigger"
  Say "ones still work, just slowly. Each takes its size in disk space."
  Write-Host ""
  $cur = @($current -split "\s+" | Where-Object { $_ })
  $catalog = Get-Catalog
  $items = @(); $pre = @(); $best = ""; $bestSize = 0
  foreach ($m in $catalog) {
    $fit = "too big"
    if ($m[1] * 1.2 -le $budget[0]) {
      $fit = "fits"
      if ($m[1] -gt $bestSize) { $best = $m[0]; $bestSize = $m[1] }
    }
    $items += "$($m[0])|$($m[0])|$($m[1]) GB $($script:Dot) $fit $($script:Dot) $($m[2])"
    if ($cur -contains $m[0]) { $pre += $m[0] }
  }
  $known = @($catalog | ForEach-Object { $_[0] })
  $extra = @($cur | Where-Object { $known -notcontains $_ })
  if ($pre.Count -eq 0 -and $extra.Count -eq 0 -and $best) { $pre = @($best) }
  $picked = Checklist "Models to download" ($pre -join " ") $items
  Write-Host ""
  Note "Any other model from ollama.com/library? Type its tag (e.g. mistral-small3.2),"
  Note "space-separated, or press Enter to skip."
  $more = Ask "Other models" ($extra -join " ")
  $all = @()
  foreach ($m in ("$picked $more" -split "\s+")) { if ($m -and $all -notcontains $m) { $all += $m } }
  if ($all.Count -eq 0) { Warn "No models selected; you can add some later with setup.cmd configure."; return "" }
  if ($all.Count -gt 1) {
    $default = EnvGet "DEFAULT_MODELS"
    if ($all -notcontains $default) { $default = $all[0] }
    $opts = @()
    foreach ($m in $all) {
      $hint = ""
      foreach ($c in $catalog) { if ($c[0] -eq $m) { $hint = $c[2] } }
      $opts += "$m|$m|$hint"
    }
    Write-Host ""
    $default = Choose "Which model should new chats start with?" $default $opts
    $all = @($default) + @($all | Where-Object { $_ -ne $default })
  }
  return ($all -join " ")
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
  Say "Besides the model, Ollama keeps the conversation (its ""context"") in GPU"
  Say "memory. If both don't fit, part of the model runs on the CPU and replies"
  Say "get much slower, so setup leaves headroom."
  Write-Host ""
  Note "Memory for models   $budget GB (10% kept free for Windows and other apps)"
  if ($largestTag) { Note "Largest model       $largestTag, about $largest GB" }
  Note "Left for context    about $left GB"
  $now = Get-OllamaInUse "OLLAMA_CONTEXT_LENGTH"
  if ($now) { Note "Ollama uses now     $now tokens" }
  Write-Host ""
  $faDef = "y"
  if ((EnvGet "OLLAMA_FLASH_ATTENTION") -eq "0") { $faDef = "n" }
  if (YesNo "Use flash attention? (faster, less memory; recommended)" $faDef) {
    $fa = "1"
    $kvDef = EnvGet "OLLAMA_KV_CACHE_TYPE"
    if (-not $kvDef) { if ($search) { $kvDef = "q4_0" } else { $kvDef = "q8_0" } }
    $r4 = ""; $r8 = ""
    if ($search) { $r4 = " (recommended)" } else { $r8 = " (recommended)" }
    $kv = Choose "Context precision" $kvDef @(
      "q4_0|4-bit$r4|a quarter of the memory: twice the room for search results",
      "q8_0|8-bit$r8|half the memory; recalls long chats a bit more exactly")
  } else { $fa = "0"; $kv = "" }
  $suggest = Get-ContextSuggestion $left $kv
  $cur = EnvGet "OLLAMA_CONTEXT_LENGTH"
  $items = @("$suggest|$suggest tokens (recommended)|the most that fits with headroom")
  foreach ($c in @([int]($suggest / 2), [int]($suggest / 4))) {
    if ($c -ge 4096) { $items += "$c|$c tokens|safer if other apps use the GPU" }
  }
  if ($cur -and -not ($items | Where-Object { $_.StartsWith("$cur|") })) { $items += "$cur|$cur tokens (current)|your current setting" }
  $items += "0|Let Ollama decide|its default for this GPU"
  $items += "other|Another size...|type a number of tokens"
  Write-Host ""
  if ($search) { Note "Web search needs 16384 or more; with 65536 or more it reads whole pages." }
  $def = $cur
  if (-not $def) { $def = "$suggest" }
  $ctx = Choose "Context length" $def $items
  if ($ctx -eq "other") { do { $ctx = Ask "Context length in tokens" "$suggest" } until ($ctx -match '^\d+$') }
  if ($ctx -eq "0") { $ctx = "" }
  return @($ctx, $fa, $kv)
}

function Configure-Cloud {
  $urls = EnvGet "OPENAI_API_BASE_URLS"
  $keys = EnvGet "OPENAI_API_KEYS"
  Say "Cloud models (GPT, Claude, Gemini, ...) are smarter than any model this"
  Say "PC can run, but chats sent to them leave your machine and cost money per"
  Say "use. Local models stay private. You can add a cloud model later."
  Write-Host ""
  if ($urls) {
    if (YesNo "Keep your $(@($urls.Split(';')).Count) cloud connection(s)?" "y") { return @($urls, $keys) }
  }
  $u = @(); $k = @()
  if (-not (YesNo "Add a cloud model provider?" "n")) { return @("", "") }
  while ($true) {
    Write-Host ""
    $choice = Choose "Provider" "openrouter" @(
      "openrouter|OpenRouter|one key for Claude, GPT, Gemini and more",
      "openai|OpenAI|GPT models, directly from OpenAI",
      "other|Other|any OpenAI-compatible API (Groq, Together, ...)")
    $url = ""
    if ($choice -eq "openai") {
      $url = "https://api.openai.com/v1"
      Note "Key: https://platform.openai.com/api-keys > Create new secret key (starts with sk-)."
      Note "API use is billed separately from ChatGPT; add credit under Settings > Billing."
    } elseif ($choice -eq "openrouter") {
      $url = "https://openrouter.ai/api/v1"
      Note "Key: https://openrouter.ai/keys > Create Key (starts with sk-or-)."
      Note "Add credit at https://openrouter.ai/credits."
    } else {
      Note "Find the base URL in the provider's API docs (often ends in /v1)."
      $url = Ask "Base URL" ""
    }
    if (-not $url) { continue }
    $key = Ask-Secret "Paste the API key (hidden; saved only in .env)"
    if (-not $key) { Warn "No key entered; skipped."; continue }
    if ($key.Contains(";")) { Warn "Keys can't contain ';'. Skipped."; continue }
    $u += $url; $k += $key
    Ok "Added $url"
    if (-not (YesNo "Add another provider?" "n")) { break }
  }
  return @(($u -join ";"), ($k -join ";"))
}

# Checks a search key without using up a search. Returns 0 if it works
# ($script:KeyInfo says how much is left), 1 if rejected, 2 if unreachable.
function Check-SearchKey([string]$provider, [string]$key) {
  if ($key -notmatch '^[A-Za-z0-9_-]+$') { return 1 }
  try {
    if ($provider -eq "tavily") {
      $r = Invoke-RestMethod -Uri "https://api.tavily.com/usage" -Headers @{ Authorization = "Bearer $key" } -TimeoutSec 15
      $a = $r.account
      $script:KeyInfo = "$($a.current_plan) plan"
      if ($a.plan_limit) { $script:KeyInfo += ", $($a.plan_limit - $a.plan_usage) of $($a.plan_limit) searches left this month" }
    } else {
      $r = Invoke-RestMethod -Uri "https://serpapi.com/account.json?api_key=$key" -TimeoutSec 15
      $script:KeyInfo = "$($r.plan_name), $($r.total_searches_left) of $($r.searches_per_month) searches left this month"
    }
    return 0
  } catch {
    $code = 0
    try { $code = [int]$_.Exception.Response.StatusCode } catch { }
    if ($code -eq 401 -or $code -eq 403) { return 1 }
    return 2
  }
}

# Walks through getting a free key. Returns a working key, or "" if skipped.
function Search-Key([string]$provider, [string]$cur) {
  if ($provider -eq "tavily") {
    $name = "Tavily"; $signup = "https://app.tavily.com"; $free = "1,000 searches a month"
    $how = "Copy the API key from the overview page (starts with tvly-)."
  } else {
    $name = "SerpAPI"; $signup = "https://serpapi.com/users/sign_up"; $free = "250 searches a month"
    $how = "Copy the whole key from https://serpapi.com/manage-api-key."
  }
  Write-Host ""
  Write-Host "  $name  " -NoNewline
  Write-Host "free plan: $free" -ForegroundColor DarkGray
  if ($cur) {
    $rc = Check-SearchKey $provider $cur
    if ($rc -eq 0) { Ok "Saved key works: $($script:KeyInfo)"; return $cur }
    if ($rc -eq 2) { Warn "Couldn't reach $name to check the saved key; keeping it."; return $cur }
    Warn "$name rejects the saved key; let's replace it."
  }
  Say "1. Create a free account: $signup"
  Say "2. $how"
  $def = "open"
  while ($true) {
    $c = Choose "$name key" $def @(
      "open|Open the sign-up page|in your browser, then paste the key here",
      "paste|Paste a key|I already have one",
      "skip|Skip for now|add it later with setup.cmd configure")
    if ($c -eq "skip") { return "" }
    if ($c -eq "open") {
      try { Start-Process $signup; Note "Opened $signup" } catch { Note "Open $signup in your browser." }
    }
    $key = Ask-Secret "Paste the $name key (hidden)"
    $key = "$key" -replace '\s', ''
    $def = "paste"
    # Nothing pasted: offer Skip next, so Enter moves on (and unattended runs end).
    if (-not $key) { $def = "skip"; continue }
    $rc = Check-SearchKey $provider $key
    if ($rc -eq 0) { Ok "$name key works: $($script:KeyInfo)"; return $key }
    if ($rc -eq 2) { Warn "Couldn't reach $name to check the key; saving it anyway."; return $key }
    Warn "$name rejected that key. Copy the whole key and try again."
  }
}

function Configure-Search {
  $cur = EnvGet "WEB_SEARCH_ENGINE"
  if ($cur -eq "external") { $cur = "auto" }
  if ((EnvGet "ENABLE_WEB_SEARCH") -ne "true" -or -not $cur) { $cur = "off" }
  $brave = EnvGet "BRAVE_SEARCH_API_KEY"
  $tavily = EnvGet "TAVILY_API_KEY"
  $serpapi = EnvGet "SERPAPI_API_KEY"
  Say "Web search lets the model look things up instead of guessing from"
  Say "training data that is months or years old. It's what makes answers about"
  Say "new software, products, prices and news right."
  Write-Host ""
  Write-Host "  Recommended: two free accounts, about 5 minutes." -ForegroundColor White
  Write-Host "    Tavily    " -ForegroundColor White -NoNewline; Write-Host "search built for AI; returns the useful part of each page"
  Write-Host "    SerpAPI   " -ForegroundColor White -NoNewline; Write-Host "Google results"
  Say "Auto uses Tavily, switches to SerpAPI if Tavily fails or runs out of"
  Say "searches, then to DuckDuckGo. DuckDuckGo needs no account but often"
  Say "returns weak results, and answers suffer for it."
  Note "Only the search terms the model writes are sent; your chats stay here."
  Write-Host ""
  $engine = Choose "Web search" $cur @(
    "auto|Auto (recommended)|Tavily, then SerpAPI, then DuckDuckGo",
    "tavily|Tavily only|free account",
    "serpapi|SerpAPI only|free account; Google results",
    "brave|Brave Search|needs a Brave Search API key",
    "duckduckgo|DuckDuckGo only|no account; weaker results",
    "off|Off|no web access (most private)")
  if ($engine -eq "auto") {
    $tavily = Search-Key "tavily" $tavily
    $serpapi = Search-Key "serpapi" $serpapi
    if (-not $tavily -and -not $serpapi) { Write-Host ""; Warn "No keys yet, so Auto uses DuckDuckGo. Add keys any time: setup.cmd configure" }
  } elseif ($engine -eq "tavily") {
    $tavily = Search-Key "tavily" $tavily
    if (-not $tavily) { Warn "No Tavily key, so using DuckDuckGo instead."; $engine = "duckduckgo" }
  } elseif ($engine -eq "serpapi") {
    $serpapi = Search-Key "serpapi" $serpapi
    if (-not $serpapi) { Warn "No SerpAPI key, so using DuckDuckGo instead."; $engine = "duckduckgo" }
  } elseif ($engine -eq "brave") {
    if (-not $brave -or -not (YesNo "Keep the saved Brave key?" "y")) {
      Note "Key: https://api-dashboard.search.brave.com > API Keys (see brave.com/search/api for plans)."
      $brave = Ask-Secret "Paste the Brave Search API key (hidden)"
    }
  }
  return @($engine, $brave, $tavily, $serpapi)
}

function Summary-Row([string]$label, [string]$value) {
  Write-Host ("  {0,-17}" -f $label) -ForegroundColor DarkGray -NoNewline
  Write-Host $value
}

function Configure {
  Write-Host ""
  Write-Host "  Open WebUI + Ollama setup  " -ForegroundColor Cyan -NoNewline
  Write-Host "Windows" -ForegroundColor DarkGray
  Note "A private ChatGPT-style assistant on your own hardware."
  if ($script:Ui) { Note "Use the arrow keys and Enter to choose, Space to tick boxes. Ctrl+C quits." }
  Note "Nothing changes until you confirm at the end."

  Step "1 of 7 $($script:Dot) Ollama"
  $cur = EnvGet "OLLAMA_MODE"
  $mode = Choose "How should Ollama run?" $cur @(
    "native|Ollama app for Windows (recommended)|simplest; uses NVIDIA and AMD GPUs automatically",
    "container|Inside Docker|only if you want everything in Docker; NVIDIA or CPU")
  $hw = ""
  if ($mode -eq "container") {
    $hw = EnvGet "COMPOSE_PROFILES"
    $detected = "ollama-cpu"
    if ((Get-NvidiaGb) -gt 0) { $detected = "ollama-nvidia" }
    if (-not $hw) { $hw = $detected }
    $dn = ""; $dc = ""
    if ($detected -eq "ollama-nvidia") { $dn = " $($script:Dot) detected" } else { $dc = " $($script:Dot) detected" }
    Write-Host ""
    $hw = Choose "Hardware" $hw @(
      "ollama-nvidia|NVIDIA GPU|Docker Desktop passes it through$dn",
      "ollama-cpu|CPU only|works, but slowly$dc")
  }

  Step "2 of 7 $($script:Dot) Models"
  $modelsDir = Pick-ModelFolder (EnvGet "OLLAMA_MODELS") $mode
  Write-Host ""
  $models = Pick-Models (EnvGet "OLLAMA_PULL_MODELS")

  Step "3 of 7 $($script:Dot) Web search"
  $search = Configure-Search
  $searchOn = ($search[0] -ne "off")

  Step "4 of 7 $($script:Dot) GPU memory"
  $memory = Configure-Memory $models $searchOn
  # Whole pages give better answers but need room: 4 pages plus the chat.
  $bypass = "false"; $results = "5"
  if ($searchOn -and $memory[0] -and [int]$memory[0] -ge 65536) { $bypass = "true"; $results = "4" }

  Step "5 of 7 $($script:Dot) Remote access"
  Say "Tailscale lets your phone and laptop reach this PC from anywhere at"
  Say "https://<pc-name>.<tailnet>.ts.net, without exposing it to your Wi-Fi"
  Say "network or the internet. It's free for personal use: create an account at"
  Say "https://login.tailscale.com/start and install the app on each device."
  Write-Host ""
  $tsDef = "y"
  if ((EnvGet "TAILSCALE_SERVE") -eq "false") { $tsDef = "n" }
  $ts = "false"
  if (YesNo "Set up Tailscale remote access?" $tsDef) { $ts = "true" }

  Step "6 of 7 $($script:Dot) Cloud models (optional)"
  $cloud = Configure-Cloud

  Step "7 of 7 $($script:Dot) Final details"
  Say "Open WebUI listens on this PC only (127.0.0.1). Keep 3000 unless another"
  Say "app uses it."
  do { $port = Ask "Port" (EnvGet "OPEN_WEBUI_PORT") } until ($port -match "^\d+$")
  Write-Host ""
  $pcDef = "false"
  if ((EnvGet "ENABLE_PERSISTENT_CONFIG") -eq "true") { $pcDef = "true" }
  $persist = Choose "Where should settings live?" $pcDef @(
    "false|.env file (recommended)|edit .env or ask an AI CLI; re-applied on every start",
    "true|Admin Panel|.env only sets things up once; then manage settings in the web UI")
  Write-Host ""
  Note "API keys let scripts and tools use Open WebUI as your account."
  $akDef = "n"
  if ((EnvGet "ENABLE_API_KEYS") -eq "true") { $akDef = "y" }
  $apiKeys = "false"
  if (YesNo "Allow API keys? (only needed for scripts and tools)" $akDef) { $apiKeys = "true" }

  $searchText = $search[0]
  if ($search[0] -eq "auto") {
    $chain = @()
    if ($search[2]) { $chain += "Tavily" }
    if ($search[3]) { $chain += "SerpAPI" }
    $chain += "DuckDuckGo"
    $searchText = "Auto: " + ($chain -join " > ")
  }
  $modeText = $mode
  if ($hw) { $modeText = "$mode ($hw)" }
  $dirText = $modelsDir
  if (-not $dirText) { $dirText = "Ollama's default"; if ($mode -eq "container") { $dirText = "inside Docker" } }
  $ctxText = $memory[0]
  if (-not $ctxText) { $ctxText = "Ollama default" }
  if ($memory[1] -eq "1") { $ctxText = "$ctxText tokens, flash attention, $($memory[2]) cache" }
  $first = (($models -split "\s+") | Where-Object { $_ } | Select-Object -First 1)
  Step "Summary"
  Summary-Row "Ollama" $modeText
  $modelText = $models; if (-not $modelText) { $modelText = "(none)" }
  Summary-Row "Models" $modelText
  if ($first) { Summary-Row "Chats start with" $first }
  Summary-Row "Model folder" $dirText
  Summary-Row "Context" $ctxText
  Summary-Row "Web search" $searchText
  $tsText = "this PC only"; if ($ts -eq "true") { $tsText = "Tailscale (tailnet only)" }
  Summary-Row "Remote access" $tsText
  $cloudText = $cloud[0]; if (-not $cloudText) { $cloudText = "(none)" }
  Summary-Row "Cloud models" $cloudText
  Summary-Row "Local URL" "http://localhost:$port"
  $settingsFrom = ".env"; if ($persist -eq "true") { $settingsFrom = "Admin Panel" }
  Summary-Row "Settings from" $settingsFrom
  $akText = "off"; if ($apiKeys -eq "true") { $akText = "allowed" }
  Summary-Row "API keys" $akText
  Write-Host ""
  if (-not (YesNo "Save these settings and start?" "y")) { Fail "Nothing saved." }

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
  EnvSet "DEFAULT_MODELS" "$first"
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
  EnvSet "ENABLE_API_KEYS" $apiKeys
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
