// Copy this file to source/Config.mc and fill it in (source/Config.mc is not committed).
// ---- CalmBand escalation settings (edit, then rebuild) ----

// Public HTTPS URL of the CalmBand server (your tunnel), no trailing slash.
const SERVER_URL = "https://your-tunnel.trycloudflare.com";
// The free Vapi support number the watch tells you to call (+1 format)
const SUPPORT_NUMBER = "+15555550100";
// Shown on the watch's settings page (+1 format; "" shows "not set")
const THERAPIST_NUMBER = "";
const EMERGENCY_NUMBER = "";   // trusted friend
// Must match ALERT_TOKEN in server/.env
const ALERT_TOKEN = "change-me-to-a-long-random-string";

// Send the watch screen's state to the server every ~2 s for the live demo page.
const MIRROR_DISPLAY = true;

// true  = short windows so a call can be shown live (hackathon demo)
// false = real-life windows
const DEMO_MODE = true;

// Escalate to a phone call when ANXIETY is the reading for this long without a break...
const SUSTAIN_SEC_REAL = 120;
const SUSTAIN_SEC_DEMO = 30;
// ...or when this many anxiety calming sessions (not dismissed) happen within the window.
const REPEAT_COUNT = 2;
const REPEAT_WINDOW_SEC_REAL = 1800;
const REPEAT_WINDOW_SEC_DEMO = 300;
// Seconds before the call is placed (dismissing the alert in that time means no call).
const CANCEL_GRACE_SEC = 10;
// No second call within this many seconds.
const CALL_COOLDOWN_SEC_REAL = 1800;
const CALL_COOLDOWN_SEC_DEMO = 120;
