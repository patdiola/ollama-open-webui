# ollama-open-webui

Open WebUI boilerplate for Ollama: private, self-hosted AI chat over Tailscale, nothing exposed to the internet, with separate accounts for family.

Runs on **macOS** (e.g. a Mac Studio), **Windows 10/11**, and **Linux** (desktop or server).

## Quick start

On the machine that will host it:

```sh
git clone https://github.com/patdiola/ollama-open-webui.git
cd ollama-open-webui
```

| OS | Run |
| --- | --- |
| macOS / Linux | `./setup.sh` |
| Windows | `setup.cmd` (double-click, or run it from a terminal in this folder) |
| Windows, from Ubuntu (WSL) | `./setup.sh`; it runs the Windows setup for you (a clone inside WSL, e.g. `~/git/...`, is first copied to the same path under your Windows user folder) |

Setup asks every question up front, saves your answers to `.env`, then:

1. checks Docker, Ollama and Tailscale, and offers to install what's missing
2. starts Open WebUI (and Ollama, on Linux) with Docker Compose
3. downloads the models you picked, skipping ones you already have
4. has you create the admin account locally, before anything is reachable remotely
5. runs `tailscale serve`, so your devices reach it at `https://<pc-name>.<tailnet>.ts.net`

Run it again any time: it's safe to repeat, and it updates the images.

**On your phone and laptop:** install Tailscale, sign in to the same account, and open the `https://<pc-name>.<tailnet>.ts.net` URL that setup printed. To make it feel like an app, add it to your home screen: Share → Add to Home Screen on iOS, or ⋮ → Install app / Add to Home screen on Android.

| Command | What it does |
| --- | --- |
| `setup` | First run: configure, then start. Later: apply `.env`, update, pull models |
| `setup configure` | Change your answers, then apply |
| `setup status` | Show containers, Ollama and Tailscale serve status |
| `setup stop` | Stop the containers (accounts, chats and models are kept) |

(`./setup.sh <command>` on macOS/Linux, `setup.cmd <command>` on Windows.)

## Prerequisites

Setup checks these and tells you exactly what to do if one is missing.

| | macOS | Windows | Linux |
| --- | --- | --- | --- |
| Docker | Docker Desktop or OrbStack | Docker Desktop (WSL 2) | Docker Engine + Compose v2 |
| Ollama | Native app (uses the GPU) | Native app (default) or container | Container (NVIDIA, AMD or CPU) |
| Tailscale | App, signed in | App, signed in | Installed by setup if missing |

Notes:
- **macOS:** Docker can't use the Mac GPU, so Ollama runs natively.
- **Linux + NVIDIA:** install [nvidia-container-toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html).
- **Tailscale HTTPS:** the first `tailscale serve` may ask you to enable HTTPS certificates for your tailnet. Follow the link it prints.

## What you configure

| Setting | Default | Notes |
| --- | --- | --- |
| Ollama mode / hardware | per OS | see above |
| Models | none | picked from [`models.txt`](models.txt) or any [Ollama tag](https://ollama.com/library); setup marks what fits your memory |
| Port | 3000 | always bound to `127.0.0.1` |
| Tailscale remote access | on | tailnet only; never Funnel |
| Cloud models | off | OpenAI, OpenRouter, or any OpenAI-compatible API. Chats sent to them leave your machine |
| Web search | on, DuckDuckGo | Tavily (recommended), Brave or SerpAPI for better results; `off` for no web access. To start every chat with it: Admin Panel → Settings → Models → Default Features |
| Settings source | `.env` | `.env` re-applied on every start; or let the Admin Panel own them |

Everything lands in `.env`, which is gitignored and created with owner-only permissions on macOS/Linux. See [`.env.example`](.env.example) for every option.

### Changing settings later

- Run `setup configure`, or
- edit `.env` and run `setup` to apply, or
- ask an AI coding CLI (Claude Code, Codex, Gemini CLI, ...) in this folder, for example *"switch me to qwen3:14b and turn on DuckDuckGo search"*. [`AGENTS.md`](AGENTS.md) tells it the rules.

## Family access

See [docs/family-access.md](docs/family-access.md): share only this machine over Tailscale, create an account per person, and keep sign-ups off.

## Privacy & security

This repo is public and privacy-first. Personal settings and secrets live only in `.env`. A privacy gate blocks pushes that contain secrets, private IPs, tailnet hostnames, personal emails or unsafe Docker settings. Contributors: read [PRIVACY_SECURITY.md](PRIVACY_SECURITY.md) and enable the hook once per clone:

```sh
git config core.hooksPath .githooks
cp .privacy-denylist.example .privacy-denylist   # then add your personal terms
```

Report vulnerabilities privately: [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
