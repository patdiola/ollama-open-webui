# Family access

Each family member gets their own Open WebUI account. Their chats are
private from each other, and with this repo's defaults
(`ENABLE_ADMIN_CHAT_ACCESS=false`, `ENABLE_ADMIN_EXPORT=false`) the admin
can't read or export them through Open WebUI either.

There are two layers: getting onto the network (Tailscale), and logging in
(Open WebUI).

## 1. Network access: share the device, don't invite users

Each family member creates their own free Tailscale account and installs
the app. You then **share only the Open WebUI machine** with them:
admin console → Machines → the host machine → Share.

Why sharing rather than inviting them into your tailnet:

- **Smaller blast radius.** An invited user can reach every device in your
  tailnet by default. A shared device is the only thing a sharee sees.
- **No user limits.** Shared devices don't count toward your plan's user
  count. Invited users do, and the free plan's limit has changed over time.
- **Their accounts stay theirs.** Nobody shares login credentials.

They open the same `https://<pc-name>.<tailnet>.ts.net` URL and install it
to their home screen, the same way you did.

### Restrict sharees to the web UI only

By default, a sharee can reach **every port** on the shared machine. That can
include Remote Desktop and file sharing (Windows), Screen Sharing and SSH
(macOS), or SSH (Linux). Limit them to
HTTPS with a grant in your tailnet policy file (admin console → Access
controls):

```jsonc
{
  "hosts": {
    "open-webui": "100.x.y.z"   // the host's Tailscale IP
  },
  "grants": [
    // You and your own devices: unchanged full access.
    // Replaces the default rule whose "src" is "*", which includes sharees.
    { "src": ["autogroup:member"], "dst": ["*"], "ip": ["*"] },

    // People you've shared the device with: HTTPS (tailscale serve) only.
    { "src": ["autogroup:shared"], "dst": ["open-webui"], "ip": ["tcp:443"] }
  ]
}
```

Use the policy editor's preview and tests to confirm the result before saving.
Keep this policy out of the repo: it contains your Tailscale IP.

## 2. Accounts: you create them; sign-ups stay off

1. Admin Panel → Users → **Add User**. Create an account per person with
   role **user**, and send them the password privately. They can change it
   under Settings → Account.
2. Leave **new sign-ups disabled** (`ENABLE_SIGNUP=false`, this repo's
   default). An open sign-up page reachable by every sharee defeats the
   per-person setup.
3. Keep the default user permissions minimal. In particular, **don't grant
   Workspace permissions** (creating models, knowledge, prompts, tools) to
   family accounts unless someone needs them. Several 2026 Open WebUI
   vulnerabilities were stored XSS that required a user with model-creation
   permission to plant malicious content. Without that permission, those
   attacks aren't available to other accounts.
4. Consider a separate admin account that you use only for administration,
   and a regular **user** account for your own day-to-day chats.

## What "private" means here, honestly

The admin settings stop the admin from reading chats **through the Open WebUI
interface**. Whoever runs the host machine can still read the database in
the Docker volume. Tell your family that. For conversations that must not be
stored at all, use Open WebUI's **temporary chat** mode.

## Sharing one GPU

Ollama queues requests, so several people can use it at once. Responses slow
down when requests overlap, and a model that's loaded for one person holds
VRAM for everyone (idle models unload after 5 minutes by default). Expect
noticeably slower responses while the machine is busy with something else,
such as a game.
