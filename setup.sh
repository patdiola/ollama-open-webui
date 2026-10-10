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
OLLAMA_TUNING="OLLAMA_MODELS OLLAMA_CONTEXT_LENGTH OLLAMA_FLASH_ATTENTION OLLAMA_KV_CACHE_TYPE OLLAMA_KEEP_ALIVE"

# ------------------------------------------------------------------ helpers

# Terminal UI. With a terminal attached, questions are arrow-key menus,
# checklists and toggles; without one (piped input, CI) every question falls
# back to a plain prompt, so setup still works unattended.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C0=$'\033[0m'; CB=$'\033[1m'; CD=$'\033[2m'; CC=$'\033[36m'; CG=$'\033[32m'; CY=$'\033[33m'; CR=$'\033[31m'
else
  C0=""; CB=""; CD=""; CC=""; CG=""; CY=""; CR=""
fi
TTY_UI=""
if [ -t 1 ] && { : </dev/tty; } 2>/dev/null; then
  TTY_UI=1
  trap 'printf "\033[?25h"' EXIT
  trap 'printf "\033[?25h\n"; exit 130' INT
fi
COLS=$( { [ -n "$TTY_UI" ] && tput cols 2>/dev/null; } || echo 80)

bold() { printf '%s%s%s\n' "$CB" "$*" "$C0"; }
info() { printf '  %s\n' "$*"; }
note() { printf '  %s%s%s\n' "$CD" "$*" "$C0"; }
ok()   { printf '  %s✓%s %s\n' "$CG" "$C0" "$*"; }
warn() { printf '  %s!%s %s\n' "$CY" "$C0" "$*" >&2; }
die()  { printf '\n  %sError:%s %s\n' "$CR" "$C0" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# step "Title"  -> section header, with space around it
step() {
  printf '\n\n  %s%s%s\n  %s────────────────────────────────────────────────────────────%s\n\n' \
    "$CB$CC" "$*" "$C0" "$CD" "$C0"
}

# ask "Question" default  -> $REPLY
ask() {
  local hint=""
  [ -n "$2" ] && hint=" $CD($2)$C0"
  REPLY=""; read -r -p "  $CC?$C0 $1$hint: " REPLY 2>/dev/null </dev/tty || REPLY=""
  [ -z "$REPLY" ] && REPLY="$2"
  return 0
}

# ask_secret "Question"  -> $REPLY (not echoed)
ask_secret() {
  REPLY=""; read -r -s -p "  $CC?$C0 $1: " REPLY 2>/dev/null </dev/tty || REPLY=""
  printf '\n'
}

# read_key  -> $KEY: up, down, left, right, enter, space, tab, or the character
read_key() {
  local k rest
  IFS= read -rsn1 k 2>/dev/null </dev/tty || k=""
  if [ "$k" = $'\033' ]; then
    IFS= read -rsn2 rest 2>/dev/null </dev/tty || rest=""
    case "$rest" in '[A') k=up ;; '[B') k=down ;; '[C') k=right ;; '[D') k=left ;; *) k=esc ;; esac
  fi
  case "$k" in '') k=enter ;; ' ') k=space ;; $'\t') k=tab ;; esac
  KEY=$k
}

# yesno "Question" y|n  -> exit status. Left/right (or y/n), Enter confirms.
yesno() {
  local q=$1 sel=$2
  if [ -z "$TTY_UI" ]; then
    local hint="y/N"
    [ "$sel" = y ] && hint="Y/n"
    while true; do
      REPLY=""; read -r -p "  ? $q [$hint]: " REPLY 2>/dev/null </dev/tty || REPLY=""
      case "${REPLY:-$sel}" in [Yy]*) return 0 ;; [Nn]*) return 1 ;; esac
    done
  fi
  printf '\033[?25l'
  while true; do
    if [ "$sel" = y ]; then
      printf '\r\033[2K  %s?%s %s   %s❯ Yes%s   %sNo%s ' "$CC" "$C0" "$q" "$CB$CC" "$C0" "$CD" "$C0"
    else
      printf '\r\033[2K  %s?%s %s   %sYes%s   %s❯ No%s ' "$CC" "$C0" "$q" "$CD" "$C0" "$CB$CC" "$C0"
    fi
    read_key
    case "$KEY" in
      left|right|tab|h|l) [ "$sel" = y ] && sel=n || sel=y ;;
      y|Y) sel=y; break ;;
      n|N) sel=n; break ;;
      enter) break ;;
    esac
  done
  printf '\r\033[2K  %s✓%s %s %s%s%s\n\033[?25h' "$CG" "$C0" "$q" "$CB" "$( [ "$sel" = y ] && echo Yes || echo No)" "$C0"
  [ "$sel" = y ]
}

# menu_line SELECTED MARK LABEL HINT  (one row of choose/checklist, cut to fit)
menu_line() {
  local label=${3:0:34} hint=$4 room=$((COLS - 44))
  [ "$room" -lt 10 ] && room=10
  [ "${#hint}" -gt "$room" ] && hint="${hint:0:$((room - 1))}…"
  if [ "$1" = 1 ]; then
    printf '\033[2K  %s❯ %s%-34s%s %s%s%s\n' "$CB$CC" "$2" "$label" "$C0" "$CD" "$hint" "$C0"
  else
    printf '\033[2K    %s%-34s %s%s%s\n' "$2" "$label" "$CD" "$hint" "$C0"
  fi
}

# choose "Question" DEFAULT "value|label|hint" ...  -> $REPLY (the value)
choose() {
  local q=$1 def=$2 n=0 sel=0 i it
  shift 2
  local vals=() labels=() hints=()
  for it in "$@"; do
    vals[n]=${it%%|*}; it=${it#*|}; labels[n]=${it%%|*}; hints[n]=${it#*|}
    [ "${vals[n]}" = "$def" ] && sel=$n
    n=$((n + 1))
  done
  if [ -z "$TTY_UI" ]; then
    printf '  ? %s\n' "$q"
    for ((i = 0; i < n; i++)); do printf '     %d) %-30s %s\n' $((i + 1)) "${labels[i]}" "${hints[i]}"; done
    while true; do
      REPLY=""; read -r -p "     Choice [$((sel + 1))]: " REPLY 2>/dev/null </dev/tty || REPLY=""
      i=${REPLY:-$((sel + 1))}
      case "$i" in ''|*[!0-9]*) continue ;; esac
      if [ "$i" -ge 1 ] && [ "$i" -le "$n" ]; then REPLY=${vals[i - 1]}; return 0; fi
    done
  fi
  printf '  %s?%s %s  %s↑/↓ to move, Enter to choose%s\n\033[?25l' "$CC" "$C0" "$q" "$CD" "$C0"
  while true; do
    for ((i = 0; i < n; i++)); do menu_line "$( [ "$i" -eq "$sel" ] && echo 1 || echo 0)" "" "${labels[i]}" "${hints[i]}"; done
    read_key
    case "$KEY" in
      up|k) sel=$(( (sel + n - 1) % n )) ;;
      down|j|tab) sel=$(( (sel + 1) % n )) ;;
      [1-9]) [ "$KEY" -le "$n" ] && sel=$((KEY - 1)) ;;
      enter) break ;;
    esac
    printf '\033[%dA' "$n"
  done
  printf '\033[%dA\033[J  %s✓%s %s %s%s%s\n\033[?25h' $((n + 1)) "$CG" "$C0" "$q" "$CB" "${labels[sel]}" "$C0"
  REPLY=${vals[sel]}
}

# checklist "Question" "preselected values" "value|label|hint" ...
#   -> $REPLY: ticked values, space-separated, in list order
checklist() {
  local q=$1 pre=" $2 " n=0 sel=0 i it out="" names=""
  shift 2
  local vals=() labels=() hints=() on=()
  for it in "$@"; do
    vals[n]=${it%%|*}; it=${it#*|}; labels[n]=${it%%|*}; hints[n]=${it#*|}
    case "$pre" in *" ${vals[n]} "*) on[n]=1 ;; *) on[n]=0 ;; esac
    n=$((n + 1))
  done
  if [ -z "$TTY_UI" ]; then
    while true; do
      printf '  ? %s\n' "$q"
      for ((i = 0; i < n; i++)); do
        printf '     %2d) [%s] %-28s %s\n' $((i + 1)) "$( [ "${on[i]}" = 1 ] && echo x || echo ' ')" "${labels[i]}" "${hints[i]}"
      done
      REPLY=""; read -r -p "     Numbers to tick or untick, Enter when done: " REPLY 2>/dev/null </dev/tty || REPLY=""
      [ -n "$REPLY" ] || break
      for i in $REPLY; do
        case "$i" in *[!0-9]*) continue ;; esac
        [ "$i" -ge 1 ] && [ "$i" -le "$n" ] && on[i - 1]=$((1 - on[i - 1]))
      done
    done
  else
    printf '  %s?%s %s  %s↑/↓ to move, Space to tick, Enter when done%s\n\033[?25l' "$CC" "$C0" "$q" "$CD" "$C0"
    while true; do
      for ((i = 0; i < n; i++)); do
        menu_line "$( [ "$i" -eq "$sel" ] && echo 1 || echo 0)" "$( [ "${on[i]}" = 1 ] && printf '%s[x]%s ' "$CG" "$C0$( [ "$i" -eq "$sel" ] && printf '%s' "$CB$CC")" || echo '[ ] ')" "${labels[i]}" "${hints[i]}"
      done
      read_key
      case "$KEY" in
        up|k) sel=$(( (sel + n - 1) % n )) ;;
        down|j|tab) sel=$(( (sel + 1) % n )) ;;
        space|x) on[sel]=$((1 - on[sel])) ;;
        enter) break ;;
      esac
      printf '\033[%dA' "$n"
    done
  fi
  for ((i = 0; i < n; i++)); do
    [ "${on[i]}" = 1 ] || continue
    out="$out ${vals[i]}"; names="$names, ${labels[i]}"
  done
  names=${names#, }
  if [ -n "$TTY_UI" ]; then
    printf '\033[%dA\033[J  %s✓%s %s %s%s%s\n\033[?25h' $((n + 1)) "$CG" "$C0" "$q" "$CB" "${names:-none}" "$C0"
  fi
  REPLY=${out# }
}

# open_url URL  -> opens it in the browser; fails if there is no desktop
open_url() {
  if [ "$OS" = Darwin ]; then open "$1" 2>/dev/null
  elif [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && have xdg-open; then xdg-open "$1" >/dev/null 2>&1 &
  else return 1; fi
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
  local current="$1" default="" in_use="" list="" d names count gb items=() hint def TILDE="~"
  # macOS runs Ollama natively; Linux runs it in Docker.
  if [ "$OS" = Darwin ]; then
    default="$HOME/.ollama/models"
    in_use=$(ollama_in_use OLLAMA_MODELS | sed 's#/*$##') || in_use=""
  fi
  note "Looking for models Ollama already downloaded on this computer..."
  list=$( { [ -n "$default" ] && echo "$default"; [ -n "$in_use" ] && echo "$in_use"; [ -n "$current" ] && echo "$current"; find_model_stores; } \
    | sed 's#/*$##' | awk 'NF && !seen[$0]++')
  [ -z "$default" ] && items[${#items[@]}]="|Inside Docker|Docker's own storage (default)"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    names=$(store_models "$d")
    if [ -n "$names" ]; then
      count=$(printf '%s\n' "$names" | wc -l | tr -d ' ')
      gb=$(du -sk "$d/blobs" 2>/dev/null | awk '{ printf "%.0f", $1 / 1048576 }')
      hint="$count models, ${gb:-0} GB: $(printf '%s\n' "$names" | head -n 3 | paste -sd, - | sed 's/,/, /g')"
    else
      hint="empty"
    fi
    [ "$d" = "$in_use" ] && hint="Ollama uses this now · $hint"
    [ "$d" = "$default" ] && [ "$d" != "$in_use" ] && hint="Ollama's default · $hint"
    items[${#items[@]}]="$d|${d/#$HOME/$TILDE}|$hint"
  done <<EOF
$list
EOF
  items[${#items[@]}]="other|Another folder...|type a path; created if missing"
  info "Models take 2-65 GB each. Pick a drive with room, or a folder that"
  info "already holds models so they aren't downloaded again."
  note "Free space in your home folder: $(df -Pk "$HOME" | awk 'NR == 2 { printf "%.0f GB", $4 / 1048576 }')"
  printf '\n'
  def=${current:-${in_use:-$default}}
  choose "Where should models live?" "$def" "${items[@]}"
  d=$REPLY
  if [ "$d" = other ]; then
    while true; do
      ask "Folder path" ""
      d=$REPLY
      case "$d" in "~"/*) d="$HOME/${d#"~"/}" ;; esac
      d=$(printf '%s' "$d" | sed 's#/*$##')
      case "$d" in /*) break ;; esac
      warn "Enter a full path, like /Volumes/Big/ollama."
    done
  fi
  [ "$d" = "$default" ] && d=""
  MODELS_DIR=$d
}

# in_catalog TAG  -> true if TAG is listed in models.txt
in_catalog() { awk -F'|' -v t="$1" '$1 == t { f = 1 } END { exit !f }' models.txt; }

# Asks which models to download -> $MODELS (default chat model first)
pick_models() {
  local current=" $1 " mem budget desc tag size note fit items=() pre="" extra="" m best="" bestsize=0 default
  mem=$(detect_memory); budget=${mem%%|*}; desc=${mem#*|}
  info "Detected: $desc."
  info "Models marked ${CG}fits${C0} run fully on this machine's GPU and are fast;"
  info "bigger ones still work, just slowly. Each takes its size in disk space."
  printf '\n'
  while IFS='|' read -r tag size note; do
    case "$tag" in ''|\#*) continue ;; esac
    if awk -v s="$size" -v b="$budget" 'BEGIN { exit !(s * 1.2 <= b) }'; then
      fit="fits"
      awk -v s="$size" -v b="$bestsize" 'BEGIN { exit !(s > b) }' && { best=$tag; bestsize=$size; }
    else
      fit="too big"
    fi
    items[${#items[@]}]="$tag|$tag|$size GB · $fit · $note"
    case "$current" in *" $tag "*) pre="$pre $tag" ;; esac
  done < models.txt
  # Keep tags typed earlier that aren't in the catalog.
  for m in $current; do in_catalog "$m" || extra="$extra $m"; done
  [ -n "$pre$extra" ] || pre=$best
  checklist "Models to download" "$pre" "${items[@]}"
  MODELS=$REPLY
  printf '\n'
  note "Any other model from ollama.com/library? Type its tag (e.g. mistral-small3.2),"
  note "space-separated, or press Enter to skip."
  ask "Other models" "$(echo $extra)"
  MODELS=$(printf '%s\n' $MODELS $REPLY | awk 'NF && !seen[$0]++' | paste -sd' ' -)
  [ -n "$MODELS" ] || { warn "No models selected; you can add some later with ./setup.sh configure."; return 0; }
  set -- $MODELS
  if [ $# -gt 1 ]; then
    default=$(env_get DEFAULT_MODELS)
    case " $MODELS " in *" $default "*) ;; *) default=$1 ;; esac
    items=()
    for m in $MODELS; do items[${#items[@]}]="$m|$m|$(awk -F'|' -v t="$m" '$1 == t { print $3 }' models.txt)"; done
    printf '\n'
    choose "Which model should new chats start with?" "$default" "${items[@]}"
    MODELS="$REPLY $(printf '%s\n' $MODELS | grep -vxF "$REPLY" | paste -sd' ' -)"
    MODELS=$(echo $MODELS)
  fi
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
  local search=$1 mem budget m size largest=0 largest_tag="" left suggest def cur items=() c
  mem=$(detect_memory); budget=${mem%%|*}
  for m in $MODELS; do
    size=$(grep -vE '^(#|$)' models.txt | awk -F'|' -v t="$m" '$1 == t { print $2 }')
    [ -n "$size" ] || continue
    if awk -v a="$size" -v b="$largest" 'BEGIN { exit !(a > b) }'; then largest=$size; largest_tag=$m; fi
  done
  left=$(awk -v b="$budget" -v l="$largest" 'BEGIN { printf "%.1f", b * 0.9 - l }')
  info "Besides the model, Ollama keeps the conversation (its \"context\") in GPU"
  info "memory. If both don't fit, part of the model runs on the CPU and replies"
  info "get much slower, so setup leaves headroom."
  printf '\n'
  note "Memory for models   $budget GB (10% kept free for the desktop and other apps)"
  [ -n "$largest_tag" ] && note "Largest model       $largest_tag, about $largest GB"
  note "Left for context    about $left GB"
  cur=$(ollama_in_use OLLAMA_CONTEXT_LENGTH) && [ -n "$cur" ] && note "Ollama uses now     $cur tokens"
  printf '\n'
  def=y; [ "$(env_get OLLAMA_FLASH_ATTENTION)" = 0 ] && def=n
  if yesno "Use flash attention? (faster, less memory; recommended)" "$def"; then
    FA=1
    def=$(env_get OLLAMA_KV_CACHE_TYPE)
    [ -n "$def" ] || { [ "$search" = true ] && def=q4_0 || def=q8_0; }
    choose "Context precision" "$def" \
      "q4_0|4-bit$( [ "$search" = true ] && echo ' (recommended)')|a quarter of the memory: twice the room for search results" \
      "q8_0|8-bit$( [ "$search" = true ] || echo ' (recommended)')|half the memory; recalls long chats a bit more exactly"
    KV=$REPLY
  else
    FA=0; KV=""
  fi
  suggest=$(context_suggestion "$left" "$KV")
  cur=$(env_get OLLAMA_CONTEXT_LENGTH)
  items=("$suggest|$suggest tokens (recommended)|the most that fits with headroom")
  for c in $((suggest / 2)) $((suggest / 4)); do
    [ "$c" -ge 4096 ] && items[${#items[@]}]="$c|$c tokens|safer if other apps use the GPU"
  done
  if [ -n "$cur" ] && ! printf '%s\n' "${items[@]}" | grep -q "^$cur|"; then
    items[${#items[@]}]="$cur|$cur tokens (current)|your current setting"
  fi
  items[${#items[@]}]="0|Let Ollama decide|its default for this GPU"
  items[${#items[@]}]="other|Another size...|type a number of tokens"
  printf '\n'
  [ "$search" = true ] && note "Web search needs 16384 or more; with 65536 or more it reads whole pages."
  choose "Context length" "${cur:-$suggest}" "${items[@]}"
  CTX=$REPLY
  if [ "$CTX" = other ]; then
    while true; do
      ask "Context length in tokens" "$suggest"
      case "$REPLY" in ''|*[!0-9]*) ;; *) CTX=$REPLY; break ;; esac
    done
  fi
  [ "$CTX" = 0 ] && CTX=""
  return 0
}

configure_cloud() {
  local urls keys n url key
  urls=$(env_get OPENAI_API_BASE_URLS); keys=$(env_get OPENAI_API_KEYS)
  info "Cloud models (GPT, Claude, Gemini, ...) are smarter than any model this"
  info "PC can run, but chats sent to them leave your machine and cost money per"
  info "use. Local models stay private. You can add a cloud model later."
  printf '\n'
  if [ -n "$urls" ]; then
    n=$(printf '%s' "$urls" | awk -F';' '{ print NF }')
    if yesno "Keep your $n cloud connection(s)?" y; then CLOUD_URLS=$urls; CLOUD_KEYS=$keys; return 0; fi
  fi
  CLOUD_URLS=""; CLOUD_KEYS=""
  yesno "Add a cloud model provider?" n || return 0
  while true; do
    printf '\n'
    choose "Provider" openrouter \
      "openrouter|OpenRouter|one key for Claude, GPT, Gemini and more" \
      "openai|OpenAI|GPT models, directly from OpenAI" \
      "other|Other|any OpenAI-compatible API (Groq, Together, ...)"
    case "$REPLY" in
      openai) url=https://api.openai.com/v1
              note "Key: https://platform.openai.com/api-keys > Create new secret key (starts with sk-)."
              note "API use is billed separately from ChatGPT; add credit under Settings > Billing." ;;
      openrouter) url=https://openrouter.ai/api/v1
              note "Key: https://openrouter.ai/keys > Create Key (starts with sk-or-)."
              note "Add credit at https://openrouter.ai/credits." ;;
      other)  note "Find the base URL in the provider's API docs (often ends in /v1)."
              ask "Base URL" ""; url=$REPLY ;;
    esac
    [ -n "$url" ] || continue
    ask_secret "Paste the API key (hidden; saved only in .env)"; key=$REPLY
    [ -n "$key" ] || { warn "No key entered; skipped."; continue; }
    case "$key" in *';'*) warn "Keys can't contain ';'. Skipped."; continue ;; esac
    if [ -z "$CLOUD_URLS" ]; then CLOUD_URLS=$url; CLOUD_KEYS=$key
    else CLOUD_URLS="$CLOUD_URLS;$url"; CLOUD_KEYS="$CLOUD_KEYS;$key"; fi
    ok "Added $url"
    yesno "Add another provider?" n || break
  done
}

# key_ok KEY  -> true if KEY looks like an API key (safe to put in a curl config)
key_ok() { case "$1" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac; }

# check_tavily KEY / check_serpapi KEY -> 0 works ($KEY_INFO says how much is
# left), 1 rejected, 2 couldn't check. Neither uses up a search. Keys go to
# curl on stdin, so they never show in the process list.
check_tavily() {
  local out code plan used limit
  key_ok "$1" || return 1
  out=$(printf 'header = "Authorization: Bearer %s"\n' "$1" | curl -sS -m 15 -K - -w '\n%{http_code}' https://api.tavily.com/usage 2>/dev/null) || return 2
  code=${out##*$'\n'}; out=${out%$'\n'*}
  case "$code" in 200) ;; 401|403) return 1 ;; *) return 2 ;; esac
  plan=$(printf '%s' "$out" | sed -n 's/.*"current_plan": *"\([^"]*\)".*/\1/p')
  used=$(printf '%s' "$out" | sed -n 's/.*"plan_usage": *\([0-9]*\).*/\1/p')
  limit=$(printf '%s' "$out" | sed -n 's/.*"plan_limit": *\([0-9]*\).*/\1/p')
  KEY_INFO="${plan:-Tavily} plan"
  [ -n "$limit" ] && KEY_INFO="$KEY_INFO, $((limit - ${used:-0})) of $limit searches left this month"
  return 0
}
check_serpapi() {
  local out code plan left per
  key_ok "$1" || return 1
  out=$(printf 'data-urlencode = "api_key=%s"\n' "$1" | curl -sS -m 15 -G -K - -w '\n%{http_code}' https://serpapi.com/account.json 2>/dev/null) || return 2
  code=${out##*$'\n'}; out=${out%$'\n'*}
  case "$code" in 200) ;; 401|403) return 1 ;; *) return 2 ;; esac
  plan=$(printf '%s' "$out" | sed -n 's/.*"plan_name": *"\([^"]*\)".*/\1/p')
  left=$(printf '%s' "$out" | sed -n 's/.*"total_searches_left": *\([0-9]*\).*/\1/p')
  per=$(printf '%s' "$out" | sed -n 's/.*"searches_per_month": *\([0-9]*\).*/\1/p')
  KEY_INFO="${plan:-SerpAPI}"
  [ -n "$left" ] && KEY_INFO="$KEY_INFO, $left of ${per:-?} searches left this month"
  return 0
}

# search_key tavily|serpapi  -> $REPLY: a working key, or "" if skipped
search_key() {
  local p=$1 name cur signup free how key rc def=open
  case "$p" in
    tavily)  name=Tavily; cur=$TAVILY_KEY; signup=https://app.tavily.com
             free="1,000 searches a month"; how="Copy the API key from the overview page (starts with tvly-)." ;;
    serpapi) name=SerpAPI; cur=$SERPAPI_KEY; signup=https://serpapi.com/users/sign_up
             free="250 searches a month"; how="Copy the whole key from https://serpapi.com/manage-api-key." ;;
  esac
  printf '\n  %s%s%s  %sfree plan: %s%s\n' "$CB" "$name" "$C0" "$CD" "$free" "$C0"
  if [ -n "$cur" ]; then
    rc=0; check_$p "$cur" || rc=$?
    case $rc in
      0) ok "Saved key works: $KEY_INFO"; REPLY=$cur; return 0 ;;
      2) warn "Couldn't reach $name to check the saved key; keeping it."; REPLY=$cur; return 0 ;;
      *) warn "$name rejects the saved key; let's replace it." ;;
    esac
  fi
  info "1. Create a free account: $signup"
  info "2. $how"
  [ "$OS" = Darwin ] || [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || def=paste
  while true; do
    choose "$name key" "$def" \
      "open|Open the sign-up page|in your browser, then paste the key here" \
      "paste|Paste a key|I already have one" \
      "skip|Skip for now|add it later with ./setup.sh configure"
    case "$REPLY" in
      skip) REPLY=""; return 0 ;;
      open) open_url "$signup" && note "Opened $signup" || note "Open $signup in your browser." ;;
    esac
    ask_secret "Paste the $name key (hidden)"
    key=$(printf '%s' "$REPLY" | tr -d '[:space:]')
    def=paste
    # Nothing pasted: offer Skip next, so Enter moves on (and unattended runs end).
    [ -n "$key" ] || { def=skip; continue; }
    rc=0; check_$p "$key" || rc=$?
    case $rc in
      0) ok "$name key works: $KEY_INFO"; REPLY=$key; return 0 ;;
      2) warn "Couldn't reach $name to check the key; saving it anyway."; REPLY=$key; return 0 ;;
      *) warn "$name rejected that key. Copy the whole key and try again." ;;
    esac
  done
}

configure_search() {
  local cur
  cur=$(env_get WEB_SEARCH_ENGINE)
  [ "$cur" = external ] && cur=auto
  [ "$(env_get ENABLE_WEB_SEARCH)" = true ] || cur=off
  BRAVE_KEY=$(env_get BRAVE_SEARCH_API_KEY); TAVILY_KEY=$(env_get TAVILY_API_KEY); SERPAPI_KEY=$(env_get SERPAPI_API_KEY)
  info "Web search lets the model look things up instead of guessing from"
  info "training data that is months or years old. It's what makes answers about"
  info "new software, products, prices and news right."
  printf '\n'
  info "${CB}Recommended: two free accounts, about 5 minutes.${C0}"
  info "  ${CB}Tavily${C0}    search built for AI; returns the useful part of each page"
  info "  ${CB}SerpAPI${C0}   Google results"
  info "Auto uses Tavily, switches to SerpAPI if Tavily fails or runs out of"
  info "searches, then to DuckDuckGo. DuckDuckGo needs no account but often"
  info "returns weak results, and answers suffer for it."
  note "Only the search terms the model writes are sent; your chats stay here."
  printf '\n'
  choose "Web search" "${cur:-auto}" \
    "auto|Auto (recommended)|Tavily, then SerpAPI, then DuckDuckGo" \
    "tavily|Tavily only|free account" \
    "serpapi|SerpAPI only|free account; Google results" \
    "brave|Brave Search|needs a Brave Search API key" \
    "duckduckgo|DuckDuckGo only|no account; weaker results" \
    "off|Off|no web access (most private)"
  SEARCH=$REPLY
  case "$SEARCH" in
    auto)
      search_key tavily; TAVILY_KEY=$REPLY
      search_key serpapi; SERPAPI_KEY=$REPLY
      [ -n "$TAVILY_KEY$SERPAPI_KEY" ] || { printf '\n'; warn "No keys yet, so Auto uses DuckDuckGo. Add keys any time: ./setup.sh configure"; } ;;
    tavily)
      search_key tavily; TAVILY_KEY=$REPLY
      [ -n "$TAVILY_KEY" ] || { warn "No Tavily key, so using DuckDuckGo instead."; SEARCH=duckduckgo; } ;;
    serpapi)
      search_key serpapi; SERPAPI_KEY=$REPLY
      [ -n "$SERPAPI_KEY" ] || { warn "No SerpAPI key, so using DuckDuckGo instead."; SEARCH=duckduckgo; } ;;
    brave)
      if [ -z "$BRAVE_KEY" ] || ! yesno "Keep the saved Brave key?" y; then
        note "Key: https://api-dashboard.search.brave.com > API Keys (see brave.com/search/api for plans)."
        ask_secret "Paste the Brave Search API key (hidden)"; BRAVE_KEY=$REPLY
      fi ;;
  esac
}

# summary_row "Label" "value"
summary_row() { printf '  %s%-16s%s %s\n' "$CD" "$1" "$C0" "$2"; }

configure() {
  local profile="" detected port searchtext
  printf '\n  %sOpen WebUI + Ollama setup%s  %s%s%s\n' "$CB$CC" "$C0" "$CD" "$OS_NAME" "$C0"
  note "A private ChatGPT-style assistant on your own hardware."
  [ -n "$TTY_UI" ] && note "Use the arrow keys and Enter to choose, Space to tick boxes. Ctrl+C quits."
  note "Nothing changes until you confirm at the end."

  step "1 of 7 · Ollama"
  if [ "$OS" = Darwin ]; then
    MODE=native
    info "On macOS, Ollama runs as a native app so it can use the GPU."
  else
    MODE=container
    detected=$(detect_profile)
    profile=$(env_get COMPOSE_PROFILES); [ -n "$profile" ] || profile=$detected
    info "On Linux, Ollama runs in Docker. Which hardware should it use?"
    printf '\n'
    choose "Hardware" "$profile" \
      "ollama-nvidia|NVIDIA GPU|needs nvidia-container-toolkit$( [ "$detected" = ollama-nvidia ] && echo ' · detected')" \
      "ollama-amd|AMD GPU (ROCm)|Radeon cards supported by ROCm$( [ "$detected" = ollama-amd ] && echo ' · detected')" \
      "ollama-cpu|CPU only|works anywhere, but slowly$( [ "$detected" = ollama-cpu ] && echo ' · detected')"
    profile=$REPLY
  fi

  step "2 of 7 · Models"
  pick_model_folder "$(env_get OLLAMA_MODELS)"
  printf '\n'
  pick_models "$(env_get OLLAMA_PULL_MODELS)"

  step "3 of 7 · Web search"
  configure_search

  step "4 of 7 · GPU memory"
  configure_memory "$( [ "$SEARCH" = off ] && echo false || echo true)"
  # Whole pages give better answers but need room: 4 pages plus the chat.
  BYPASS=false; RESULTS=5
  if [ "$SEARCH" != off ] && [ "${CTX:-0}" -ge 65536 ]; then BYPASS=true; RESULTS=4; fi

  step "5 of 7 · Remote access"
  info "Tailscale lets your phone and laptop reach this machine from anywhere at"
  info "https://<pc-name>.<tailnet>.ts.net, without exposing it to your Wi-Fi"
  info "network or the internet. It's free for personal use: create an account at"
  info "https://login.tailscale.com/start and install the app on each device."
  printf '\n'
  if yesno "Set up Tailscale remote access?" "$( [ "$(env_get TAILSCALE_SERVE)" = false ] && echo n || echo y)"; then
    TS=true; else TS=false; fi

  step "6 of 7 · Cloud models (optional)"
  configure_cloud

  step "7 of 7 · Final details"
  info "Open WebUI listens on this machine only (127.0.0.1). Keep 3000 unless"
  info "another app uses it."
  while true; do
    ask "Port" "$(env_get OPEN_WEBUI_PORT)"
    case "$REPLY" in ''|*[!0-9]*) ;; *) PORT=$REPLY; break ;; esac
  done
  printf '\n'
  choose "Where should settings live?" "$( [ "$(env_get ENABLE_PERSISTENT_CONFIG)" = true ] && echo true || echo false)" \
    "false|.env file (recommended)|edit .env or ask an AI CLI; re-applied on every start" \
    "true|Admin Panel|.env only sets things up once; then manage settings in the web UI"
  PERSIST=$REPLY
  printf '\n'
  note "API keys let scripts and tools use Open WebUI as your account."
  if yesno "Allow API keys? (only needed for scripts and tools)" "$( [ "$(env_get ENABLE_API_KEYS)" = true ] && echo y || echo n)"; then
    API_KEYS=true; else API_KEYS=false; fi

  case "$SEARCH" in
    auto) searchtext="Auto: "
          [ -z "$TAVILY_KEY" ] || searchtext="${searchtext}Tavily → "
          [ -z "$SERPAPI_KEY" ] || searchtext="${searchtext}SerpAPI → "
          searchtext="${searchtext}DuckDuckGo" ;;
    off)  searchtext="off" ;;
    *)    searchtext=$SEARCH ;;
  esac
  step "Summary"
  summary_row "Ollama" "$MODE${profile:+ ($profile)}"
  summary_row "Models" "${MODELS:-(none)}"
  [ -n "$MODELS" ] && summary_row "Chats start with" "${MODELS%% *}"
  summary_row "Model folder" "${MODELS_DIR:-$( [ "$MODE" = native ] && echo "Ollama's default" || echo "inside Docker")}"
  summary_row "Context" "${CTX:-Ollama default}$( [ "$FA" = 1 ] && echo " tokens, flash attention, $KV cache")"
  summary_row "Web search" "$searchtext"
  summary_row "Remote access" "$( [ "$TS" = true ] && echo 'Tailscale (tailnet only)' || echo 'this machine only')"
  summary_row "Cloud models" "${CLOUD_URLS:-(none)}"
  summary_row "Local URL" "http://localhost:$PORT"
  summary_row "Settings from" "$( [ "$PERSIST" = false ] && echo .env || echo 'Admin Panel')"
  summary_row "API keys" "$( [ "$API_KEYS" = true ] && echo allowed || echo off)"
  printf '\n'
  yesno "Save these settings and start?" y || die "Nothing saved."

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
  env_set DEFAULT_MODELS "${MODELS%% *}"
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
    env_set ENABLE_WEB_SEARCH true; env_set WEB_SEARCH_ENGINE "$( [ "$SEARCH" = auto ] && echo external || echo "$SEARCH")"
  fi
  env_set BRAVE_SEARCH_API_KEY "$BRAVE_KEY"
  env_set TAVILY_API_KEY "$TAVILY_KEY"
  env_set SERPAPI_API_KEY "$SERPAPI_KEY"
  env_set BYPASS_WEB_SEARCH_EMBEDDING_AND_RETRIEVAL "$BYPASS"
  env_set WEB_SEARCH_RESULT_COUNT "$RESULTS"
  env_set ENABLE_PERSISTENT_CONFIG "$PERSIST"
  env_set ENABLE_API_KEYS "$API_KEYS"
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
