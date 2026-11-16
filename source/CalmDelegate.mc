import Toybox.Lang;
using Toybox.WatchUi;
using Toybox.Timer;
using Toybox.System;

// Screens: 0 = main (top), 1 = legend, 2 = today's log, 3 = settings (bottom).
// The view slides between them.
// On the settings screen START toggles Parkinson's mode.
// Physical buttons
//   DOWN  -> while vibrating: snooze (stops it, silences that state / tremor response for 5 min);
//            otherwise: next screen down (main -> legend -> today -> settings -> main)
//   UP    -> mode: live -> sleep (nightmare watch) -> anxiety simulation -> live
//   START -> mark "the app's reading is off right now" (tags ~45 s of the recording)
//   BACK  -> back to the main screen from another screen, otherwise exit and save
// Touch screen (screens only, never dismiss)
//   swipe up -> next screen down,  swipe down -> back up,  tap -> same as START
// While the "Call CalmBand" nudge is showing: START = I'm calling, DOWN / BACK = not now,
// everything else is ignored so it can't be closed by accident.
// Hidden: hold START for 3 seconds -> demo escalation (see Engine.demoTrigger).
//
// Why DOWN/UP are handled in onKeyPressed: on the FR165 a button can arrive as onKey, as a
// "page" behaviour (onNextPage / onPreviousPage - which touch swipes also produce), or both.
// Acting on the physical press and ignoring the echoes for a moment makes each press count
// exactly once, and keeps swipes from ever dismissing anything.
class CalmDelegate extends WatchUi.BehaviorDelegate {
    var holdTimer;
    var lastBtnMs = -100000;          // when DOWN/UP was last physically pressed

    function initialize() {
        BehaviorDelegate.initialize();
        holdTimer = new Timer.Timer();
    }

    hidden function recentButton() {
        return System.getTimer() - lastBtnMs < 700;
    }

    // ---- the actual button actions ----
    hidden function pressDown() {
        var e = getApp().engine;
        if (nudging()) {
            closeNudge();                         // "not now"
            return;
        }
        if (e.isBuzzing()) {
            e.dismiss();                          // vibrating: snooze it
            e.mirrorNow();
            WatchUi.requestUpdate();
            return;
        }
        go((e.page + 1) % 4);                     // otherwise: next screen down
    }

    hidden function pressUp() {                // UP: live -> sleep -> anxiety sim -> live
        if (nudging()) { return; }
        getApp().engine.cycleMode();
        WatchUi.requestUpdate();
    }

    // ---- low-level presses ----
    function onKeyPressed(evt) {
        var k = evt.getKey();
        if (k == WatchUi.KEY_ENTER) {
            holdTimer.stop();
            holdTimer.start(method(:onHeld), 3000, false);
            return false;                         // let the normal START handling run too
        }
        if (k == WatchUi.KEY_DOWN) {
            lastBtnMs = System.getTimer();
            pressDown();
            return true;
        }
        if (k == WatchUi.KEY_UP) {
            lastBtnMs = System.getTimer();
            pressUp();
            return true;
        }
        return false;
    }

    function onKeyReleased(evt) {
        if (evt.getKey() == WatchUi.KEY_ENTER) {
            holdTimer.stop();         // released before 3 s: just a normal press
        }
        return false;
    }

    function onHeld() as Void {
        getApp().engine.demoTrigger();
    }

    hidden function go(p) {
        var e = getApp().engine;
        var changed = (e.page != p);
        e.page = p;
        if (changed) { e.mirrorNow(); }   // the demo page follows the swipe right away
        WatchUi.requestUpdate();
    }

    hidden function nudging() {
        return getApp().engine.nudgeActive;
    }

    hidden function closeNudge() {
        getApp().engine.closeNudge();
        WatchUi.requestUpdate();
    }

    // Fallback if a firmware never sends onKeyPressed: act here, unless the press was already handled.
    function onKey(evt) {
        var k = evt.getKey();
        if (k == WatchUi.KEY_DOWN || k == WatchUi.KEY_UP) {
            if (!recentButton()) {
                lastBtnMs = System.getTimer();
                if (k == WatchUi.KEY_DOWN) { pressDown(); } else { pressUp(); }
            }
            return true;
        }
        return BehaviorDelegate.onKey(evt);   // START -> onSelect, BACK -> onBack
    }

    hidden function down() {                  // swipe up: next screen below
        var p = getApp().engine.page;
        go(p < 3 ? p + 1 : 3);
    }

    hidden function up() {                    // swipe down: previous screen above
        var p = getApp().engine.page;
        go(p > 0 ? p - 1 : 0);
    }

    function onSwipe(evt) {
        if (nudging()) { return true; }
        var d = evt.getDirection();
        if (d == WatchUi.SWIPE_UP) {
            down();
            return true;
        }
        if (d == WatchUi.SWIPE_DOWN) {
            up();
            return true;
        }
        return false;
    }

    // "Page" behaviours come from swipes, or as an echo of a DOWN/UP press (ignored).
    function onNextPage() {          // swipe up
        if (!recentButton() && !nudging()) { down(); }
        return true;
    }

    function onPreviousPage() {      // swipe down
        if (!recentButton() && !nudging()) { up(); }
        return true;
    }

    function onBack() {
        if (nudging()) {
            closeNudge();
            return true;
        }
        if (getApp().engine.page > 0) {
            go(0);
            return true;
        }
        return false;
    }

    function onSelect() {            // START button / tap
        if (nudging()) {
            getApp().engine.nudgeCalling();   // "I'm calling" - no need to keep showing the number
            WatchUi.requestUpdate();
            return true;
        }
        if (getApp().engine.page == 3) {      // settings: toggle Parkinson's mode
            getApp().engine.toggleParkinson();
            WatchUi.requestUpdate();
            return true;
        }
        getApp().engine.cycleLabel();
        WatchUi.requestUpdate();
        return true;
    }
}
