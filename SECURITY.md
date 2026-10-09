# Security policy

Please **don't report security problems in public issues or discussions.**

Report them privately through GitHub:
**Security tab → Report a vulnerability**.

In scope: this repo's compose file, defaults, docs, privacy gate, and CI.
Vulnerabilities in Open WebUI, Ollama, or Tailscale themselves should be
reported to those projects directly.

If a report involves your own leaked secret (for example a
`WEBUI_SECRET_KEY` or Tailscale auth key), rotate it first; removing it
from a post or commit doesn't undo exposure.
