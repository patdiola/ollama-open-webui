"""Web search with automatic fallback, for Open WebUI's "external" engine.

Open WebUI POSTs {"query": ..., "count": ...} to /search and expects a list
of {"link", "title", "snippet"}. This tries each engine in SEARCH_ORDER and
returns the first non-empty result, so a search engine that is out of
credits, rate-limited or down doesn't leave chats without search results.

Engines: tavily (TAVILY_API_KEY), serpapi (SERPAPI_API_KEY), duckduckgo (no
key; uses the ddgs package that ships in the Open WebUI image). Engines
without a key are skipped. Runs on the private compose network only; it
publishes no port. Logs which engine answered, never keys or queries.
"""
import json
import logging
import os
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ORDER = os.environ.get("SEARCH_ORDER", "tavily serpapi duckduckgo").split()
TIMEOUT = 20
log = logging.getLogger("search-fallback")


def http_json(url, body=None, headers=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data, {"Content-Type": "application/json", **(headers or {})})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return json.load(r)


def tavily(query, count):
    key = os.environ.get("TAVILY_API_KEY")
    if not key:
        return None
    r = http_json("https://api.tavily.com/search", {"query": query, "max_results": count},
                  {"Authorization": f"Bearer {key}"})
    return [{"link": x.get("url"), "title": x.get("title"), "snippet": x.get("content")}
            for x in r.get("results", [])]


def serpapi(query, count):
    key = os.environ.get("SERPAPI_API_KEY")
    if not key:
        return None
    q = urllib.parse.urlencode({"engine": "google", "q": query, "num": count, "api_key": key})
    r = http_json(f"https://serpapi.com/search.json?{q}")
    if r.get("error"):
        raise RuntimeError(r["error"])
    return [{"link": x.get("link"), "title": x.get("title"), "snippet": x.get("snippet")}
            for x in r.get("organic_results", [])]


def duckduckgo(query, count):
    from ddgs import DDGS
    return [{"link": x.get("href"), "title": x.get("title"), "snippet": x.get("body")}
            for x in DDGS().text(query, max_results=count)]


ENGINES = {"tavily": tavily, "serpapi": serpapi, "duckduckgo": duckduckgo}


def search(query, count):
    for name in ORDER:
        engine = ENGINES.get(name)
        if engine is None:
            continue
        try:
            results = engine(query, count)
        # Any failure moves on: urllib raises HTTPError for every status >= 400
        # (401 bad key, 429 rate limit, 432/433 Tavily out of credits, 5xx),
        # plus timeouts, connection errors and SerpAPI's "error" field.
        except Exception as e:
            log.warning("%s failed (%s), trying the next engine", name, getattr(e, "code", type(e).__name__))
            continue
        if results:
            log.info("%s answered with %d results", name, len(results))
            return results[:count]
        if results is not None:
            log.warning("%s returned no results, trying the next engine", name)
    log.error("no engine returned results")
    return []


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self._send(200, {"ok": True} if self.path == "/health" else {"error": "not found"})

    def do_POST(self):
        if self.path != "/search":
            return self._send(404, {"error": "not found"})
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
            count = max(1, min(int(body.get("count") or 5), 20))
            self._send(200, search(str(body.get("query", "")), count))
        except Exception as e:
            log.error("bad request: %s", type(e).__name__)
            self._send(400, {"error": "bad request"})

    def _send(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):  # no per-request access log
        pass


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    for noisy in ("ddgs", "primp", "httpx", "httpcore"):  # they log every query and URL
        logging.getLogger(noisy).setLevel(logging.WARNING)
    log.info("search order: %s", " -> ".join(ORDER))
    ThreadingHTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
