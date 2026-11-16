"""Point your free Vapi phone number at this server.

Usage (with server/.env filled in, PUBLIC_URL set to the current tunnel):
    .venv\\Scripts\\python setup_vapi.py
It finds your Vapi number (or VAPI_PHONE_NUMBER_ID), sets its server URL to
<PUBLIC_URL>/vapi/<VAPI_PATH_TOKEN>/webhook, and prints the number so you can put it in
SUPPORT_NUMBER and the watch's Config.mc. Run it again whenever the tunnel URL changes.
"""
import os
import sys

import httpx2
from dotenv import load_dotenv

load_dotenv()
key = os.environ.get("VAPI_API_KEY", "")
public = os.environ.get("PUBLIC_URL", "").rstrip("/")
path_token = os.environ.get("VAPI_PATH_TOKEN", "")
if not (key and public.startswith("https://") and path_token):
    sys.exit("Set VAPI_API_KEY, PUBLIC_URL (https://...) and VAPI_PATH_TOKEN in .env first.")

api = httpx2.Client(base_url="https://api.vapi.ai", headers={"Authorization": f"Bearer {key}"}, timeout=30)
numbers = api.get("/phone-number").raise_for_status().json()
wanted = os.environ.get("VAPI_PHONE_NUMBER_ID", "")
num = next((n for n in numbers if not wanted or n.get("id") == wanted), None)
if num is None:
    sys.exit("No Vapi phone number found. Create the free number in the Vapi dashboard first.")

url = f"{public}/vapi/{path_token}/webhook"
r = api.patch(f"/phone-number/{num['id']}", json={"server": {"url": url}})
if r.status_code >= 400:   # some providers require the discriminator field on update
    r = api.patch(f"/phone-number/{num['id']}", json={"provider": num.get("provider"), "server": {"url": url}})
r.raise_for_status()
print(f"Vapi number {num.get('number')} (id {num['id']}) now sends calls to {public}/vapi/<secret>/webhook")
