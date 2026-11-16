using Toybox.Attention;

// Haptic "kind" for Parkinson's tremor cueing (outside the classifier's state numbers).
const TREMOR_KIND = 100;

// Plays paced-breathing haptics: vibration swells on the inhale and fades on the
// exhale, so you can follow it with your eyes closed (or asleep) and slow down
// your breathing to ~6-10 breaths/min, which raises vagal tone and lowers HR.
class Haptics {
    var pattern = [];      // vibration strength (0-100) for each second
    var idx = 0;
    var active = false;
    var level = 0;         // current vibration strength (drives the on-screen breathing circle)
    var kind = -1;
    var lastEndSec = -100000;
    var cooldownSec = 120;

    function initialize() {}

    hidden function breathe(out, cycles, peak, inhale, exhale) {
        for (var c = 0; c < cycles; c++) {
            for (var i = 1; i <= inhale; i++) {
                out.add(peak * i / inhale);
            }
            for (var j = 0; j < exhale; j++) {
                out.add(peak * (exhale - j) / (exhale + 1));
            }
        }
    }

    function buildPattern(k) {
        var p = [];
        if (k == C_ANXIETY) {
            breathe(p, 8, 80, 4, 6);          // 6 breaths/min, ~80 s
        } else if (k == C_NIGHTMARE) {
            breathe(p, 6, 30, 4, 6);          // very gentle so it soothes without waking
        } else if (k == C_EXCITED) {
            breathe(p, 3, 50, 4, 6);
        } else if (k == TREMOR_KIND) {
            // ~30 s of short, even pulses once a second: a steady rhythm to focus on
            for (var i = 0; i < 30; i++) { p.add(45); }
        }
        return p;
    }

    function trigger(k, nowSec) {
        if (active || (nowSec - lastEndSec) < cooldownSec) {
            return false;
        }
        var p = buildPattern(k);
        if (p.size() == 0) {
            return false;
        }
        pattern = p;
        idx = 0;
        kind = k;
        active = true;
        return true;
    }

    function cancel(nowSec) {
        level = 0;
        if (active) {
            active = false;
            lastEndSec = nowSec;
            kind = -1;
        }
    }

    // call once per second
    function tick(nowSec) {
        if (!active) {
            return;
        }
        if (idx >= pattern.size()) {
            cancel(nowSec);
            return;
        }
        var duty = pattern[idx];
        idx++;
        var tremor = (kind == TREMOR_KIND);
        level = tremor ? 0 : duty;            // the breathing circle is only for breathing patterns
        if (duty > 0 && (Attention has :vibrate)) {
            Attention.vibrate([new Attention.VibeProfile(duty, tremor ? 250 : 700)]);
        }
    }

    // strong triple buzz: "a support call is about to be placed"
    function alert() {
        if (Attention has :vibrate) {
            Attention.vibrate([
                new Attention.VibeProfile(100, 300), new Attention.VibeProfile(0, 150),
                new Attention.VibeProfile(100, 300), new Attention.VibeProfile(0, 150),
                new Attention.VibeProfile(100, 300)
            ]);
        }
    }

    // soft double tap: "you can still call CalmBand"
    function nudge() {
        if (Attention has :vibrate) {
            Attention.vibrate([
                new Attention.VibeProfile(60, 250), new Attention.VibeProfile(0, 200),
                new Attention.VibeProfile(60, 250)
            ]);
        }
    }

    // button-press self test
    function test() {
        if (Attention has :vibrate) {
            Attention.vibrate([new Attention.VibeProfile(70, 500)]);
        }
    }
}
