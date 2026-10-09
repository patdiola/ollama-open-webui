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

OS=$(uname -s)
case "$OS" in
  Darwin) OS_NAME=macOS ;;
  Linux)  OS_NAME=Linux
          grep -qi microsoft /proc/version 2>/dev/null &&
            warn "This looks like WSL. On Windows, run setup.cmd from Windows instead." ;;
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
  info "Web search lets models look things up online. Optional; the search"
  info "queries (not your whole chat) go to the provider you pick."
  info "  off         no web access (most private)"
  info "  duckduckgo  no account or key needed; can be rate-limited if used heavily"
  info "  brave       needs a Brave Search API key; reliable, independent index"
  info "  tavily      needs a Tavily API key; built for AI, returns cleaner results"
  info "Not sure? Pick duckduckgo, or off."
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

  step "1/6  Ollama"
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

  step "2/6  Models"
  pick_models "$(env_get OLLAMA_PULL_MODELS)"

  step "3/6  Local port"
  info "Open WebUI listens on this machine only (127.0.0.1). Keep 3000 unless"
  info "another app already uses it; then pick any free number like 3001 or 8080."
  while true; do
    ask "Port" "$(env_get OPEN_WEBUI_PORT)"
    case "$REPLY" in ''|*[!0-9]*) ;; *) PORT=$REPLY; break ;; esac
  done

  step "4/6  Remote access (Tailscale)"
  info "Tailscale lets your phone and laptop reach this machine from anywhere at"
  info "https://<pc-name>.<tailnet>.ts.net, without exposing anything to your"
  info "Wi-Fi network or the internet. It's free for personal use: create an"
  info "account at https://login.tailscale.com/start and install the app on each"
  info "device. Say no only if you'll use Open WebUI on this machine alone."
  if yesno "Set up Tailscale remote access?" "$( [ "$(env_get TAILSCALE_SERVE)" = false ] && echo n || echo y)"; then
    TS=true; else TS=false; fi

  step "5/6  Optional extras"
  configure_cloud
  configure_search

  step "6/6  Where settings live"
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
  info "Local URL:     http://localhost:$PORT"
  info "Tailscale:     $TS"
  info "Cloud APIs:    ${CLOUD_URLS:-(none)}"
  info "Web search:    $SEARCH"
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
  step "Create your admin account"
  info "No accounts exist yet. The first account becomes the admin, and"
  info "sign-ups close after that. Create it now, before remote access is on."
  info "The email is only a login name (Open WebUI never sends mail), and the"
  info "password protects every account, so use a strong one and save it in a"
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
    ask "Press Enter when the admin account exists (or type 'skip')" ""
    [ "$REPLY" = skip ] && { warn "Skipped. Create the admin account before sharing access."; return 0; }
    curl -fsS -m 5 "http://127.0.0.1:$port/api/config" | grep -q '"onboarding":true' || break
    warn "No account yet."
  done
  ok "Admin account exists"
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

apply() {
  [ -f "$ENV_FILE" ] || configure
  local mode profile port svc
  mode=$(env_get OLLAMA_MODE); profile=$(env_get COMPOSE_PROFILES); port=$(env_get OPEN_WEBUI_PORT)
  [ -n "$(env_get WEBUI_SECRET_KEY)" ] || env_set WEBUI_SECRET_KEY "$(gen_secret)"

  step "Checking prerequisites"
  check_docker
  if [ "$mode" = native ]; then check_native_ollama; else check_gpu_runtime "$profile"; fi

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
