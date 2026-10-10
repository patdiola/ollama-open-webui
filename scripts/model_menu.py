"""Sets up the model menu as "Chat" and "Code". Setup runs it inside the
open-webui container:

    docker exec -i open-webui python3 - CHAT_TAG CODE_TAG < scripts/model_menu.py

- Names the chat model "Chat" and the coding model "Code" (Code without image
  input; coder models are text-only), and lets every account use both.
- Hides every other local model, so people pick between two tested models
  instead of guessing.

It writes the same model entries the Admin Panel (Settings > Models) saves,
using Open WebUI's own code, and only for models without an entry yet: names
and visibility set in the Admin Panel survive re-running setup. One exception:
Chat and Code get public read access if they have none, because without it
only the admin sees them. Hidden models stay downloaded; show them again in
the Admin Panel. Prints one line per change.
"""
import asyncio
import json
import os
import sys
import urllib.request

from open_webui.models.access_grants import AccessGrants
from open_webui.models.models import ModelForm, Models
from open_webui.models.users import Users

PUBLIC = [{"principal_type": "user", "principal_id": "*", "permission": "read"}]


def tag(name):
    return name if ":" in name else name + ":latest"


def ollama_models():
    base = os.environ.get("OLLAMA_BASE_URL", "http://host.docker.internal:11434").split(";")[0]
    with urllib.request.urlopen(base.rstrip("/") + "/api/tags", timeout=15) as r:
        return [m["name"] for m in json.load(r).get("models", [])]


async def main(chat, code):
    admin = await Users.get_super_admin_user()
    if admin is None:
        print("skipped: no admin account yet")
        return
    caps = json.loads(os.environ.get("DEFAULT_MODEL_METADATA") or "{}").get("capabilities", {})
    names = {
        chat: ("Chat", "Everyday chat: searches the web, reads photos and screenshots", {}),
        code: ("Code", "Coding help: write, explain and fix code",
               {"capabilities": dict(caps, vision=False)} if caps and code != chat else {}),
    }
    local = ollama_models()
    for t in (chat, code):
        if t not in local:
            print("skipped %s: not downloaded" % t)
    entries = {m.id: m for m in await Models.get_all_models()}
    # The arena model is Open WebUI's blind A/B test entry; hidden like the rest.
    for mid in local + ["arena-model"]:
        entry = entries.get(mid)
        if mid in names:
            name, desc, extra = names[mid]
            if entry is None:
                await Models.insert_new_model(ModelForm(
                    id=mid, name=name, meta={"description": desc, **extra}, params={},
                    access_grants=PUBLIC, is_active=True), admin.id)
                print("%s: shown as %s" % (mid, name))
            elif not entry.access_grants:
                await AccessGrants.set_access_grants("model", mid, PUBLIC)
                print("%s: every account can use it now" % entry.name)
        elif entry is None:
            await Models.insert_new_model(ModelForm(
                id=mid, name=mid, meta={}, params={}, access_grants=[], is_active=False), admin.id)
            print("%s: hidden" % mid)


asyncio.run(main(tag(sys.argv[1]), tag(sys.argv[2])))
