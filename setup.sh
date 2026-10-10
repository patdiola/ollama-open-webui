#!/usr/bin/env bash
# Open WebUI + Ollama setup for macOS and Linux. Windows: run setup.cmd.
#
#   ./setup.sh             first run: configure, then start everything
#                          later runs: apply .env (update images, pull models)
#   ./setup.sh configure   change your answers, then apply
#   ./setup.sh status      show what's running
#   ./setup.sh stop        stop the containers (data is kept)
#
# All answers are saved to .env (gitignored). Nothing personal is written
# anywhere else.
set -euo pipefail
cd "$(dirname "$0")"

ENV_FILE=.env
OLLAMA_SERVICES="ollama-cpu ollama-nvidia ollama-amd"
OLLAMA_TUNING="OLLAMA_MODELS OLLAMA_CONTEXT_LENGTH OLLAMA_FLASH_ATTENTION OLLAMA_KV_CACHE_TYPE"

# ------------------------------------------------------------------ helpers

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
ok()   { printf '  \033[32mok\033[0m  %s\n' "$*"; }
warn() { printf '  \033[33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\n\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n'; bold "== $*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ask "Question" default  -> $REPLY
ask() {
  local hint=""
  [ -n "$2" ] && hint=" [$2]"
  read -r -p "  $1$hint: " REPLY </dev/tty || true
  [ -z "$REPLY" ] && REPLY="$2"
  return 0
}

# ask_secret "Question"  -> $REPLY (not echoed)
ask_secret() {
  read -r -s -p "  $1: " REPLY </dev/tty || true
  printf '\n'
}

# yesno "Question" y|n  -> exit status
yesno() {
  local def="$2" hint="y/N"
  [ "$def" = y ] && hint="Y/n"
  while true; do
    read -r -p "  $1 [$hint]: " REPLY </dev/tty || true
    case "${REPLY:-$def}" in
      [Yy]*) return 0 ;;
      [Nn]*) return 1 ;;
    esac
  done
}

# env_get KEY  -> value from .env, falling back to .env.example
env_get() {
  local f v
  for f in "$ENV_FILE" .env.example; do
    [ -f "$f" ] || continue
    if grep -qE "^$1=" "$f"; then
      v=$(grep -E "^$1=" "$f" | tail -n 1 | cut -d= -f2- | tr -d '\r')
      v=${v#\"}; v=${v%\"}; v=${v#\'}; v=${v%\'}
      printf '%s' "$v"
      return 0
    fi
  done
  return 0
}

# env_set KEY VALUE  -> replaces or appends the line in .env. Values with
# spaces, $, # or quotes are single-quoted so Compose reads them literally.
env_set() {
  local tmp="$ENV_FILE.tmp.$$" v="$2"
  case "$v" in *"'"*) die "$1 can't contain a single quote." ;; esac
  case "$v" in *[[:space:]\$\#\"\`\\]*) v="'$v'" ;; esac
  K="$1" V="$v" awk '
    BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"]; done = 0 }
    index($0, k "=") == 1 { if (!done) print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }
  ' "$ENV_FILE" > "$tmp"
  cat "$tmp" > "$ENV_FILE"
  rm -f "$tmp"
}

gen_secret() {
  if have openssl; then openssl rand -hex 32
  else od -An -tx1 -N32 /dev/urandom | tr -d ' \n'; fi
}

# Ubuntu (or any distro) on Windows via WSL: hand off to the Windows setup.
# Ollama, Docker Desktop and Tailscale run best as Windows apps: they start
# with Windows and stay up, while WSL shuts down when its terminal closes.
# Set SETUP_IN_WSL=1 to run the Linux setup inside WSL anyway (unsupported).
#
# PowerShell can't run a script stored inside WSL's own filesystem, so a repo
# there (e.g. ~/git/...) is cloned to the same path under the Windows user
# folder, along with the personal gitignored files, and setup continues there.
wsl_move_to_windows() {
  local win_home rel dest f before
  win_home=$(powershell.exe -NoProfile -Command '[Environment]::GetFolderPath("UserProfile")' 2>/dev/null | tr -d '\r')
  [ -n "$win_home" ] || die "Can't find your Windows user folder. Clone this repo under /mnt/c/, then run ./setup.sh from there."
  win_home=$(wslpath -u "$win_home")
  case "$PWD" in
    "$HOME"/*) rel=${PWD#"$HOME"/} ;;
    *) rel=$(basename "$PWD") ;;
  esac
  dest="$win_home/$rel"

  bold "WSL detected, but this repo is inside WSL's own filesystem."
  info "The Windows setup needs it in a Windows folder."
  if have git && [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    warn "Uncommitted changes here won't be copied; commit them first to include them."
  fi
  if [ -f "$dest/setup.sh" ]; then
    info "Using the existing copy at $(wslpath -w "$dest")"
    # Bring it up to date with this copy's commits. Fast-forward only, so
    # nothing there is overwritten; its .env (your saved answers) is kept.
    if have git && [ -d "$dest/.git" ]; then
      before=$(git -C "$dest" rev-parse HEAD 2>/dev/null || true)
      if git -C "$dest" pull -q --ff-only "$PWD" HEAD >/dev/null 2>&1; then
        [ "$(git -C "$dest" rev-parse HEAD)" = "$before" ] || ok "Updated it with the commits from this copy"
      else
        warn "Couldn't update it from this copy (it has changes of its own). Continuing with it as is."
      fi
    fi
  else
    [ -e "$dest" ] && die "$(wslpath -w "$dest") already exists. Move it aside, or clone this repo under /mnt/c/ yourself."
    have git || die "git is not installed. Clone this repo under /mnt/c/, then run ./setup.sh from there."
    yesno "Clone it to $(wslpath -w "$dest") and continue there?" y \
      || die "Clone this repo under /mnt/c/, then run ./setup.sh from there."
    mkdir -p "$(dirname "$dest")"
    git clone -q "$PWD" "$dest" || die "Cloning to $(wslpath -w "$dest") failed."
    if f=$(git remote get-url origin 2>/dev/null); then
      git -C "$dest" remote set-url origin "$f"
    fi
    ok "Cloned to $(wslpath -w "$dest")"
  fi
  for f in .env .privacy-denylist; do
    if [ -f "$f" ] && [ ! -e "$dest/$f" ]; then
      cp -p "$f" "$dest/$f" && ok "Copied $f"
    fi
  done
  info "Use that copy from now on: cd $dest"
  cd "$dest"
  exec bash ./setup.sh "$@"
}

if [ -z "${SETUP_IN_WSL:-}" ] && grep -qi microsoft /proc/version 2>/dev/null; then
  have powershell.exe || die "Can't find powershell.exe. Run setup.cmd from Windows instead."
  case "$PWD" in
    /mnt/[a-z]/*) ;;
    *) wsl_move_to_windows "$@" ;;
  esac
  bold "WSL detected: running the Windows setup (setup.ps1)."
  exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$PWD/setup.ps1")" "$@"
fi

OS=$(uname -s)
case "$OS" in
  Darwin) OS_NAME=macOS ;;
  Linux)  OS_NAME=Linux ;;
  *) die "Unsupported OS: $OS. On Windows, run setup.cmd." ;;
esac

# Sudo only when needed (Linux, not root).
SUDO=""
[ "$OS" = Linux ] && [ "$(id -u)" -ne 0 ] && SUDO="sudo"

offer_install() {  # offer_install "what" "command"
  warn "$1 is not installed."
  info "Install command: $2"
  if yesno "Run it now?" n; then
    sh -c "$2" || die "Installing $1 failed. Install it manually, then re-run ./setup.sh"
  else
    die "Install $1, then re-run ./setup.sh"
  fi
}

# ------------------------------------------------------------- hardware

# Prints "budget_gb|description": memory a model can use for fast inference.
detect_memory() {
  local gb vram
  if [ "$OS" = Darwin ]; then
    gb=$(( $(sysctl -n hw.memsize) / 1073741824 ))
    awk -v g="$gb" 'BEGIN { printf "%.0f|%d GB unified memory (about 70%% usable by the GPU)", g * 0.7, g }'
    return
  fi
  if have nvidia-smi && vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null); then
    vram=$(printf '%s\n' "$vram" | awk '{ s += $1 } END { printf "%.0f", s / 1024 }')
    if [ "${vram:-0}" -gt 0 ]; then
      printf '%s|%s GB NVIDIA GPU memory' "$vram" "$vram"
      return
    fi
  fi
  gb=$(awk '/MemTotal/ { printf "%.0f", $2 / 1048576 }' /proc/meminfo)
  awk -v g="$gb" 'BEGIN { printf "%.0f|%d GB RAM, no NVIDIA GPU detected (AMD/CPU: smaller models are faster)", g * 0.5, g }'
}

# Prints the suggested container profile for Linux.
detect_profile() {
  if have nvidia-smi && nvidia-smi >/dev/null 2>&1; then
    echo ollama-nvidia
  elif [ -e /dev/kfd ]; then
    echo ollama-amd
  else
    echo ollama-cpu
  fi
}

# ------------------------------------------------------------- configure

# A setting the running native Ollama uses (macOS), from its server log. The
# Ollama app has its own settings (model location, context length) that it
# passes to the server, which can win over .env.
ollama_in_use() {
  local log="$HOME/.ollama/logs/server.log"
  [ "$OS" = Darwin ] && [ -f "$log" ] || return 1
  awk -v k="$1:" '(i = index($0, k)) {
    s = substr($0, i + length(k)); j = index(s, " OLLAMA_")
    v = j ? substr(s, 1, j - 1) : s; found = 1
  } END { if (!found) exit 1; print v }' "$log"
}

# Warns when native Ollama doesn't use a setting from .env.
check_ollama_settings() {
  local k want have bad=""
  for k in $OLLAMA_TUNING; do
    want=$(env_get "$k")
    [ -n "$want" ] || continue
    have=$(ollama_in_use "$k") || return 0
    [ "$k" = OLLAMA_FLASH_ATTENTION ] && { [ "$want" = 1 ] && want=true; [ "$want" = 0 ] && want=false; }
    [ "${have%/}" = "${want%/}" ] || bad="$bad
      $k is '$have', .env says '$want'"
  done
  [ -n "$bad" ] || return 0
  warn "Ollama isn't using some settings from .env:$bad"
  info "The Ollama app's own Settings (Model location, Context length) can"
  info "override them. Change those there to match, then quit and reopen Ollama."
}

# Folders holding Ollama models (home folder, plus external drives), so
# existing downloads can be reused.
find_model_stores() {
  local roots="$HOME" r
  if [ "$OS" = Darwin ]; then roots="$roots /Volumes"; else roots="$roots /usr/share/ollama /media /srv"; fi
  # /mnt holds the Windows drives under WSL; searching them is very slow.
  grep -qi microsoft /proc/version 2>/dev/null || roots="$roots /mnt"
  for r in $roots; do
    [ -d "$r" ] || continue
    find "$r" -maxdepth 5 \( -name Library -o -name node_modules -o -name .git -o -name .cache \) -prune \
      -o -type d -name manifests -print 2>/dev/null || true
  done | while IFS= read -r d; do
    [ -d "${d%/manifests}/blobs" ] && echo "${d%/manifests}"
  done | sort -u
}

# Model names (name:tag) in an Ollama models folder.
store_models() {
  [ -d "$1/manifests" ] || return 0
  find "$1/manifests" -type f 2>/dev/null | awk -v p="$1/manifests/" '{
    s = substr($0, length(p) + 1)
    sub(/^registry\.ollama\.ai\/library\//, "", s); sub(/^registry\.ollama\.ai\//, "", s)
    n = split(s, a, "/"); name = a[1]
    for (i = 2; i < n; i++) name = name "/" a[i]
    print name ":" a[n]
  }'
}

# Asks where Ollama keeps models -> $MODELS_DIR ("" for Ollama's default).
pick_model_folder() {
  local current="$1" default="" in_use="" list="" d i names count gb
  # macOS runs Ollama natively; Linux runs it in Docker.
  if [ "$OS" = Darwin ]; then
    default="$HOME/.ollama/models"
    in_use=$(ollama_in_use OLLAMA_MODELS | sed 's#/*$##') || in_use=""
  fi
  info "Searching this computer for models Ollama already downloaded..."
  list=$( { [ -n "$default" ] && echo "$default"; [ -n "$in_use" ] && echo "$in_use"; [ -n "$current" ] && echo "$current"; find_model_stores; } \
    | sed 's#/*$##' | awk 'NF && !seen[$0]++')
  i=0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    i=$((i + 1))
    printf '   %2d) %s%s\n' "$i" "$d" "$( [ "$d" = "$in_use" ] && echo "  (Ollama uses this now)" || { [ "$d" = "$default" ] && echo "  (Ollama's default)"; })"
    names=$(store_models "$d")
    if [ -n "$names" ]; then
      count=$(printf '%s\n' "$names" | wc -l | tr -d ' ')
      gb=$(du -sk "$d/blobs" 2>/dev/null | awk '{ printf "%.0f", $1 / 1048576 }')
      info "      $count models, ${gb:-0} GB: $(printf '%s\n' "$names" | head -n 4 | paste -sd, - | sed 's/,/, /g')$( [ "$count" -gt 4 ] && echo ", ...")"
    else
      info "      no models yet"
    fi
  done <<EOF
$list
EOF
  info "Free space in your home folder: $(df -Pk "$HOME" | awk 'NR == 2 { printf "%.0f GB", $4 / 1048576 }')"
  info ""
  info "Models take 2-65 GB each, so pick a drive with room. Picking a folder"
  info "that already has models means those won't be downloaded again."
  if [ -z "$default" ]; then
    info "Enter a number or a folder path, or press Enter with nothing to keep"
    info "models inside Docker."
  else
    info "Enter a number or a folder path (created if missing)."
  fi
  while true; do
    ask "Model folder" "${current:-${in_use:-$default}}"
    d=$REPLY
    case "$d" in "~"/*) d="$HOME/${d#"~"/}" ;; esac
    d=$(printf '%s' "$d" | sed 's#/*$##')
    case "$d" in
      *[!0-9]*|'') ;;
      *) d=$(printf '%s\n' "$list" | sed -n "${d}p") ;;
    esac
    if [ -z "$d" ] && [ -z "$default" ]; then MODELS_DIR=""; return 0; fi
    case "$d" in /*) break ;; esac
    warn "Enter a number from the list or a full path like /Volumes/Big/ollama."
  done
  [ "$d" = "$default" ] && d=""
  MODELS_DIR=$d
}

pick_models() {
  local current="$1" mem budget desc i=0 tag size note fit choice out=""
  mem=$(detect_memory); budget=${mem%%|*}; desc=${mem#*|}
  info "Detected: $desc"
  info ""
  while IFS='|' read -r tag size note; do
    case "$tag" in ''|\#*) continue ;; esac
    i=$((i + 1))
    fit=$(awk -v s="$size" -v b="$budget" 'BEGIN { print (s * 1.2 <= b) ? "fits " : "big  " }')
    printf '   %2d) %-18s %5s GB  %s %s\n' "$i" "$tag" "$size" "$fit" "$note"
  done < models.txt
  info ""
  info "How to choose: start with one or two models marked 'fits'. Bigger"
  info "models are smarter but slower; a model marked 'big' still works, just"
  info "slowly. Each one takes its size in disk space. You can add or remove"
  info "models later with './setup.sh configure'. Browse more at ollama.com/library."
  info ""
  info "Enter numbers and/or any Ollama tags, separated by spaces (e.g. 2 5)."
  ask "Models to download" "$current"
  for choice in $REPLY; do
    case "$choice" in
      *[!0-9]*) out="$out $choice" ;;
      *) tag=$(grep -vE '^(#|$)' models.txt | sed -n "${choice}p" | cut -d'|' -f1)
         [ -n "$tag" ] && out="$out $tag" || warn "No model number $choice; skipped." ;;
    esac
  done
  MODELS=$(echo $out)
}

# Largest power-of-two context whose cache fits in $1 GB with cache type $2.
# Calibrated on qwen3:30b (about 8000 tokens per GB of f16 cache); models
# that need more are caught by check_gpu_fit after setup.
context_suggestion() {
  awk -v l="$1" -v kv="$2" 'BEGIN {
    f = (kv == "q8_0") ? 0.53 : (kv == "q4_0") ? 0.28 : 1
    t = l * 8000 / f; c = 2048
    while (c * 2 <= t && c < 131072) c *= 2
    print c
  }'
}

# Suggests GPU memory settings, leaving headroom for context and other apps.
# With web search on ($1 = true), it favours a 4-bit cache: search results
# fill the context, so twice the context matters more than exact recall.
configure_memory() {
  local search=$1 mem budget m size largest=0 largest_tag="" left suggest def d
  mem=$(detect_memory); budget=${mem%%|*}
  for m in $MODELS; do
    size=$(grep -vE '^(#|$)' models.txt | awk -F'|' -v t="$m" '$1 == t { print $2 }')
    [ -n "$size" ] || continue
    if awk -v a="$size" -v b="$largest" 'BEGIN { exit !(a > b) }'; then largest=$size; largest_tag=$m; fi
  done
  left=$(awk -v b="$budget" -v l="$largest" 'BEGIN { printf "%.1f", b * 0.9 - l }')
  info "Besides the model itself, Ollama needs memory for the conversation it"
  info "keeps in context. Leave headroom: if it all doesn't fit in GPU memory,"
  info "part of the model runs on the CPU and replies get much slower."
  info "  Memory for models: $budget GB, keeping 10% free for the desktop and other apps"
  [ -n "$largest_tag" ] && info "  Largest model:     $largest_tag, about $largest GB"
  info "  Left for context:  about $left GB"
  d=$(ollama_in_use OLLAMA_CONTEXT_LENGTH) && [ -n "$d" ] && info "  Ollama uses now:   $d tokens"
  info ""
  info "Flash attention shrinks the context memory and is usually faster. With"
  info "it on, the context can be stored at lower precision:"
  info "  q8_0  about half the memory, little quality loss"
  info "  q4_0  about a quarter; recalls details from long chats a bit less exactly"
  [ "$search" = true ] && info "Recommended with web search: q4_0, so search results get twice the room."
  def=y; [ "$(env_get OLLAMA_FLASH_ATTENTION)" = 0 ] && def=n
  if yesno "Use flash attention?" "$def"; then
    FA=1
    def=$(env_get OLLAMA_KV_CACHE_TYPE)
    [ -n "$def" ] || { [ "$search" = true ] && def=q4_0 || def=q8_0; }
    while true; do
      ask "Context precision (q8_0 or q4_0)" "$def"
      case "$REPLY" in q8_0|q4_0) KV=$REPLY; break ;; esac
    done
  else
    FA=0; KV=""
  fi
  suggest=$(context_suggestion "$left" "$KV")
  info ""
  info "About $suggest tokens of context fit in the room left. Lower is safer;"
  info "0 leaves it to Ollama. After setup, setup checks that the model fits."
  if [ "$search" = true ]; then
    info "Web search needs 16384 or more. With 65536 or more, it sends whole pages"
    info "(4 results) instead of excerpts, which gives better answers."
  fi
  def=$(env_get OLLAMA_CONTEXT_LENGTH); [ -n "$def" ] || def=$suggest
  while true; do
    ask "Context length in tokens" "$def"
    case "$REPLY" in ''|*[!0-9]*) ;; *) CTX=$REPLY; break ;; esac
  done
  [ "$CTX" = 0 ] && CTX=""
  return 0
}

configure_cloud() {
  local urls keys url key n
  urls=$(env_get OPENAI_API_BASE_URLS); keys=$(env_get OPENAI_API_KEYS)
  if [ -n "$urls" ]; then
    n=$(printf '%s' "$urls" | awk -F';' '{ print NF }')
    info "Currently configured: $n cloud connection(s)."
    if yesno "Keep them?" y; then
      CLOUD_URLS=$urls; CLOUD_KEYS=$keys; return
    fi
  fi
  CLOUD_URLS=""; CLOUD_KEYS=""
  info "Cloud models are optional. They're smarter than most local models, but"
  info "chats sent to them leave your machine, and the provider bills you per use."
  info "Skip this if you want everything private; you can add one later."
  yesno "Add a cloud model provider (OpenAI, OpenRouter, ...)?" n || return 0
  while true; do
    info "  1) OpenAI      GPT models, directly from OpenAI"
    info "  2) OpenRouter  one key for many providers (Claude, GPT, Gemini, ...)"
    info "  3) Other       any OpenAI-compatible API (Groq, Together, a local server)"
    ask "Provider" "1"
    case "$REPLY" in
      1) url=https://api.openai.com/v1
         info "Get a key: sign in at https://platform.openai.com/api-keys, click"
         info "'Create new secret key', and copy it (starts with sk-). API use is"
         info "billed separately from ChatGPT; add credit under Settings > Billing." ;;
      2) url=https://openrouter.ai/api/v1
         info "Get a key: sign in at https://openrouter.ai/keys, click 'Create Key',"
         info "and copy it (starts with sk-or-). Add credit at openrouter.ai/credits." ;;
      3) info "Find the base URL in the provider's API docs (often ends in /v1),"
         info "and create a key in their dashboard."
         ask "Base URL" ""; url=$REPLY ;;
      *) continue ;;
    esac
    [ -n "$url" ] || continue
    ask_secret "Paste the API key (hidden; it's saved only in .env)"; key=$REPLY
    [ -n "$key" ] || { warn "No key entered; skipped."; continue; }
    case "$key" in *';'*) warn "Keys can't contain ';'. Skipped."; continue ;; esac
    if [ -z "$CLOUD_URLS" ]; then CLOUD_URLS=$url; CLOUD_KEYS=$key
    else CLOUD_URLS="$CLOUD_URLS;$url"; CLOUD_KEYS="$CLOUD_KEYS;$key"; fi
    yesno "Add another provider?" n || break
  done
}

configure_search() {
  local cur
  cur=$(env_get WEB_SEARCH_ENGINE)
  [ "$(env_get ENABLE_WEB_SEARCH)" = true ] || cur=off
  info "Web search lets models look things up online; it's on by default. The"
  info "search queries, not your whole chat, go to the provider you pick."
  info "  off         no web access (most private)"
  info "  duckduckgo  no account or key needed; can be rate-limited if used heavily"
  info "  brave       needs a Brave Search API key; reliable, independent index"
  info "  tavily      needs a Tavily API key; built for AI, returns cleaner results"
  info "Not sure? Keep duckduckgo; pick off for no web access."
  while true; do
    ask "Web search" "${cur:-off}"
    case "$REPLY" in off|duckduckgo|brave|tavily) SEARCH=$REPLY; break ;; esac
  done
  BRAVE_KEY=$(env_get BRAVE_SEARCH_API_KEY); TAVILY_KEY=$(env_get TAVILY_API_KEY)
  if [ "$SEARCH" = brave ] && { [ -z "$BRAVE_KEY" ] || ! yesno "Keep the saved Brave key?" y; }; then
    info "Get a key: sign up at https://api-dashboard.search.brave.com, choose a"
    info "plan (see brave.com/search/api for current pricing), then open"
    info "'API Keys' and copy the key."
    ask_secret "Paste the Brave Search API key (hidden)"; BRAVE_KEY=$REPLY
  fi
  if [ "$SEARCH" = tavily ] && { [ -z "$TAVILY_KEY" ] || ! yesno "Keep the saved Tavily key?" y; }; then
    info "Get a key: sign up at https://app.tavily.com; your key (starts with"
    info "tvly-) is on the overview page. Check their site for current free limits."
    ask_secret "Paste the Tavily API key (hidden)"; TAVILY_KEY=$REPLY
  fi
}

configure() {
  bold ""
  bold "Open WebUI + Ollama setup ($OS_NAME)"
  info "Answer each question, or press Enter to keep the value in [brackets]."
  info "Nothing is changed until you confirm at the end."

  step "1/7  Ollama"
  local profile=""
  if [ "$OS" = Darwin ]; then
    MODE=native
    info "macOS: Ollama runs as a native app so it can use the GPU."
  else
    MODE=container
    profile=$(env_get COMPOSE_PROFILES)
    [ -n "$profile" ] || profile=$(detect_profile)
    info "Linux: Ollama runs in Docker. Pick the hardware it should use:"
    info "  ollama-nvidia  NVIDIA graphics card (needs nvidia-container-toolkit)"
    info "  ollama-amd     AMD Radeon card supported by ROCm"
    info "  ollama-cpu     no supported GPU; works anywhere, but slowly"
    info "Not sure? 'nvidia-smi' working means NVIDIA. The suggestion below was"
    info "detected on this machine; press Enter to accept it."
    while true; do
      ask "Ollama hardware" "$profile"
      case "$REPLY" in ollama-cpu|ollama-nvidia|ollama-amd) profile=$REPLY; break ;; esac
    done
  fi

  step "2/7  Models"
  pick_model_folder "$(env_get OLLAMA_MODELS)"
  info ""
  pick_models "$(env_get OLLAMA_PULL_MODELS)"

  step "3/7  Local port"
  info "Open WebUI listens on this machine only (127.0.0.1). Keep 3000 unless"
  info "another app already uses it; then pick any free number like 3001 or 8080."
  while true; do
    ask "Port" "$(env_get OPEN_WEBUI_PORT)"
    case "$REPLY" in ''|*[!0-9]*) ;; *) PORT=$REPLY; break ;; esac
  done

  step "4/7  Remote access (Tailscale)"
  info "Tailscale lets your phone and laptop reach this machine from anywhere at"
  info "https://<pc-name>.<tailnet>.ts.net, without exposing anything to your"
  info "Wi-Fi network or the internet. It's free for personal use: create an"
  info "account at https://login.tailscale.com/start and install the app on each"
  info "device. Say no only if you'll use Open WebUI on this machine alone."
  if yesno "Set up Tailscale remote access?" "$( [ "$(env_get TAILSCALE_SERVE)" = false ] && echo n || echo y)"; then
    TS=true; else TS=false; fi

  step "5/7  Optional extras"
  configure_cloud
  configure_search

  step "6/7  GPU memory"
  configure_memory "$( [ "$SEARCH" = off ] && echo false || echo true)"
  # Whole pages give better answers but need room: 4 pages plus the chat.
  BYPASS=false; RESULTS=5
  if [ "$SEARCH" != off ] && [ "${CTX:-0}" -ge 65536 ]; then BYPASS=true; RESULTS=4; fi

  step "7/7  Where settings live"
  info "a) .env (recommended): your answers here, or edits to .env (by hand or by"
  info "   an AI coding CLI), are applied on every start. Changes you make to the"
  info "   same settings in Open WebUI's Admin Panel reset on restart."
  info "b) Admin Panel: .env only sets things up the first time; afterwards you"
  info "   manage settings in Open WebUI's web interface."
  info "Pick a if you'd rather configure from files or with an AI CLI."
  local pc=a
  [ "$(env_get ENABLE_PERSISTENT_CONFIG)" = true ] && pc=b
  while true; do
    ask "Choice" "$pc"
    case "$REPLY" in a) PERSIST=false; break ;; b) PERSIST=true; break ;; esac
  done

  step "Summary"
  info "Ollama:        $MODE${profile:+ ($profile)}"
  info "Models:        ${MODELS:-(none)}"
  info "Model folder:  ${MODELS_DIR:-$( [ "$MODE" = native ] && echo "Ollama's default" || echo "inside Docker")}"
  info "Context:       ${CTX:-Ollama default}$( [ "$FA" = 1 ] && echo " tokens, flash attention, $KV cache")"
  info "Local URL:     http://localhost:$PORT"
  info "Tailscale:     $TS"
  info "Cloud APIs:    ${CLOUD_URLS:-(none)}"
  info "Web search:    $SEARCH$( [ "$SEARCH" = off ] || { [ "$BYPASS" = true ] && echo ", whole pages, $RESULTS results" || echo ", excerpts, $RESULTS results"; })"
  info "Settings from: $( [ "$PERSIST" = false ] && echo .env || echo 'Admin Panel')"
  yesno "Save to .env?" y || die "Nothing saved."

  if [ ! -f "$ENV_FILE" ]; then
    cp .env.example "$ENV_FILE"
  fi
  chmod 600 "$ENV_FILE"
  [ -n "$(env_get WEBUI_SECRET_KEY)" ] || env_set WEBUI_SECRET_KEY "$(gen_secret)"

  env_set OLLAMA_MODE "$MODE"
  if [ "$MODE" = container ]; then
    env_set COMPOSE_PROFILES "$profile"
    env_set OLLAMA_BASE_URL "http://ollama:11434"
  else
    env_set COMPOSE_PROFILES ""
    env_set OLLAMA_BASE_URL "http://host.docker.internal:11434"
  fi
  env_set OLLAMA_PULL_MODELS "$MODELS"
  env_set OLLAMA_MODELS "$MODELS_DIR"
  env_set OLLAMA_CONTEXT_LENGTH "$CTX"
  env_set OLLAMA_FLASH_ATTENTION "$FA"
  env_set OLLAMA_KV_CACHE_TYPE "$KV"
  env_set OPEN_WEBUI_PORT "$PORT"
  env_set TAILSCALE_SERVE "$TS"
  env_set OPENAI_API_BASE_URLS "$CLOUD_URLS"
  env_set OPENAI_API_KEYS "$CLOUD_KEYS"
  env_set ENABLE_OPENAI_API "$( [ -n "$CLOUD_URLS" ] && echo true || echo false)"
  if [ "$SEARCH" = off ]; then
    env_set ENABLE_WEB_SEARCH false; env_set WEB_SEARCH_ENGINE ""
  else
    env_set ENABLE_WEB_SEARCH true; env_set WEB_SEARCH_ENGINE "$SEARCH"
  fi
  env_set BRAVE_SEARCH_API_KEY "$BRAVE_KEY"
  env_set TAVILY_API_KEY "$TAVILY_KEY"
  env_set BYPASS_WEB_SEARCH_EMBEDDING_AND_RETRIEVAL "$BYPASS"
  env_set WEB_SEARCH_RESULT_COUNT "$RESULTS"
  env_set ENABLE_PERSISTENT_CONFIG "$PERSIST"
  ok "Saved .env"
}

# ------------------------------------------------------------------ apply

check_docker() {
  if ! have docker; then
    if [ "$OS" = Darwin ]; then
      die "Docker is not installed. Install Docker Desktop (docker.com) or OrbStack (orbstack.dev), start it, then re-run."
    fi
    offer_install Docker "curl -fsSL https://get.docker.com | $SUDO sh"
  fi
  docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is missing (the 'docker compose' command)."
  if [ "$OS" = Darwin ] && ! docker info >/dev/null 2>&1; then
    local app=Docker i
    [ -d /Applications/OrbStack.app ] && app=OrbStack
    if open -a "$app" 2>/dev/null; then
      info "Starting $app (this can take a minute or two)..."
      for i in $(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 3; done
    fi
  fi
  if ! docker info >/dev/null 2>&1; then
    if [ "$OS" = Darwin ]; then
      die "Docker isn't running. Start Docker Desktop or OrbStack, then re-run."
    fi
    die "Can't talk to Docker. Start it ($SUDO systemctl enable --now docker) and make sure your user is in the docker group ($SUDO usermod -aG docker \$USER, then log out and back in)."
  fi
  ok "Docker is running"
}

ollama_up() {
  curl -fsS -m 3 http://127.0.0.1:11434/api/version >/dev/null 2>&1
}

check_native_ollama() {
  if ! have ollama; then
    if have brew; then offer_install Ollama "brew install --cask ollama"
    else die "Install Ollama from https://ollama.com/download, open it once, then re-run."; fi
  fi
  if ! ollama_up; then
    info "Starting Ollama..."
    open -a Ollama 2>/dev/null || (nohup ollama serve >/dev/null 2>&1 &)
    local i
    for i in $(seq 1 30); do ollama_up && break; sleep 1; done
    ollama_up || die "Ollama didn't start. Open the Ollama app, then re-run."
  fi
  ok "Ollama is running"
}

# Native Ollama doesn't read .env. macOS: copy the settings to the app
# environment with launchctl (lasts until reboot; setup re-applies it; empty
# in .env removes them) and restart Ollama if one changed. Linux: the
# settings belong in the ollama systemd service.
sync_native_ollama_env() {
  local k want="" changed="" i p
  if [ -n "$(env_get OLLAMA_KV_CACHE_TYPE)" ] && [ "$(env_get OLLAMA_FLASH_ATTENTION)" != 1 ]; then
    warn "OLLAMA_KV_CACHE_TYPE only works with OLLAMA_FLASH_ATTENTION=1."
  fi
  if [ "$OS" != Darwin ]; then
    for k in $OLLAMA_TUNING; do want="$want$(env_get "$k")"; done
    if [ -n "$want" ]; then
      warn "Native Ollama on Linux doesn't read .env. Add the OLLAMA_* settings to its service: $SUDO systemctl edit ollama"
    fi
    return 0
  fi
  for k in $OLLAMA_TUNING; do
    want=$(env_get "$k")
    if [ "$want" != "$(launchctl getenv "$k" 2>/dev/null)" ]; then
      if [ -n "$want" ]; then launchctl setenv "$k" "$want"; else launchctl unsetenv "$k"; fi
      changed=1
    fi
    # The `ollama serve` fallback in check_native_ollama inherits these.
    if [ -n "$want" ]; then export "$k=$want"; else unset "$k"; fi
  done
  [ -n "$changed" ] || return 0
  ok "Ollama settings applied"
  if ollama_up; then
    info "Restarting Ollama to apply them..."
    osascript -e 'quit app "Ollama"' >/dev/null 2>&1 || true
    # Model runners too: left running, they keep holding GPU memory.
    for p in ollama llama-server ollama_llama_server; do pkill -x "$p" >/dev/null 2>&1 || true; done
    for i in $(seq 1 15); do ollama_up || break; sleep 1; done
    ollama_up && warn "Couldn't stop Ollama. Quit it from the menu bar and open it again to apply them."
  fi
  return 0
}

check_gpu_runtime() {
  if [ "$1" = ollama-nvidia ] && ! docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q nvidia; then
    warn "Docker has no NVIDIA runtime. Install nvidia-container-toolkit:"
    info "https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html"
    die "Or re-run './setup.sh configure' and choose ollama-cpu."
  fi
}

run_ollama() {  # run_ollama ARGS...  (native or in the container)
  if [ "$(env_get OLLAMA_MODE)" = container ]; then docker exec ollama ollama "$@"
  else ollama "$@"; fi
}

# Python run inside the Open WebUI container, which reaches Ollama in both
# modes: loads a model, then prints its size, size in GPU memory and context.
FIT_PY="import json,os,sys,urllib.request as u; b=os.environ['OLLAMA_BASE_URL']; m=sys.argv[1]; u.urlopen(u.Request(b+'/api/generate',json.dumps({'model':m,'prompt':''}).encode()),timeout=600).read(); [print(x['size'],x['size_vram'],x.get('context_length',0)) for x in json.load(u.urlopen(b+'/api/ps',timeout=10))['models'] if x['name'] in (m,m+':latest')]"

# Loads the largest selected model and warns if part of it runs on the CPU.
check_gpu_fit() {
  local models m size best=0 pick="" out total vram ctx
  models=$(env_get OLLAMA_PULL_MODELS)
  [ -n "$models" ] || return 0
  for m in $models; do
    [ -n "$pick" ] || pick=$m
    size=$(grep -vE '^(#|$)' models.txt | awk -F'|' -v t="$m" '$1 == t { print $2 }')
    if [ -n "$size" ] && awk -v a="$size" -v b="$best" 'BEGIN { exit !(a > b) }'; then best=$size; pick=$m; fi
  done
  info "Loading $pick to check it fits in GPU memory..."
  out=$(docker exec open-webui python3 -c "$FIT_PY" "$pick" 2>/dev/null) && [ -n "$out" ] \
    || { warn "Couldn't load $pick to check its fit."; return 0; }
  set -- $out; total=$1; vram=$2; ctx=$3
  [ "$vram" -gt 0 ] || return 0
  if [ "$vram" -ge "$total" ]; then
    ok "$pick fits in GPU memory ($(awk -v t="$total" 'BEGIN { printf "%.1f", t / 1e9 }') GB with $ctx tokens of context)"
  else
    warn "$pick doesn't fit: $(awk -v t="$total" -v v="$vram" 'BEGIN { printf "%.1f of %.1f", (t - v) / 1e9, t / 1e9 }') GB runs on the CPU, so replies are slow."
    info "Lower the context length, use the q4_0 cache, or pick a smaller model: ./setup.sh configure"
  fi
}

pull_models() {
  local models have_list m
  models=$(env_get OLLAMA_PULL_MODELS)
  [ -n "$models" ] || { info "No models selected. Run './setup.sh configure' to pick some."; return 0; }
  have_list=$(run_ollama list 2>/dev/null | awk 'NR > 1 { print $1 }')
  for m in $models; do
    case "$m" in *:*) ;; *) m="$m:latest" ;; esac
    if printf '%s\n' "$have_list" | grep -qxF "$m"; then
      ok "$m already downloaded"
    else
      info "Downloading $m (this can take a while)..."
      run_ollama pull "$m" || warn "Couldn't download $m. Check the tag at https://ollama.com/library"
    fi
  done
}

wait_webui() {
  local port=$1 i
  for i in $(seq 1 90); do
    curl -fsS -m 3 "http://127.0.0.1:$port/health" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

first_admin() {
  local port=$1
  curl -fsS -m 5 "http://127.0.0.1:$port/api/config" 2>/dev/null | grep -q '"onboarding":true' || return 0
  step "Create your Open WebUI admin account"
  info "Open WebUI (the chat website) has no accounts yet. This is a new login"
  info "stored only on this computer, not your Tailscale, Docker or Ollama account."
  info "The first account becomes the admin and sign-ups close after that; you"
  info "add family members later. Create it now, before remote access is on."
  info "The email is only a login name (Open WebUI never sends mail). The admin"
  info "password guards everyone's chats, so use a strong one and save it in a"
  info "password manager. There's no 'forgot password' link."
  info ""
  if [ "$OS" = Linux ] && [ -n "${SSH_CONNECTION:-}" ] && [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    info "This looks like a remote server. From your own computer, run:"
    info "  ssh -L $port:127.0.0.1:$port <you>@<this-server>"
    info "then open http://localhost:$port in your browser."
  else
    info "Open http://localhost:$port"
    [ "$OS" = Darwin ] && open "http://localhost:$port" 2>/dev/null || true
  fi
  while true; do
    ask "Press Enter when the Open WebUI admin account exists (or type 'skip')" ""
    [ "$REPLY" = skip ] && { warn "Skipped. Create the Open WebUI admin account before sharing access."; return 0; }
    curl -fsS -m 5 "http://127.0.0.1:$port/api/config" | grep -q '"onboarding":true' || break
    warn "No account yet."
  done
  ok "Open WebUI admin account exists"
}

tailscale_bin() {
  if have tailscale; then echo tailscale
  elif [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
    echo /Applications/Tailscale.app/Contents/MacOS/Tailscale
  fi
}

setup_tailscale() {
  local port=$1 ts url
  ts=$(tailscale_bin)
  if [ -z "$ts" ]; then
    if [ "$OS" = Darwin ]; then
      have brew && offer_install Tailscale "brew install --cask tailscale" ||
        die "Install Tailscale from https://tailscale.com/download, sign in, then re-run."
      ts=$(tailscale_bin)
      [ -n "$ts" ] || die "Open the Tailscale app and sign in, then re-run."
    else
      offer_install Tailscale "curl -fsSL https://tailscale.com/install.sh | sh"
      ts=tailscale
    fi
  fi
  if ! "$ts" status >/dev/null 2>&1; then
    if [ "$OS" = Darwin ]; then
      die "Tailscale isn't connected. Open the Tailscale app, sign in, then re-run."
    fi
    info "Connecting this machine to Tailscale (follow the login link)..."
    $SUDO "$ts" up || die "tailscale up failed."
  fi
  ok "Tailscale is connected"
  info "Publishing Open WebUI to your tailnet with 'tailscale serve' (HTTPS)."
  info "If asked, enable HTTPS certificates for your tailnet using the link shown."
  # On Linux, serve needs root (or: sudo tailscale set --operator=$USER).
  $SUDO "$ts" serve --bg "$port" || die "tailscale serve failed."
  url=$("$ts" serve status 2>/dev/null | grep -o 'https://[^ ]*' | head -n 1 || true)
  TS_URL=${url:-"https://<pc-name>.<tailnet>.ts.net"}
  ok "Remote access: $TS_URL (your tailnet only)"
}

# Search results go into the model's context. Too small a context and Ollama
# drops them, so the model answers from its outdated training data.
check_search_context() {
  local ctx
  [ "$(env_get ENABLE_WEB_SEARCH)" = true ] || return 0
  ctx=$(env_get OLLAMA_CONTEXT_LENGTH)
  case "$ctx" in ''|*[!0-9]*) ctx=0 ;; esac
  [ "$ctx" -ge 16384 ] && return 0
  warn "Web search works poorly with less than 16384 tokens of context (.env has '$(env_get OLLAMA_CONTEXT_LENGTH)');"
  warn "search results get cut off. Raise OLLAMA_CONTEXT_LENGTH if the model fits: ./setup.sh configure"
}

apply() {
  [ -f "$ENV_FILE" ] || configure
  local mode profile port svc
  mode=$(env_get OLLAMA_MODE); profile=$(env_get COMPOSE_PROFILES); port=$(env_get OPEN_WEBUI_PORT)
  [ -n "$(env_get WEBUI_SECRET_KEY)" ] || env_set WEBUI_SECRET_KEY "$(gen_secret)"

  step "Checking prerequisites"
  check_docker
  if [ "$mode" = native ]; then sync_native_ollama_env; check_native_ollama; check_ollama_settings; else check_gpu_runtime "$profile"; fi
  check_search_context

  step "Starting containers"
  # Remove an Ollama container from a previously chosen profile.
  for svc in $OLLAMA_SERVICES; do
    [ "$svc" = "$profile" ] || docker compose --profile "$svc" rm -s -f "$svc" >/dev/null 2>&1 || true
  done
  docker compose pull
  docker compose up -d
  info "Waiting for Open WebUI..."
  wait_webui "$port" || die "Open WebUI didn't become healthy. See: docker compose logs open-webui"
  ok "Open WebUI is up at http://localhost:$port"

  step "Models"
  pull_models
  check_gpu_fit

  first_admin "$port"

  TS_URL=""
  if [ "$(env_get TAILSCALE_SERVE)" = true ]; then
    step "Remote access"
    setup_tailscale "$port"
  fi

  step "Done"
  info "Local:   http://localhost:$port"
  [ -n "$TS_URL" ] && info "Remote:  $TS_URL"
  info "Family:  see docs/family-access.md"
  info "Change settings: ./setup.sh configure   (or ask an AI coding CLI; see AGENTS.md)"
}

status() {
  docker compose ps
  if [ "$(env_get OLLAMA_MODE)" = native ]; then
    ollama_up && ok "Native Ollama is running" || warn "Native Ollama is not running"
  fi
  local ts; ts=$(tailscale_bin)
  [ -n "$ts" ] && "$ts" serve status 2>/dev/null || true
}

case "${1:-}" in
  "")        apply ;;
  configure) configure; apply ;;
  apply|update) apply ;;
  status)    status ;;
  stop)      docker compose down ;;
  -h|--help|help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "Unknown command '$1'. Try: ./setup.sh help" ;;
esac
