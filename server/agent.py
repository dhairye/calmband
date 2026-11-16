"""The AI side of CalmBand: the voice coach's instructions and the after-call summary.

The live call's AI is Cloudflare Workers AI (free daily allowance), reached by Vapi through this
server (see app.py /vapi/.../llm). The summary also uses Workers AI, unless ANTHROPIC_API_KEY is
set, in which case Claude writes it.
"""
import json
import logging
import os

import httpx2

log = logging.getLogger("calmband.agent")

CF_ACCOUNT = os.environ.get("CLOUDFLARE_ACCOUNT_ID", "")
CF_TOKEN = os.environ.get("CLOUDFLARE_API_TOKEN", "")
# Small, fast model: ~0.5 s to first word, and the lightest on the free allowance.
CF_MODEL = os.environ.get("CLOUDFLARE_MODEL", "@cf/meta/llama-3.1-8b-instruct-fast")
CF_CHAT_URL = f"https://api.cloudflare.com/client/v4/accounts/{CF_ACCOUNT}/ai/v1/chat/completions"
USE_CLAUDE = bool(os.environ.get("ANTHROPIC_API_KEY"))
PROVIDER = "claude" if USE_CLAUDE else ("workers-ai" if CF_ACCOUNT and CF_TOKEN else "none")

# The coach ends the call by saying exactly this; Vapi hangs up when it hears it.
GOODBYE = "Take care. Goodbye."

_http = None


def http() -> httpx2.AsyncClient:
    global _http
    if _http is None:
        _http = httpx2.AsyncClient(headers={"Authorization": f"Bearer {CF_TOKEN}"}, timeout=30)
    return _http


_plain = None


def http_plain() -> httpx2.AsyncClient:
    """HTTP client without the Cloudflare token (for the Apps Script email relay)."""
    global _plain
    if _plain is None:
        _plain = httpx2.AsyncClient(timeout=30)
    return _plain


def describe_alert(alert: dict) -> str:
    """Turn the watch's payload into a short factual description."""
    if not alert:
        return "No recent watch alert was found; they called on their own."
    if alert.get("demo") or alert.get("reason") == "demo":
        return (f"DEMO TRIGGER (started by hand, not a real detection). Live readings at the time: "
                f"heart rate {alert.get('hr', '?')} bpm, resting baseline about {alert.get('baseline', '?')} bpm.")
    reason = alert.get("reason", "unknown")
    why = {
        "sustained": "the anxiety pattern lasted continuously",
        "repeated": "the anxiety pattern came back several times in a short window",
    }.get(reason, "an anxiety-like pattern was detected")
    return (
        f"Trigger: {why}. Heart rate {alert.get('hr', '?')} bpm against a resting "
        f"baseline of about {alert.get('baseline', '?')} bpm; HR trend "
        f"{alert.get('slope', '?')} bpm/min; anxious reading for {alert.get('anxSec', '?')} s; "
        f"{alert.get('triggers', '?')} calming sessions in the window; wrist mostly still "
        f"(motion {alert.get('motion', '?')} mg). These are wrist-sensor estimates and can be wrong."
    )


def describe_log(entries) -> str:
    """Today's watch log as one line, e.g. '2:05 PM anxiety (6 min); 4:10 PM exercise (25 min)'."""
    parts = []
    for e in entries or []:
        mins = round((e.get("d") or 0) / 60)
        dur = f" ({mins} min)" if mins >= 1 else ""
        parts.append(f"{e.get('t', '?')} {e.get('k', 'event')}{dur}")
    return "; ".join(parts) if parts else "nothing logged yet today"


def first_message(user_name: str, alert: dict) -> str:
    if alert:
        return (f"Hi {user_name}, this is CalmBand. Thanks for calling. Your watch noticed your heart "
                "rate climbing while you were sitting still. First, are you driving right now?")
    return f"Hi {user_name}, this is CalmBand. I'm here with you. First, are you driving right now?"


def voice_system_prompt(user_name: str, alert: dict, log=None) -> str:
    return f"""You are CalmBand, a calm, warm voice on a phone call with {user_name}. Their smartwatch \
detected signs that they may be anxious and asked them to call you. You are not a therapist or a doctor \
and you never diagnose. Your job is to help them feel safer and calmer right now, in a few minutes.

What the watch saw: {describe_alert(alert)}
Today's watch log (events the watch noticed and they did not dismiss): {describe_log(log)}
You may gently use the log for context - e.g. noticing it has been a tense day, or that they exercised \
earlier - but don't read it out like a report.

You already opened the call with: "{first_message(user_name, alert)}"

How to talk:
- This is speech. Use short, plain sentences, one or two at a time, then pause for them. No lists, \
markdown, emoji, or stage directions.
- Be gentle and unhurried. Reflect what they say before suggesting anything.
- If they are driving: do not give eyes-closed or long exercises. Ask them to keep their eyes on the road, \
breathe out slowly, and pull over somewhere safe when they can.
- If they are not driving: ask them to sit down if they can, feet flat on the floor. Then guide one \
technique at a time, counting it out slowly - for example breathing in for four, holding for four, out \
for six - or a 5-4-3-2-1 grounding exercise (things they can see, touch, hear).
- Ask how they feel after each round. If it was a false alarm, accept that warmly and keep it brief.
- If they mention wanting to hurt themselves, suicidal thoughts, chest pain, trouble breathing, or \
fainting: tell them clearly to call 911 for an emergency or 988 for the Suicide and Crisis Lifeline, \
and stay supportive.
- Only promise things you can do. You can tell them their therapist and a trusted friend will get a \
short note after the call.
- When they say they are okay or want to hang up, give one short kind line and end with exactly: \
"{GOODBYE}" Never say that phrase at any other time."""


async def summarize(user_name: str, alert: dict, transcript: list, call_outcome: str, log=None) -> str:
    """Write the therapist note. Falls back to a plain template if the AI call fails."""
    lines = "\n".join(f"{who.upper()}: {text}" for who, text in transcript) or "(no conversation)"
    prompt = f"""Write a brief note to {user_name}'s therapist about a CalmBand episode. CalmBand is a \
wrist-worn app that detects possible anxiety from heart rate and movement and then offers a supportive \
AI voice call.

Watch data: {describe_alert(alert)}
Today's watch log: {describe_log(log)}
Call outcome: {call_outcome}

Call transcript (the caller's speech is machine-transcribed and may contain errors):
<transcript>
{lines}
</transcript>

Write plain text, at most 700 characters, no markdown. Cover: what triggered it; the pattern of the day \
from the log if relevant; symptoms or behaviours \
{user_name} reported (only what the transcript supports - say so if nothing was reported); what helped \
and how they seemed at the end; any safety concern mentioned (state it first if present). Use neutral, \
factual language and do not diagnose. Do not include a greeting or sign-off."""
    try:
        text = ""
        if USE_CLAUDE:
            import anthropic

            resp = await anthropic.AsyncAnthropic().beta.messages.create(
                model="claude-opus-5-5",
                max_tokens=4000,
                betas=["server-side-fallback-2026-07-01"],
                fallbacks="default",
                messages=[{"role": "user", "content": prompt}],
            )
            if resp.stop_reason != "refusal":
                text = "".join(b.text for b in resp.content if b.type == "text").strip()
        elif PROVIDER == "workers-ai":
            r = await http().post(CF_CHAT_URL, json={
                "model": CF_MODEL, "max_tokens": 300,
                "messages": [{"role": "user", "content": prompt}]})
            r.raise_for_status()
            text = (r.json()["choices"][0]["message"]["content"] or "").strip()
        if text:
            return text[:1500]
    except Exception as e:  # noqa: BLE001 - a failed summary must never block the notifications
        log.warning("summary failed, using template: %s", e)
    return f"{describe_alert(alert)} Call outcome: {call_outcome}. (Automatic summary unavailable.)"


def safe_json(obj) -> str:
    return json.dumps(obj, default=str)
