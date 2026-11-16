# CalmBand

On-watch "why is my heart rate up?" classifier + paced-breathing haptics.

Pipeline: HR (1 Hz) + 25 Hz wrist accelerometer + GPS speed
-> features (HR elevation vs a learned resting baseline, 90 s HR trend, recent-movement memory)
-> probabilistic scoring (softmax over CALM / ACTIVE / ANXIETY / NIGHTMARE / EXCITED / RECOVERING)
-> haptic coach (vibration swells on inhale, fades on exhale) only for distress states.
Movement or recent movement suppresses it (standing up, walking, eating, exercise recovery).

Field findings on the FR165 (2 h of real wear): the watch gives third-party apps no HRV (no beat
intervals), no respiration rate, and a stuck stress score, so none of those are used. The app keeps
running with the screen off. A startle detector was removed: startles barely moved HR.

## Setup (once)
1. Install the Connect IQ SDK Manager from developer.garmin.com/connect-iq, download the latest SDK and the FR165 device.
2. Install VS Code + the "Monkey C" extension. Run "Monkey C: Verify Installation" (it generates a developer key).
3. Open this `calmband` folder in VS Code.

## Buttons
- DOWN: DISMISS a false positive. Stops the vibration at once, takes that state out of
  the classifier for 5 minutes, and tags the recording as "dismissed".
- UP: open / close the legend screen (swiping down / up does the same if touch works).
  Sleep is automatic: 23:00-07:00 with no wrist movement.
- START (or tap): mark "the app's reading is off right now" (tags ~45 s of the recording, no dismissal)
- BACK: back to the main screen from the legend, otherwise exit and save the recording

## Screens
- Main screen: clean view (confidence ring, heart rate, state, probability bar, status line).
- Swipe up (or UP) for the legend, again for Settings; swipe down goes back up, BACK returns to main.
- Settings: Parkinson's mode toggle (START; remembered across restarts, off by default), and the
  therapist / emergency contact numbers (set in `source/Config.mc`).

## Parkinson's mode (experimental, not clinically validated)
When on, the watch looks for a rhythmic 3.5-7.5 Hz wrist shake (typical Parkinson's rest tremor is
4-6 Hz) using Goertzel filters on the last ~2.6 s of 25 Hz accelerometer data, compared with slower
movement (walking arm swing ~1-2 Hz) and faster jitter. A tremor that holds for several seconds
(band share > 60%, amplitude 15-1500 mg, not exercising) starts ~30 s of short, steady pulses once a
second. DOWN stops and snoozes it for 5 minutes. The tremor band share is recorded (`tremor_pct`).

## Run in the simulator
F5 / "Run without debugging", pick `fr165`. (There is no built-in demo data; use the real watch.)

## Recording
Every run records a FIT activity with custom fields (state, confidence, baseline, elevation, slope,
motion, memories, vibration, your START marks). Exit with BACK to save it; pull the .fit from
`GARMIN/Activity`.

## Put it on your watch (no store needed)
"Monkey C: Build for Device" -> pick fr165 -> output `bin/CalmBand.prg`.
Plug in the watch by USB and copy the .prg to `GARMIN/Apps/`. Open it from the app list.

## Support line (Vapi + Cloudflare Workers AI + email), all on free tiers

When the watch sees ANXIETY for a sustained stretch, or anxiety calming sessions keep coming back,
it buzzes three times and shows "getting support in 10s". Dismissing (DOWN) stops it. Otherwise it
sends the episode to the CalmBand server (through the phone's Garmin Connect app) and shows
"call support" with the support number. You call that free Vapi number; the server gives Vapi a
voice coach that already knows what the watch saw. It asks whether you're driving, gets you seated,
and talks you through breathing and grounding. The coach's replies come from Cloudflare Workers AI
(`@cf/meta/llama-3.1-8b-instruct-fast`), proxied by the server. After the call, a summary is
emailed to your therapist, and a short check-in (no clinical details) to your trusted friend. If
you don't call within `CALL_WAIT_SEC` (10 min), both are emailed anyway.

Thresholds are in `source/Config.mc`. With `DEMO_MODE = true`: 30 s of continuous anxiety, or
2 calming sessions within 5 minutes. With `DEMO_MODE = false`: 2 minutes, or 2 within 30 minutes.

Free-tier guards in `server/.env`: `MAX_CALL_SEC` (7 min), `MAX_ALERTS_PER_DAY` (10), and only
the last 12 turns are sent to the AI per reply.

### Server setup
1. `cd server`, `python -m venv .venv`, `.venv\Scripts\activate`, `pip install -r requirements.txt`
2. Copy `.env.example` to `.env` and fill it in.
3. Start it: `uvicorn app:app --port 8000`
4. Tunnel: `cloudflared tunnel --url http://localhost:8000`; put the printed `https://...` URL in
   `.env` as `PUBLIC_URL` and restart the server.
5. `python setup_vapi.py` points your Vapi number at the server (re-run when the URL changes).
6. Copy `config/Config.example.mc` to `source/Config.mc` (it isn't committed), put the URL,
   `ALERT_TOKEN` and the Vapi number in it, rebuild, copy to the watch.

Without Gmail settings, emails run in DRY RUN mode (logged, not sent).

### Host it on Render (free, permanent URL)
1. Push this repo to GitHub. In the Render dashboard: New > Blueprint, pick the repo. It reads
   `render.yaml` (Python web service, `server/` folder, free plan).
2. Render asks for each secret; copy them from `server/.env`. `PUBLIC_URL` isn't needed: the
   server uses Render's own `https://<name>.onrender.com` address.
3. When it's live, check `https://<name>.onrender.com/health`, then open `/live`.
4. Point Vapi at it: in your local `server/.env` set `PUBLIC_URL=https://<name>.onrender.com`
   and run `python setup_vapi.py`.
5. Put the same URL in `source/Config.mc`, rebuild and copy to the watch. It never changes again.

Free services sleep after ~15 minutes without requests and take ~1 minute to wake. The watch
sends its state every 2 s, so it stays awake while the app runs; open `/live` a minute before a
demo. Episodes are kept in memory, so a restart or sleep clears them. `/live` is public on a
guessable address; use `/display/<DISPLAY_TOKEN>` if that matters.

### Accounts needed (free)
- **Vapi** (vapi.ai): sign up ($5 credit), create the free phone number, copy the private API key.
- **Gmail**: turn on 2-step verification, then create an app password (Google Account -> Security
  -> App passwords) for `GMAIL_APP_PASSWORD`.
- **Cloudflare**: account ID + an API token with Workers AI access.

### Demo on stage
`POST /demo` with header `X-CalmBand-Token` creates an episode with sample watch numbers; then
call the support number. E.g. `curl -X POST https://<tunnel>/demo -H "X-CalmBand-Token: <token>"`.

## Tuning
Thresholds and weights are in `source/Classifier.mc` (hand-set priors, informed by one person's
recordings). Cooldown between interventions is in `Haptics.cooldownSec` (120 s live, 20 s in demo).
