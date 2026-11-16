"""CalmBand support server (Vapi + Cloudflare Workers AI + email). Everything runs on free tiers.

Flow:
  1. watch --POST /alert--> server: an anxiety episode is recorded; the watch shows the support number
  2. user calls the free Vapi number
  3. Vapi --assistant-request--> server: we answer with a coach that knows the watch data
  4. during the call Vapi --POST .../llm--> server --> Cloudflare Workers AI (streamed back as-is)
  5. Vapi --end-of-call-report--> server: summary written, emailed to the therapist; the friend gets
     a short check-in email. If the user never calls, both are still emailed after CALL_WAIT_SEC.

Without Gmail settings the server runs emails in DRY RUN mode (logged, not sent).
"""
import asyncio
import hmac
import json
import logging
import os
import smtplib
import time
import uuid
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path
from datetime import datetime
from email.message import EmailMessage

from dotenv import load_dotenv

load_dotenv()

from fastapi import FastAPI, HTTPException, Request  # noqa: E402
from fastapi.responses import HTMLResponse, RedirectResponse, StreamingResponse  # noqa: E402

import agent  # noqa: E402

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("calmband")

# ---------------------------------------------------------------- config (from .env)
PUBLIC_URL = (os.environ.get("PUBLIC_URL")                       # https://<your tunnel>
              or os.environ.get("RENDER_EXTERNAL_URL", "")).rstrip("/")  # set automatically on Render
ALERT_TOKEN = os.environ.get("ALERT_TOKEN", "")                   # shared secret with the watch
VAPI_PATH_TOKEN = os.environ.get("VAPI_PATH_TOKEN", "")           # secret part of the Vapi URLs
DISPLAY_TOKEN = os.environ.get("DISPLAY_TOKEN", "")               # secret part of the demo page URL
SUPPORT_NUMBER = os.environ.get("SUPPORT_NUMBER", "")             # the free Vapi number, for display
USER_NAME = os.environ.get("USER_NAME", "there")
APPS_SCRIPT_URL = os.environ.get("APPS_SCRIPT_URL", "")            # Google Apps Script email relay
APPS_SCRIPT_SECRET = os.environ.get("APPS_SCRIPT_SECRET", "")
GMAIL_ADDRESS = os.environ.get("GMAIL_ADDRESS", "")
GMAIL_APP_PASSWORD = os.environ.get("GMAIL_APP_PASSWORD", "").replace(" ", "")
THERAPIST_EMAIL = os.environ.get("THERAPIST_EMAIL", "")
FRIEND_EMAIL = os.environ.get("FRIEND_EMAIL", "")
CALL_WAIT_SEC = int(os.environ.get("CALL_WAIT_SEC", "600"))       # notify anyway if no call by then
MAX_CALL_SEC = int(os.environ.get("MAX_CALL_SEC", "420"))         # keeps Vapi's free credit going further
MAX_ALERTS_PER_DAY = int(os.environ.get("MAX_ALERTS_PER_DAY", "10"))
HISTORY_TURNS = 12                                                # turns sent to the AI per reply

USE_APPS_SCRIPT = bool(APPS_SCRIPT_URL and APPS_SCRIPT_SECRET)
EMAIL_DRY_RUN = not (USE_APPS_SCRIPT or (GMAIL_ADDRESS and GMAIL_APP_PASSWORD))

app = FastAPI(title="CalmBand")


@dataclass
class Episode:
    id: str
    alert: dict
    created: float
    call_id: str = ""
    call_started: bool = False
    transcript: list = field(default_factory=list)   # [("agent"|"user", text)]
    finalized: bool = False


EPISODES: dict[str, Episode] = {}
BY_CALL: dict[str, Episode] = {}
DAY_LOG = {"day": "", "entries": []}     # today's events from the watch's log screen
WATCH = {"state": {}, "at": 0.0}         # latest mirrored watch screen
HR_HIST: deque = deque(maxlen=180)       # (unix time, bpm) for the demo page's graph
LAST_CALL = {"at": 0.0, "status": ""}    # support-line activity for the demo page
alerts_today = {"day": "", "count": 0}
_background: set = set()


def _spawn(coro):
    task = asyncio.create_task(coro)
    _background.add(task)
    task.add_done_callback(_background.discard)


def _check_token(request: Request):
    if not ALERT_TOKEN:
        raise HTTPException(500, "ALERT_TOKEN is not set on the server")
    if not hmac.compare_digest(request.headers.get("X-CalmBand-Token", ""), ALERT_TOKEN):
        raise HTTPException(401, "bad token")


def _check_vapi(token: str):
    if not VAPI_PATH_TOKEN or not hmac.compare_digest(token, VAPI_PATH_TOKEN):
        raise HTTPException(404)


def _vapi_url(path: str) -> str:
    return f"{PUBLIC_URL}/vapi/{VAPI_PATH_TOKEN}/{path}"


def _store_log(entries, day: str = ""):
    """Keep the watch's log of today's events (time, kind, duration) - plain data, capped."""
    if not isinstance(entries, list):
        return
    clean = []
    for e in entries[-50:]:
        if isinstance(e, dict):
            clean.append({"t": str(e.get("t", ""))[:12], "k": str(e.get("k", ""))[:24],
                          "d": int(e.get("d") or 0) if str(e.get("d") or 0).lstrip("-").isdigit() else 0})
    DAY_LOG.update(day=str(day)[:12] or datetime.now().strftime("%Y-%m-%d"), entries=clean)


# ---------------------------------------------------------------- 1. the watch raises an alert
@app.post("/log")
async def daylog(request: Request):
    _check_token(request)
    data = await request.json()
    if isinstance(data, dict):
        _store_log(data.get("entries"), data.get("day", ""))
        log.info("day log updated: %s", agent.describe_log(DAY_LOG["entries"]))
    return {"ok": True}


@app.post("/alert")
async def alert(request: Request):
    _check_token(request)
    data = await request.json()
    data = data if isinstance(data, dict) else {}
    if "log" in data:
        _store_log(data.pop("log"))
    return _new_episode(data)


@app.post("/demo")
async def demo(request: Request):
    """Same as /alert with plausible numbers, for showing the flow on stage."""
    _check_token(request)
    return _new_episode({"reason": "sustained", "hr": 104, "baseline": 68, "slope": 9.5,
                         "anxSec": 130, "triggers": 1, "motion": 18, "demo": True})


def _new_episode(data: dict) -> dict:
    today = datetime.now().strftime("%Y-%m-%d")
    if alerts_today["day"] != today:
        alerts_today.update(day=today, count=0)
    if alerts_today["count"] >= MAX_ALERTS_PER_DAY:
        log.warning("alert ignored: daily limit (%d) reached", MAX_ALERTS_PER_DAY)
        return {"status": "daily-limit", "number": SUPPORT_NUMBER}
    alerts_today["count"] += 1
    ep = Episode(id=uuid.uuid4().hex[:12], alert=data, created=time.time())
    EPISODES[ep.id] = ep
    log.info("episode %s from watch: %s", ep.id, agent.safe_json(data))
    _spawn(_missed_call_check(ep))
    return {"status": "call-support", "number": SUPPORT_NUMBER, "episode": ep.id}


async def _missed_call_check(ep: Episode):
    await asyncio.sleep(CALL_WAIT_SEC)
    if not ep.call_started and not ep.finalized:
        _finalize(ep, f"{USER_NAME} did not call the support line within {CALL_WAIT_SEC // 60} minutes")


def _latest_open_episode() -> Episode | None:
    open_eps = [e for e in EPISODES.values()
                if not e.call_started and not e.finalized and time.time() - e.created < 3600]
    return max(open_eps, key=lambda e: e.created) if open_eps else None


# ---------------------------------------------------------------- 2. Vapi webhooks
@app.post("/vapi/{token}/webhook")
async def vapi_webhook(token: str, request: Request):
    _check_vapi(token)
    msg = (await request.json()).get("message", {})
    kind = msg.get("type")
    call = msg.get("call") or {}

    if kind == "assistant-request":
        ep = _latest_open_episode()
        if ep is None:   # they called without a recent watch alert: still help
            ep = Episode(id=uuid.uuid4().hex[:12], alert={}, created=time.time())
            EPISODES[ep.id] = ep
        ep.call_started = True
        ep.call_id = call.get("id", "")
        if ep.call_id:
            BY_CALL[ep.call_id] = ep
        log.info("incoming call %s -> episode %s", ep.call_id, ep.id)
        return {"assistant": _assistant(ep)}

    if kind == "end-of-call-report":
        ep = BY_CALL.get(call.get("id", ""))
        if ep is None:
            log.warning("end-of-call-report for unknown call %s", call.get("id"))
            return {}
        artifact = msg.get("artifact") or {}
        for m in artifact.get("messages") or []:
            role, text = m.get("role"), (m.get("message") or "").strip()
            if text and role in ("user", "bot", "assistant"):
                ep.transcript.append(("user" if role == "user" else "agent", text))
        reason = msg.get("endedReason") or call.get("endedReason") or "ended"
        _finalize(ep, f"{USER_NAME} called the support line; call ended ({reason})")
        return {}

    return {}


def _assistant(ep: Episode) -> dict:
    return {
        "name": "CalmBand",
        "firstMessage": agent.first_message(USER_NAME, ep.alert),
        "model": {
            "provider": "custom-llm",
            "url": _vapi_url("llm"),
            "model": "calmband-coach",
            "messages": [{"role": "system", "content": agent.voice_system_prompt(
                USER_NAME, ep.alert, DAY_LOG["entries"])}],
        },
        "endCallPhrases": [agent.GOODBYE],
        "maxDurationSeconds": MAX_CALL_SEC,
        "analysisPlan": {"summaryPrompt": ""},      # we write our own summary (free, via Workers AI)
        "serverMessages": ["end-of-call-report"],
        "server": {"url": _vapi_url("webhook")},
    }


# ---------------------------------------------------------------- 3. the coach's brain (Vapi custom LLM)
@app.post("/vapi/{token}/llm")
@app.post("/vapi/{token}/llm/chat/completions")
async def vapi_llm(token: str, request: Request):
    _check_vapi(token)
    body = await request.json()
    msgs = [m for m in body.get("messages") or []
            if m.get("role") in ("system", "user", "assistant") and isinstance(m.get("content"), str)]
    system = [m for m in msgs if m["role"] == "system"][:1]
    convo = [m for m in msgs if m["role"] != "system"][-HISTORY_TURNS:]
    payload = {"model": agent.CF_MODEL, "stream": True, "max_tokens": 150, "messages": system + convo}
    wants_stream = body.get("stream", True) is not False
    log.info("coach request: stream=%s keys=%s roles=%s", body.get("stream"), sorted(body.keys()),
             [m.get("role") for m in body.get("messages") or []][-6:])

    cid = f"chatcmpl-{uuid.uuid4().hex[:16]}"
    created = int(time.time())
    fallback = "I'm still here with you. Let's breathe in slowly for four, and out for six."

    def chunk(delta: dict, finish=None) -> str:
        """A clean OpenAI chat.completion.chunk, built here rather than passing Cloudflare's through."""
        return "data: " + json.dumps({
            "id": cid, "object": "chat.completion.chunk", "created": created, "model": "calmband-coach",
            "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}) + "\n\n"

    async def pieces():
        """Yield reply text pieces from Workers AI (or a fallback line on any failure)."""
        try:
            async with agent.http().stream("POST", agent.CF_CHAT_URL, json=payload) as r:
                if r.status_code != 200:
                    raise RuntimeError(f"Workers AI HTTP {r.status_code}")
                async for line in r.aiter_lines():
                    if not line.startswith("data: ") or line.strip() == "data: [DONE]":
                        continue
                    for ch in json.loads(line[6:]).get("choices") or []:
                        text = (ch.get("delta") or {}).get("content")
                        if text:
                            yield text
        except Exception as e:  # noqa: BLE001 - never leave the caller in silence
            log.error("coach reply failed: %s", e)
            yield fallback

    if not wants_stream:
        text = "".join([p async for p in pieces()]).strip() or fallback
        log.info("coach reply (non-stream): %s", text[:200])
        return {"id": cid, "object": "chat.completion", "created": created, "model": "calmband-coach",
                "choices": [{"index": 0, "message": {"role": "assistant", "content": text},
                             "finish_reason": "stop"}]}

    async def relay():
        said = []
        yield chunk({"role": "assistant", "content": ""})
        async for p in pieces():
            said.append(p)
            yield chunk({"content": p})
        yield chunk({}, finish="stop")
        yield "data: [DONE]\n\n"
        log.info("coach reply: %s", "".join(said)[:200])

    return StreamingResponse(relay(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})


# ---------------------------------------------------------------- 4. after the call: email
def _finalize(ep: Episode, outcome: str):
    if ep.finalized:
        return
    ep.finalized = True
    _spawn(_notify(ep, outcome))


async def _notify(ep: Episode, outcome: str):
    talked = any(who == "user" for who, _ in ep.transcript)
    summary = await agent.summarize(USER_NAME, ep.alert, ep.transcript, outcome, DAY_LOG["entries"])
    when = datetime.fromtimestamp(ep.created).strftime("%I:%M %p").lstrip("0")
    await _email(THERAPIST_EMAIL, f"CalmBand alert for {USER_NAME} at {when}",
                 f"{summary}\n\n{USER_NAME} {'talked with' if talked else 'did not reach'} the CalmBand "
                 f"support line. Please message or call {USER_NAME} to check in.\n\n- CalmBand", "therapist")
    # The friend gets no clinical details - just a nudge to reach out.
    await _email(FRIEND_EMAIL, f"Could you check in on {USER_NAME}?",
                 f"Hi, this is CalmBand, {USER_NAME}'s wellbeing watch. Around {when} it noticed "
                 f"{USER_NAME} might be having a hard time, and they "
                 f"{'talked with' if talked else 'did not reach'} the support line. "
                 f"A quick text or call from you could really help.\n\n- CalmBand", "friend")


async def _email(to: str, subject: str, body: str, who: str):
    if not to:
        log.warning("no %s email configured; skipping", who)
        return
    if EMAIL_DRY_RUN:
        log.info("[DRY RUN] email to %s (%s): %s\n%s", who, to, subject, body)
        return
    if USE_APPS_SCRIPT:
        try:
            # Apps Script answers a POST with a redirect to the result; follow it.
            r = await agent.http_plain().post(APPS_SCRIPT_URL, follow_redirects=True, json={
                "secret": APPS_SCRIPT_SECRET, "to": to, "subject": subject, "body": body})
            if r.status_code == 200 and r.text.strip() == "ok":
                log.info("email to %s sent", who)
            else:
                log.error("email to %s failed: HTTP %s %s", who, r.status_code, r.text[:200])
        except Exception as e:  # noqa: BLE001
            log.error("email to %s failed: %s", who, e)
        return
    msg = EmailMessage()
    msg["From"] = f"CalmBand <{GMAIL_ADDRESS}>"
    msg["To"] = to
    msg["Subject"] = subject
    msg.set_content(body)

    def send():
        with smtplib.SMTP_SSL("smtp.gmail.com", 465, timeout=30) as s:
            s.login(GMAIL_ADDRESS, GMAIL_APP_PASSWORD)
            s.send_message(msg)

    try:
        await asyncio.to_thread(send)
        log.info("email to %s sent", who)
    except Exception as e:  # noqa: BLE001 - never let one failed email stop the other
        log.error("email to %s failed: %s", who, e)


# ---------------------------------------------------------------- 5. live demo page
@app.post("/watch/state")
async def watch_state(request: Request):
    """The watch mirrors its screen here every ~2 s (MIRROR_DISPLAY in Config.mc)."""
    _check_token(request)
    data = await request.json()
    if isinstance(data, dict):
        prev = WATCH["state"]
        if (prev.get("st"), prev.get("pd"), prev.get("vib")) != (data.get("st"), data.get("pd"), data.get("vib")):
            print(f"[watch] st={data.get('st')} tp={data.get('tp')} pd={data.get('pd')} "
                  f"vib={data.get('vib')} pulse={data.get('pulse')!r} status={data.get('status')!r}", flush=True)
        WATCH.update(state=data, at=time.time())
        hr = data.get("hr")
        if isinstance(hr, int) and 30 <= hr <= 230:
            HR_HIST.append((round(time.time()), hr))
    return {"ok": True}


def _check_display(token: str):
    if not DISPLAY_TOKEN or not hmac.compare_digest(token, DISPLAY_TOKEN):
        raise HTTPException(404)


def _page() -> HTMLResponse:
    return HTMLResponse((Path(__file__).parent / "static" / "display.html").read_text(encoding="utf-8"),
                        headers={"Cache-Control": "no-store"})


# Short address for the demo: <PUBLIC_URL>/live (the random tunnel hostname keeps it unguessable).
@app.get("/live", response_class=HTMLResponse)
async def live_page():
    return _page()


# The bare address opens the live page.
@app.get("/", include_in_schema=False)
async def root():
    return RedirectResponse("/live")


@app.get("/live/state")
async def live_state():
    return _display_payload()


# Same page behind a secret key, for when the server has a permanent public address.
@app.get("/display/{token}", response_class=HTMLResponse)
async def display_page(token: str):
    _check_display(token)
    return _page()


@app.get("/display/{token}/state")
async def display_state(token: str):
    _check_display(token)
    return _display_payload()


def _display_payload() -> dict:
    in_call = any(e.call_started and not e.finalized for e in EPISODES.values())
    return {
        "watch": WATCH["state"],
        "age": round(time.time() - WATCH["at"], 1) if WATCH["at"] else None,
        "hrHist": list(HR_HIST),
        "log": DAY_LOG["entries"],
        "user": USER_NAME,
        "supportNumber": SUPPORT_NUMBER,
        "inCall": in_call,
    }


@app.get("/health")
async def health():
    return {"ok": True, "ai": agent.PROVIDER, "emailDryRun": EMAIL_DRY_RUN,
            "alertsToday": alerts_today["count"], "episodes": len(EPISODES)}
