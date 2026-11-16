import Toybox.Lang;
using Toybox.WatchUi;
using Toybox.Graphics;
using Toybox.Timer;

// Two screens stacked vertically: 0 = main, 1 = button legend. Changing page slides between
// them (main moves up, legend rises from below). Page dots on the right edge show where you are.
//   main:   outer ring (colour = state, sweep = confidence), heart rate, state name,
//           thin stacked probability bar, status line
//   a soft circle swells/fades behind the numbers while the haptic coach runs
const TREMOR_COLOR = 0xF472B6;   // Parkinson's TREMOR stage (rose)

class CalmView extends WatchUi.View {
    var pos = 0.0;            // 0.0 = main fully shown, 1.0 = legend fully shown (animated)
    var animating = false;
    var animTimer;

    function initialize() {
        View.initialize();
        animTimer = new Timer.Timer();
    }

    function onHide() as Void {
        animTimer.stop();
        animating = false;
    }

    // one animation frame (~30 fps): ease `pos` toward the target page
    function step() as Void {
        animating = false;
        var e = getApp().engine;
        if (e == null) { return; }
        var target = e.page.toFloat();
        pos += (target - pos) * 0.35;
        if ((target - pos).abs() < 0.01) { pos = target; }
        WatchUi.requestUpdate();
    }

    hidden function colorFor(k) {
        if (k == C_CALM) { return 0x3DDC97; }
        if (k == C_EXERCISE) { return 0x4DA3FF; }
        if (k == C_ANXIETY) { return 0xFFA630; }
        if (k == C_NIGHTMARE) { return 0xA678FF; }
        if (k == C_RECOVER) { return 0x5ED3F3; }
        return 0xFFD93D;
    }

    // "+15305551234" -> "(530) 555-1234"
    hidden function prettyNumber(n) {
        if (n.length() == 12 && n.substring(0, 2).equals("+1")) {
            return "(" + n.substring(2, 5) + ") " + n.substring(5, 8) + "-" + n.substring(8, 12);
        }
        return n;
    }

    hidden function dim(c, f) {
        var r = (((c >> 16) & 0xFF) * f).toNumber();
        var g = (((c >> 8) & 0xFF) * f).toNumber();
        var b = ((c & 0xFF) * f).toNumber();
        return (r << 16) | (g << 8) | b;
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        var e = getApp().engine;
        var w = dc.getWidth();
        var h = dc.getHeight();

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();
        if (e == null) { return; }

        // escalation nudge takes over the whole screen
        if (e.nudgeActive) {
            drawNudge(dc, e, w, h);
            return;
        }

        var target = e.page.toFloat();
        if (pos != target && !animating) {
            animating = true;
            animTimer.start(method(:step), 33, false);
        }

        // four screens stacked vertically: main (0), legend (1), logs (2), settings (3)
        var shift = pos * h;
        if (pos < 0.999) { drawMain(dc, e, w, h, -shift); }
        if (pos > 0.001 && pos < 1.999) { drawLegend(dc, w, h, h - shift); }
        if (pos > 1.001 && pos < 2.999) { drawLogs(dc, e, w, h, 2 * h - shift); }
        if (pos > 2.001) { drawSettings(dc, e, w, h, 3 * h - shift); }
        drawDots(dc, w, h);
    }

    hidden function logColor(k) {
        if (k.equals("anxiety")) { return 0xFFA630; }
        if (k.equals("exercise")) { return 0x4DA3FF; }
        if (k.equals("support alert")) { return 0xFF8A5C; }
        if (k.equals("tremor")) { return TREMOR_COLOR; }
        if (k.equals("nightmare")) { return 0x8FA3B8; }
        return 0xFFD93D;                       // excited
    }

    hidden function shortDur(sec) {
        if (sec < 60) { return ""; }
        var m = sec / 60;
        return (m < 60) ? (m + "m") : ((m / 60) + "h" + (m % 60 > 0 ? " " + (m % 60) + "m" : ""));
    }

    // Today's log: newest first, time on the left, a small colour dot, then the event and how long.
    hidden function drawLogs(dc, e, w, h, oy) {
        var cx = w / 2;
        dc.setColor(0x8A8A8A, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, oy + h * 0.14, Graphics.FONT_XTINY, "TODAY", Graphics.TEXT_JUSTIFY_CENTER);
        var list = e.daylog.entries;
        if (list.size() == 0) {
            dc.setColor(0x6A6A6A, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, oy + h * 0.47, Graphics.FONT_TINY, "nothing logged yet",
                        Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            return;
        }
        var rows = list.size() < 5 ? list.size() : 5;
        for (var i = 0; i < rows; i++) {
            var it = list[list.size() - 1 - i];
            var y = oy + h * (0.30 + 0.105 * i);
            dc.setColor(0xA0A0A0, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w * 0.40, y, Graphics.FONT_XTINY, it["t"], Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);
            dc.setColor(logColor(it["k"]), Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(w * 0.44, y, 4);
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            var d = shortDur(it["d"]);
            dc.drawText(w * 0.48, y, Graphics.FONT_XTINY, it["k"] + (d.length() > 0 ? " " + d : ""),
                        Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        }
        if (list.size() > 5) {
            dc.setColor(0x6A6A6A, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, oy + h * 0.82, Graphics.FONT_XTINY, "+" + (list.size() - 5) + " earlier",
                        Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    // Settings: Parkinson's mode toggle + the therapist / emergency numbers (set in Config.mc).
    hidden function drawSettings(dc, e, w, h, oy) {
        var cx = w / 2;
        dc.setColor(0x8A8A8A, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, oy + h * 0.14, Graphics.FONT_XTINY, "SETTINGS", Graphics.TEXT_JUSTIFY_CENTER);

        // Parkinson's mode row with an ON/OFF pill
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w * 0.14, oy + h * 0.33, Graphics.FONT_TINY, "Parkinson's",
                    Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        var pw = w * 0.22;
        var ph = h * 0.085;
        var px = w * 0.86 - pw;
        var py = oy + h * 0.33 - ph / 2;
        dc.setColor(e.parkinsonMode ? 0x3DDC97 : 0x3A3A3A, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(px, py, pw, ph, ph / 2);
        dc.setColor(e.parkinsonMode ? Graphics.COLOR_BLACK : 0xA0A0A0, Graphics.COLOR_TRANSPARENT);
        dc.drawText(px + pw / 2, oy + h * 0.33, Graphics.FONT_XTINY, e.parkinsonMode ? "ON" : "OFF",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(0x6A6A6A, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, oy + h * 0.415, Graphics.FONT_XTINY, "START to toggle",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // contacts
        dc.setColor(0x8A8A8A, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, oy + h * 0.53, Graphics.FONT_XTINY, "Therapist",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, oy + h * 0.595, Graphics.FONT_TINY, contact(THERAPIST_NUMBER),
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(0x8A8A8A, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, oy + h * 0.69, Graphics.FONT_XTINY, "Emergency contact",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(0xFF5468, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, oy + h * 0.755, Graphics.FONT_TINY, contact(EMERGENCY_NUMBER),
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    hidden function contact(n) {
        return (n == null || n.length() == 0) ? "not set" : prettyNumber(n);
    }

    // Full-screen nudge to call the CalmBand support line. A soft circle slowly swells and
    // settles (4 s cycle) behind the text so the screen feels calm, not alarming.
    hidden function drawNudge(dc, e, w, h) {
        var cx = w / 2;
        var cy = h / 2;
        var accent = 0xFF8A5C;
        var phase = e.seconds % 4;
        var swell = (phase < 2) ? phase : 4 - phase;     // 0,1,2,1,...
        dc.setColor(0x2A170D, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(cx, cy, w * 0.30 + w * 0.025 * swell);

        dc.setPenWidth(w * 0.025);
        dc.setColor(accent, Graphics.COLOR_TRANSPARENT);
        dc.drawCircle(cx, cy, cx - 6);
        dc.setPenWidth(1);

        dc.setColor(0xA0A0A0, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.19, Graphics.FONT_XTINY, "TAKE A MOMENT", Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.34, Graphics.FONT_MEDIUM, "Call CalmBand",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(accent, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.455, Graphics.FONT_SMALL, prettyNumber(SUPPORT_NUMBER),
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(0xA0A0A0, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.565, Graphics.FONT_XTINY, "your heart rate has",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(cx, h * 0.645, Graphics.FONT_XTINY, "been up for a while",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w * 0.42, h * 0.755, Graphics.FONT_XTINY, "START", Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(w * 0.42, h * 0.835, Graphics.FONT_XTINY, "DOWN", Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(0xA0A0A0, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w * 0.46, h * 0.755, Graphics.FONT_XTINY, "I'm calling", Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(w * 0.46, h * 0.835, Graphics.FONT_XTINY, "not now", Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // page indicator: four dots on the right edge, the filled one slides with the animation
    hidden function drawDots(dc, w, h) {
        var x = w * 0.925;
        var y0 = h / 2 - 36;
        dc.setColor(0x3A3A3A, Graphics.COLOR_TRANSPARENT);
        for (var i = 0; i < 4; i++) { dc.fillCircle(x, y0 + 24 * i, 4); }
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(x, y0 + 24 * pos, 4);
    }

    hidden function drawLegend(dc, w, h, oy) {
        var cx = w / 2;
        var keys = ["START", "DOWN", "UP", "BACK"];
        var what = ["mark wrong", "snooze / next", "change mode", "exit & save"];
        var cols = [0xFFD93D, 0xFF8A5C, 0x5ED3F3, 0x8A8A8A];
        dc.setColor(0x8A8A8A, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, oy + h * 0.14, Graphics.FONT_XTINY, "BUTTONS", Graphics.TEXT_JUSTIFY_CENTER);
        // columns sit left of centre so the longest line clears the page dots on the right edge
        for (var i = 0; i < 4; i++) {
            var y = oy + h * (0.30 + 0.12 * i);
            dc.setColor(cols[i], Graphics.COLOR_TRANSPARENT);
            dc.drawText(w * 0.36, y, Graphics.FONT_TINY, keys[i], Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w * 0.40, y, Graphics.FONT_TINY, what[i], Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        }
        dc.setColor(0x6A6A6A, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, oy + h * 0.78, Graphics.FONT_XTINY, "BACK to main screen", Graphics.TEXT_JUSTIFY_CENTER);
    }

    hidden function drawMain(dc, e, w, h, oy) {
        var cx = w / 2;
        var cy = h / 2;
        var c = e.classifier;
        var tremor = e.tremorStage();         // Parkinson's mode: TREMOR replaces the state
        var top = c.top;
        var col = tremor ? TREMOR_COLOR : colorFor(top);
        var conf = tremor ? e.tremorPct() / 100.0 : c.probs[top];


        // outer ring: dark track + confidence arc
        dc.setPenWidth(w * 0.025);
        dc.setColor(0x1E1E1E, Graphics.COLOR_TRANSPARENT);
        dc.drawCircle(cx, cy + oy, cx - 6);
        if (conf > 0.02) {
            if (conf > 0.995) { conf = 0.995; }
            dc.setColor(col, Graphics.COLOR_TRANSPARENT);
            dc.drawArc(cx, cy + oy, cx - 6, Graphics.ARC_CLOCKWISE, 90, 90 - 360 * conf);
        }
        dc.setPenWidth(1);

        // mode label
        var mode = e.modeName();
        if (e.parkinsonMode) { mode = mode + " + PD"; }
        dc.setColor(0x8A8A8A, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, oy + h * 0.13, Graphics.FONT_XTINY, mode, Graphics.TEXT_JUSTIFY_CENTER);

        // heart rate
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, oy + h * 0.38, Graphics.FONT_NUMBER_HOT, e.hr > 0 ? e.hr.format("%d") : "--",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(0x8A8A8A, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, oy + h * 0.54, Graphics.FONT_XTINY, "bpm", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // state name
        dc.setColor(col, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, oy + h * 0.65, Graphics.FONT_SMALL, tremor ? "TREMOR" : CLASS_NAMES[top],
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // thin stacked probability bar
        var bw = w * 0.42;
        var bx = cx - bw / 2;
        var by = oy + h * 0.745;
        dc.setColor(0x1E1E1E, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(bx, by, bw, 6, 3);
        if (tremor) {
            dc.setColor(TREMOR_COLOR, Graphics.COLOR_TRANSPARENT);
            if (bw * conf >= 1.0) { dc.fillRectangle(bx, by, bw * conf, 6); }
        } else {
            var x = bx;
            for (var i = 0; i < N_CLASSES; i++) {
                var sw = bw * c.probs[i];
                if (sw >= 1.0) {
                    dc.setColor(colorFor(i), Graphics.COLOR_TRANSPARENT);
                    dc.fillRectangle(x, by, sw, 6);
                    x += sw;
                }
            }
        }

        // status line (only when something is happening)
        if (e.callState == 1) {
            // support call countdown takes over the status line
            var left = e.countdownEnd - e.seconds;
            if (left < 0) { left = 0; }
            dc.setColor(0xFF8A5C, Graphics.COLOR_TRANSPARENT);
            // shortest wording, nudged up a little, so it clears the ring at the bottom
            dc.drawText(cx, oy + h * 0.78, Graphics.FONT_XTINY, "support in " + left + "s",
                        Graphics.TEXT_JUSTIFY_CENTER);
            return;
        }
        if (e.callState >= 2 && e.seconds < e.callMsgUntil) {
            // after an escalation: show the number to call
            dc.setColor(0xFF8A5C, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, oy + h * 0.80, Graphics.FONT_XTINY, e.callMsg, Graphics.TEXT_JUSTIFY_CENTER);
            dc.drawText(cx, oy + h * 0.865, Graphics.FONT_XTINY, prettyNumber(SUPPORT_NUMBER),
                        Graphics.TEXT_JUSTIFY_CENTER);
            return;
        }
        // green while vibrating; gray one-off messages disappear after 5 s (Engine.statusLine)
        var status = e.statusLine();
        var live = tremor ? TREMOR_COLOR : 0x3DDC97;       // colour of "something is happening" text
        if (status.length() > 0) {
            dc.setColor(e.haptics.active ? live : 0xA0A0A0, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, oy + h * 0.78, Graphics.FONT_XTINY, status, Graphics.TEXT_JUSTIFY_CENTER);
        }
    }
}
