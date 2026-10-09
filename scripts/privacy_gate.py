#!/usr/bin/env python3
"""Privacy & security gate. Enforces the rules in PRIVACY_SECURITY.md.

Modes:
  --pre-push REMOTE [URL]  Run as a git pre-push hook (reads refs on stdin).
                           Scans every commit about to be pushed, plus the
                           tree at each pushed tip.
  --all                    Scan the tree at HEAD and every commit in its
                           history. Used in CI.

Standard library only. Fails closed: any finding or internal error blocks
the push. Matched values are masked in output so CI logs never echo them.

False positive? Put "privacy-gate: allow" on the line, with a reason.
"""
from __future__ import annotations

import argparse
import fnmatch
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

ALLOW_PRAGMA = "privacy-gate: allow"

# Container images allowed in compose files (prefix match).
ALLOWED_IMAGES = (
    "ghcr.io/open-webui/open-webui",
    "ollama/ollama",
    "docker.io/ollama/ollama",
)

# Files that must never be committed (matched against the file name).
FORBIDDEN_FILES = (
    ".env", ".env.*", ".privacy-denylist", ".webui_secret_key",
    "*.pem", "*.key", "*.p12", "*.pfx", "id_rsa*", "id_ecdsa*", "id_ed25519*",
    "*.db", "*.sqlite", "*.sqlite3", "*.db-wal", "*.db-shm",
)
ALLOWED_FILES = (".env.example", ".privacy-denylist.example")

COMPOSE_NAMES = ("compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml")
CONFIG_SUFFIXES = (".yml", ".yaml", ".json", ".toml", ".ini", ".conf", ".cfg", ".env")

SECRET_PATTERNS = [
    ("private key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("GitHub token", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,})")),
    ("Tailscale auth/API key", re.compile(r"\btskey-[A-Za-z0-9-]{10,}")),
    ("API key (sk-...)", re.compile(r"\bsk-[A-Za-z0-9_-]{20,}")),
    ("AWS access key", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")),
    ("Slack token", re.compile(r"\bxox[abposr]-[A-Za-z0-9-]{10,}")),
    ("Google API key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}")),
    ("JWT", re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}")),
    ("literal WEBUI_SECRET_KEY value",
     re.compile(r"WEBUI_SECRET_KEY\s*[:=]\s*[\"']?(?!\$\{)[^\s\"'#]{8,}")),
]
# Only applied to config-like files, where these assignments are real config.
CONFIG_SECRET_PATTERN = (
    "hardcoded credential",
    re.compile(r"(?i)\b(?:password|passwd|secret|token|api[_-]?key)\b\s*[:=]\s*[\"']?(?!\$\{)[^\s\"'#]{12,}"),
)

PRIVACY_PATTERNS = [
    ("private IPv4 address (use 192.0.2.x in docs)",
     re.compile(r"\b(?:10\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])|192\.168)\.\d{1,3}\.\d{1,3}\b")),
    ("Tailscale IPv4 address",
     re.compile(r"\b100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}\b")),
    ("Tailscale IPv6 address", re.compile(r"(?i)\bfd7a:115c:a1e0:")),
    ("tailnet hostname", re.compile(r"(?i)\b[a-z0-9-]+\.[a-z0-9-]+\.ts\.net\b")),
    ("MAC address", re.compile(r"\b[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}\b")),
    ("home directory path",
     re.compile(r"(?:[A-Za-z]:\\+Users\\+|/Users/|/home/)([A-Za-z0-9._-]+)")),
    ("email address", re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")),
]
PLACEHOLDER_HOSTS = ("example", "your", "placeholder", "tailnet-name", "machine-name")
PLACEHOLDER_USERS = {"public", "default", "shared", "you", "user", "username", "yourname",
                     "your-username", "runner", "example", "name", "me"}
ALLOWED_EMAIL_DOMAINS = ("example.com", "example.org", "example.net", "users.noreply.github.com")
ALLOWED_EMAILS = {"git@github.com", "noreply@github.com"}


@dataclass(frozen=True)
class Finding:
    rule: str
    where: str
    detail: str = ""


def git(*args: str, check: bool = True) -> str:
    result = subprocess.run(
        ["git", "-c", "core.quotepath=false", *args],
        capture_output=True, text=True, encoding="utf-8", errors="replace",
    )
    if check and result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout


def git_bytes(*args: str) -> bytes:
    return subprocess.run(["git", *args], capture_output=True, check=True).stdout


def mask(value: str) -> str:
    value = value.strip()
    return f"{value[:3]}... ({len(value)} chars)" if len(value) > 3 else "*" * len(value)


def is_zero(sha: str) -> bool:
    return set(sha) == {"0"}


def short(sha: str) -> str:
    return sha[:8]


# ---------------------------------------------------------------- local terms

def load_personal_terms(root: Path) -> list[str]:
    """Terms that must never appear: .privacy-denylist plus personal .env values."""
    terms: list[str] = []
    denylist = Path(os.environ.get("PRIVACY_GATE_DENYLIST", root / ".privacy-denylist"))
    if denylist.is_file():
        for line in denylist.read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and len(line) >= 3:
                terms.append(line)

    def env_values(path: Path, commented: bool = False) -> dict[str, str]:
        values = {}
        if path.is_file():
            for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
                # Documented alternatives ("# KEY=value") in .env.example are public too.
                if commented and re.match(r"^\s*#\s*[A-Z][A-Z0-9_]*=", line):
                    line = line.lstrip().lstrip("#")
                if "=" in line and not line.lstrip().startswith("#"):
                    key, _, val = line.partition("=")
                    values[key.strip()] = val.strip().strip("\"'")
        return values

    env = env_values(root / ".env")
    example_values = set(env_values(root / ".env.example", commented=True).values())
    sensitive_key = re.compile(r"SECRET|KEY|TOKEN|PASS|HOST|URL|DOMAIN|NAME|USER|EMAIL")
    for key, val in env.items():
        if sensitive_key.search(key) and len(val) >= 6 and val not in example_values:
            terms.append(val)
    return terms


def allowed_emails() -> set[str]:
    configured = git("config", "--get-all", "privacygate.allowedEmail", check=False)
    return ALLOWED_EMAILS | {e.strip().lower() for e in configured.splitlines() if e.strip()}


# ---------------------------------------------------------------- content rules

def scan_line(path: str, lineno: int, line: str, terms: list[str], emails: set[str]) -> list[Finding]:
    if ALLOW_PRAGMA in line:
        return []
    where = f"{path}:{lineno}"
    found: list[Finding] = []

    for rule, pattern in SECRET_PATTERNS:
        for m in pattern.finditer(line):
            found.append(Finding(f"secret: {rule}", where, mask(m.group(0))))

    name = Path(path).name
    if name.startswith(".env") or path.endswith(CONFIG_SUFFIXES):
        rule, pattern = CONFIG_SECRET_PATTERN
        for m in pattern.finditer(line):
            found.append(Finding(f"secret: {rule}", where, mask(m.group(0))))

    for rule, pattern in PRIVACY_PATTERNS:
        for m in pattern.finditer(line):
            value = m.group(0)
            if rule == "tailnet hostname" and any(p in value.lower() for p in PLACEHOLDER_HOSTS):
                continue
            if rule == "home directory path" and m.group(1).lower() in PLACEHOLDER_USERS:
                continue
            if rule == "email address":
                lower = value.lower()
                if lower in emails or lower.endswith(ALLOWED_EMAIL_DOMAINS):
                    continue
            found.append(Finding(f"privacy: {rule}", where, mask(value)))

    lower_line = line.lower()
    for i, term in enumerate(terms, 1):
        if term.lower() in lower_line:
            found.append(Finding("privacy: personal term (from .privacy-denylist/.env)",
                                 where, f"term #{i}"))
    return found


def check_file_name(path: str) -> Finding | None:
    name = Path(path).name
    if name in ALLOWED_FILES:
        return None
    if any(fnmatch.fnmatch(name, pattern) for pattern in FORBIDDEN_FILES):
        return Finding("forbidden file committed", path)
    return None


# ---------------------------------------------------------------- policy rules

LOCAL_BIND = re.compile(r"^(?:127\.0\.0\.1|\[::1\]|\$\{[A-Za-z0-9_]+:?-127\.0\.0\.1\})$")
HOST_PART = re.compile(r"^(?P<host>\$\{[^}]+\}|\[[^\]]+\]|\d{1,3}(?:\.\d{1,3}){3}):(?P<rest>.+)$")
DANGEROUS_COMPOSE = [
    (re.compile(r"^\s*network_mode:\s*[\"']?host"), "network_mode: host"),
    (re.compile(r"^\s*privileged:\s*true"), "privileged: true"),
    (re.compile(r"^\s*(?:pid|ipc|userns_mode):\s*[\"']?host"), "host pid/ipc/userns namespace"),
    (re.compile(r"docker\.sock"), "Docker socket mount"),
    (re.compile(r"^\s*cap_add:"), "cap_add"),
]


def check_port(value: str, where: str) -> Finding | None:
    value = value.strip().strip("\"'")
    if re.match(r"^\w+:\s", value):  # long syntax (target:/published:/host_ip:)
        return Finding("security: use short port syntax with an explicit 127.0.0.1 bind",
                       where, value)
    m = HOST_PART.match(value)
    if not m:
        return Finding("security: port published on all interfaces", where, value)
    if not LOCAL_BIND.match(m.group("host")):
        return Finding("security: port must bind to 127.0.0.1 by default", where, value)
    return None


def check_compose(path: str, text: str) -> list[Finding]:
    found: list[Finding] = []
    if "ghcr.io/open-webui/open-webui" in text:
        for key in ("ENABLE_ADMIN_CHAT_ACCESS", "ENABLE_ADMIN_EXPORT"):
            if not re.search(rf"^\s*-?\s*{key}\s*[:=]", text, re.MULTILINE):
                found.append(Finding(f"privacy: Open WebUI service must set {key}=false", path))
    lines = text.splitlines()

    def indent(s: str) -> int:
        return len(s) - len(s.lstrip(" "))

    for i, raw in enumerate(lines, 1):
        if ALLOW_PRAGMA in raw:
            continue
        line = raw.split(" #", 1)[0]
        where = f"{path}:{i}"
        for pattern, label in DANGEROUS_COMPOSE:
            if pattern.search(line):
                found.append(Finding(f"security: {label} is not allowed", where))
        m = re.match(r"^\s*-?\s*(ENABLE_ADMIN_(?:CHAT_ACCESS|EXPORT))\s*[:=]\s*(.*)$", line)
        if m and not re.fullmatch(r"[\"']?(?:false|\$\{%s:-false\})[\"']?" % m.group(1),
                                  m.group(2).strip(), re.IGNORECASE):
            found.append(Finding(f"privacy: {m.group(1)} must default to false", where,
                                 m.group(2).strip()))
        m = re.match(r"^\s*image:\s*[\"']?([^\s\"']+)", line)
        if m and not m.group(1).startswith(ALLOWED_IMAGES):
            found.append(Finding("security: image not on allowlist", where, m.group(1)))

        m = re.match(r"^(\s*)ports:\s*(.*)$", line)
        if not m:
            continue
        inline = m.group(2).strip()
        if inline.startswith("["):
            for entry in inline.strip("[]").split(","):
                if entry.strip() and (f := check_port(entry, where)):
                    found.append(f)
            continue
        base = len(m.group(1))
        j = i
        while j < len(lines) and (not lines[j].strip() or indent(lines[j]) > base):
            entry = lines[j].split(" #", 1)[0].strip()
            if entry.startswith("- ") and ALLOW_PRAGMA not in lines[j]:
                if f := check_port(entry[2:], f"{path}:{j + 1}"):
                    found.append(f)
            j += 1
    return found


def check_env_example(path: str, text: str) -> list[Finding]:
    found: list[Finding] = []
    for i, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#") or "=" not in line or ALLOW_PRAGMA in line:
            continue
        key, _, value = line.partition("=")
        key, value = key.strip(), value.strip().strip("\"'")
        where = f"{path}:{i}"
        if re.search(r"SECRET|TOKEN|PASSWORD|API_KEY", key) and value:
            found.append(Finding("secret: .env.example secrets must be empty", where, key))
        if key in ("ENABLE_ADMIN_CHAT_ACCESS", "ENABLE_ADMIN_EXPORT") and value.lower() != "false":
            found.append(Finding(f"privacy: .env.example {key} must be false", where, value))
        if key.endswith("_BIND") and value not in ("127.0.0.1", "::1", "[::1]"):
            found.append(Finding("security: .env.example bind default must be 127.0.0.1",
                                 where, f"{key}={value}"))
    return found


def check_gitignore(files: set[str], sha: str) -> list[Finding]:
    if ".gitignore" not in files:
        return [Finding("security: .gitignore is missing", short(sha))]
    entries = {l.strip() for l in git("cat-file", "-p", f"{sha}:.gitignore").splitlines()}
    found = []
    for required, accepted in ((".env", {".env", "/.env", ".env*", "*.env"}),
                               (".privacy-denylist", {".privacy-denylist", "/.privacy-denylist"})):
        if not entries & accepted:
            found.append(Finding(f"security: .gitignore must ignore {required}", ".gitignore"))
    return found


# ---------------------------------------------------------------- scanners

def read_blob(sha: str, path: str) -> str | None:
    data = git_bytes("cat-file", "-p", f"{sha}:{path}")
    if b"\x00" in data[:8000] or len(data) > 2_000_000:
        return None
    return data.decode("utf-8", errors="replace")


def scan_tree(sha: str, terms: list[str], emails: set[str]) -> list[Finding]:
    files = set(git("ls-tree", "-r", "--name-only", sha).splitlines())
    found = check_gitignore(files, sha)
    for path in sorted(files):
        if f := check_file_name(path):
            found.append(f)
        text = read_blob(sha, path)
        if text is None:
            continue
        for i, line in enumerate(text.splitlines(), 1):
            found += scan_line(path, i, line, terms, emails)
        name = Path(path).name
        if name in COMPOSE_NAMES:
            found += check_compose(path, text)
        if name == ".env.example":
            found += check_env_example(path, text)
    return found


def empty_tree() -> str:
    return subprocess.run(["git", "hash-object", "-t", "tree", "--stdin"], input=b"",
                          capture_output=True, check=True).stdout.decode().strip()


def scan_commit(sha: str, terms: list[str], emails: set[str], check_author: bool) -> list[Finding]:
    found: list[Finding] = []
    tag = short(sha)
    if check_author:
        for label, email in zip(("author", "committer"),
                                git("show", "-s", "--format=%ae%n%ce", sha).splitlines()):
            e = email.strip().lower()
            if e not in emails and not e.endswith("@users.noreply.github.com"):
                found.append(Finding(f"privacy: {label} email is not a noreply address",
                                     tag, mask(e)))

    parents = git("rev-list", "--parents", "-n", "1", sha).split()[1:]
    base = parents[0] if parents else empty_tree()
    diff_args = ("--no-renames", "--no-color", "--no-ext-diff")
    for path in git("diff", "--name-only", "--diff-filter=ACM", *diff_args, base, sha).splitlines():
        if f := check_file_name(path):
            found.append(Finding(f.rule, f"{tag} {path}"))

    path, lineno, in_header = None, 0, False
    for line in git("diff", "--unified=0", *diff_args, base, sha).splitlines():
        if line.startswith("diff --git "):
            in_header, path = True, None
        elif in_header and line.startswith("+++ "):
            target = line[4:]
            path = None if target == "/dev/null" else target.removeprefix("b/")
        elif line.startswith("@@"):
            in_header = False
            m = re.search(r"\+(\d+)", line)
            lineno = int(m.group(1)) if m else 0
        elif not in_header and path and line.startswith("+"):
            for f in scan_line(path, lineno, line[1:], terms, emails):
                found.append(Finding(f.rule, f"{tag} {f.where}", f.detail))
            lineno += 1
    return found


def commits_for_push(remote: str, refs: list[tuple[str, str, str, str]]) -> tuple[list[str], list[str]]:
    commits: list[str] = []
    tips: list[str] = []
    for _local_ref, local_sha, _remote_ref, remote_sha in refs:
        if is_zero(local_sha):
            continue  # branch deletion
        tips.append(local_sha)
        args = ["rev-list", local_sha, "--not", f"--remotes={remote}"]
        if not is_zero(remote_sha) and subprocess.run(
                ["git", "cat-file", "-e", f"{remote_sha}^{{commit}}"],
                capture_output=True).returncode == 0:
            args.append(remote_sha)  # after --not: exclude what the remote already has
        commits += [c for c in git(*args).split() if c not in commits]
    return commits, list(dict.fromkeys(tips))


def report(findings: list[Finding]) -> int:
    # The same problem shows up in a commit diff and in the tree scan; report it once.
    unique, seen = [], set()
    for f in findings:
        where = re.sub(r"^[0-9a-f]{8} ", "", f.where)
        key = (f.rule, where, f.detail)
        if key not in seen:
            seen.add(key)
            unique.append(f)
    if not unique:
        print("privacy-gate: passed")
        return 0
    print(f"privacy-gate: BLOCKED - {len(unique)} finding(s)\n", file=sys.stderr)
    for f in unique:
        detail = f"  [{f.detail}]" if f.detail else ""
        print(f"  {f.rule}\n      at {f.where}{detail}", file=sys.stderr)
    print(
        "\nFix the commits before pushing (git commit --amend / git rebase -i).\n"
        "A secret that was ever pushed must be rotated; rewriting history is not enough.\n"
        f'Genuine false positive: add "{ALLOW_PRAGMA} <reason>" to that line.\n'
        "See PRIVACY_SECURITY.md.",
        file=sys.stderr,
    )
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--pre-push", nargs="+", metavar="REMOTE")
    mode.add_argument("--all", action="store_true")
    args = parser.parse_args()

    root = Path(git("rev-parse", "--show-toplevel").strip())
    os.chdir(root)
    terms = load_personal_terms(root)
    emails = allowed_emails()
    findings: list[Finding] = []

    if args.all:
        for sha in git("rev-list", "HEAD").split():
            findings += scan_commit(sha, terms, emails, check_author=False)
        findings += scan_tree("HEAD", terms, emails)
    else:
        refs = [tuple(l.split()) for l in sys.stdin.read().splitlines() if l.strip()]
        commits, tips = commits_for_push(args.pre_push[0], refs)  # type: ignore[arg-type]
        for sha in commits:
            findings += scan_commit(sha, terms, emails, check_author=True)
        for tip in tips:
            findings += scan_tree(tip, terms, emails)
    return report(findings)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # fail closed
        print(f"privacy-gate: internal error, blocking push: {exc}", file=sys.stderr)
        sys.exit(2)
