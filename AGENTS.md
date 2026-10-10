# Instructions for AI coding agents

This repo runs Open WebUI + Ollama with Docker Compose on macOS, Windows or
Linux, reachable remotely only through Tailscale. Users ask agents to change
their configuration after running setup. This file is the contract.

## Hard rules

1. **Personal settings and secrets go in `.env` only.** Never write keys,
   hostnames, IPs, emails, usernames or home paths into any tracked file.
   This repo is public.
2. **Never print secret values** (`WEBUI_SECRET_KEY`, `OPENAI_API_KEYS`,
   `*_API_KEY`) in your replies or command output. Refer to them by name. To
   check one is set, test for non-empty without echoing it.
3. **Don't weaken the defaults** in [PRIVACY_SECURITY.md](PRIVACY_SECURITY.md):
   127.0.0.1 binds, admin chat access/export off, image allowlist, no host
   networking/privileged/Docker socket. If the user asks for something that
   conflicts, explain the risk and let them decide; then change only their
   `.env`, never the tracked defaults.
4. **Don't commit or push** unless asked. Before any commit, run
   `python3 scripts/privacy_gate.py --all`. Never bypass the gate.
5. Never run `tailscale funnel`. Remote access is `tailscale serve` (tailnet only).

## How to change settings

Edit `.env` (create it with `./setup.sh` / `setup.cmd` if it doesn't exist),
then apply with `./setup.sh` (macOS/Linux) or `setup.cmd` (Windows). Applying
recreates containers, pulls missing models and refreshes `tailscale serve`.
For a quick restart without pulls: `docker compose up -d`.

Every option is documented in [.env.example](.env.example). Common requests:

| Request | `.env` change |
| --- | --- |
| Add/remove models | `OLLAMA_PULL_MODELS` (space-separated Ollama tags). Removing a tag doesn't delete the model; run `ollama rm <tag>` (native) or `docker exec ollama ollama rm <tag>` (container) |
| Cloud provider | append to `OPENAI_API_BASE_URLS` and `OPENAI_API_KEYS` (`;`-separated, same order), set `ENABLE_OPENAI_API=true` |
| Web search | `ENABLE_WEB_SEARCH=true`, `WEB_SEARCH_ENGINE=duckduckgo\|brave\|tavily`, plus `BRAVE_SEARCH_API_KEY` or `TAVILY_API_KEY`. Needs `OLLAMA_CONTEXT_LENGTH` of 16384+ or results get cut off. Tuning: `WEB_SEARCH_RESULT_COUNT`, `BYPASS_WEB_SEARCH_EMBEDDING_AND_RETRIEVAL` |
| Port | `OPEN_WEBUI_PORT`; then re-run setup so `tailscale serve` points at it |
| Model folder | `OLLAMA_MODELS` (host path; empty = Ollama's default, or the Docker volume in container mode). The Ollama app's own Model location / Context length settings can override `.env`; setup warns when they differ |
| Quantization / GPU memory | pick a quantized tag in `OLLAMA_PULL_MODELS` (e.g. `qwen3:14b-q8_0`); `OLLAMA_CONTEXT_LENGTH`, `OLLAMA_FLASH_ATTENTION=1`, `OLLAMA_KV_CACHE_TYPE=q8_0`. Setup syncs these to native Ollama (Windows user env vars / launchctl) or the container |
| Linux GPU | `COMPOSE_PROFILES=ollama-nvidia\|ollama-amd\|ollama-cpu` |
| Pin Open WebUI | `OPEN_WEBUI_TAG=<release tag>` (default `main`) |

Ask the user for API keys; don't invent placeholder values. If they paste a
key into the chat, write it to `.env` and don't repeat it back.

`ENABLE_PERSISTENT_CONFIG=false` (default) means `.env` wins on every start
and Admin Panel changes to those settings are temporary. With `true`, Open
WebUI ignores later `.env` changes for settings already stored in its
database; tell the user to change those in the Admin Panel instead.

## Repo map

| Path | Purpose |
| --- | --- |
| `setup.sh` / `setup.ps1` (+ `setup.cmd`) | Same flow for macOS/Linux and Windows. Keep them in sync. In WSL, `setup.sh` hands off to `setup.ps1` |
| `compose.yaml` | Open WebUI, plus optional containerized Ollama profiles |
| `.env.example` | All options with safe defaults; secrets empty |
| `models.txt` | Model catalog shown by setup (`tag\|GB\|description`) |
| `scripts/privacy_gate.py`, `.githooks/`, `.github/` | Privacy gate. Changes need line-by-line review |
| `docs/family-access.md` | Tailscale sharing and per-person accounts |

When changing `setup.sh`, keep it compatible with bash 3.2 (macOS). When
changing `setup.ps1`, keep it compatible with Windows PowerShell 5.1 and ASCII-only.
