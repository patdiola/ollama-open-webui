# Privacy & security rules

This repo is privacy- and security-first. When convenience conflicts with
these rules, the rules win. They are enforced by `scripts/privacy_gate.py`,
which runs before every push (git hook) and on every push and pull request (CI).

## The rules

1. **Secrets never enter Git.** Real values live only in `.env`, which is
   gitignored. In `.env.example`, every secret is left empty. A secret that
   was ever pushed is treated as compromised and must be rotated; rewriting
   history does not undo exposure.

2. **Secure by default.** Someone who copies `.env.example` without editing
   it must get a locked-down setup:
   - Every published port binds to `127.0.0.1` by default. Remote access goes
     through Tailscale, not LAN or internet exposure.
   - No `network_mode: host`, `privileged`, `cap_add`, host `pid`/`ipc`/`userns`
     namespaces, or Docker socket mounts.
   - Container images come only from the allowlist in the gate script.
   - Users' chats are private from the admin: `ENABLE_ADMIN_CHAT_ACCESS` and
     `ENABLE_ADMIN_EXPORT` default to `false`.

3. **No personal or network-identifying data.** That includes private and
   Tailscale IP addresses, tailnet hostnames, MAC addresses, home-directory
   paths containing a username, and email addresses. In docs, use
   placeholders:
   - IPs: `192.0.2.10` (RFC 5737 documentation range)
   - Hosts: `<pc-name>.<tailnet>.ts.net`
   - Emails: `you@example.com`

4. **Commits are authored with a GitHub noreply email.** Set it per repo:
   `git config user.email <id>+<username>@users.noreply.github.com`.
   To publish a different address on purpose, allow it explicitly:
   `git config --add privacygate.allowedEmail you@example.com`.

5. **The gate is fixed, not bypassed.** When the gate blocks a push, fix the
   commits (`git commit --amend`, `git rebase -i`). For a genuine false
   positive, add `privacy-gate: allow <reason>` to that line. That exemption
   is visible in review.

6. **Changes to the gate get extra scrutiny.** On pull requests, CI runs the
   gate from the base branch, so a PR cannot weaken the gate and pass its own
   check. Review any diff to `scripts/`, `.githooks/`, or `.github/` line by line.

## Setup (once per clone)

```sh
git config core.hooksPath .githooks
cp .privacy-denylist.example .privacy-denylist   # then add your personal terms
```

`.privacy-denylist` (gitignored) holds terms specific to you, such as your
name, computer hostname, tailnet name, and OS username. The gate also treats
personal values in your `.env` (hostnames, URLs, keys) as forbidden content.
Neither file ever leaves your machine.

Run the full check manually at any time:

```sh
python3 scripts/privacy_gate.py --all
```
