import Toybox.Lang;
using Toybox.System;
using Toybox.Activity;
using Toybox.ActivityMonitor;
using Toybox.Application;
using Toybox.Communications;
using Toybox.ActivityRecording;
using Toybox.FitContributor;

const LABEL_NAMES = ["", "marked: off", "dismissed"];
using Toybox.Sensor;
using Toybox.Position;
using Toybox.Timer;
using Toybox.Math;
using Toybox.UserProfile;
using Toybox.WatchUi;

// Owns the sensors, the 1 Hz loop, the classifier and the haptic coach.
class Engine {
    var timer;
    var classifier;
    var haptics;

    // latest raw readings
    var hr = 0;
    var speed = 0.0;
    var motion = 0.0;
    var jerk = 0.0;
    var rmssd = null;
    var ibis = [];

    var sleepMode = false;
    var sleepManual = false;              // UP button: "I'm going to sleep" (nightmare watch)
    var page = 0;                         // 0 = main screen, 1 = button legend
    var seconds = 0;
    var dismissClass = -1;                // state the user said was a false positive
    var dismissUntil = 0;
    const SNOOZE_SEC = 300;      // dismissed states stay silent this long
    var streakClass = -1;
    var streak = 0;
    var lastAction = "monitoring";
    var actionAt = -100;                  // when lastAction last changed (gray text hides after 5 s)
    const ACTION_SHOW_SEC = 5;

    // UP cycles: 0 = live, 1 = sleep mode (nightmare watch), 2 = anxiety simulation (demo)
    var mode = 0;
    var realHr = 0;                       // what the sensor says (hr is replaced while simulating)
    var simStart = 0;
    var simBase = 70.0;
    var simCalmAt = -1;                   // when the sim started calming down (snooze / support call)
    var simCalmFrom = 0.0;
    const SIM_HEADSTART = 30;             // seconds of gentle rise already "behind" you when the sim starts
    const SIM_PRE_RATE = 0.36;            // bpm/s during that head start
    const SIM_RATE = 0.5;                 // bpm/s once the sim is running

    // ---- escalation to a support phone call (see Config.mc) ----
    var anxSec = 0;                       // consecutive seconds the reading has been ANXIETY
    var anxTriggers = [];                 // times of anxiety calming sessions not dismissed
    var callState = 0;                    // 0 idle, 1 countdown, 2 sending, 3 call placed, 4 failed
    var countdownEnd = 0;
    var escReason = "";
    var lastCallSec = -100000;
    var callMsg = "";
    var callMsgUntil = 0;
    // full-screen "call CalmBand" nudge shown after an escalation
    var nudgeActive = false;
    var nudgeStart = 0;
    var nudgeBuzzes = 0;
    const NUDGE_SEC = 300;                // closes by itself after 5 minutes
    const NUDGE_REMIND_SEC = 60;          // gentle reminder buzz this often...
    const NUDGE_REMINDERS = 3;            // ...this many times

    // data recording: every second goes into a FIT activity (custom fields) you can
    // export from GARMIN/Activity or Garmin Connect. `label` is your own ground truth.
    var session = null;
    var label = 0;
    var markUntil = 0;
    var fState; var fConf; var fMotion; var fJerk; var fRmssd; var fElev;
    // Garmin-derived signals (stress score comes from HRV; respiration from the optical sensor)
    var stress = null;
    var resp = null;
    var ibiNew = 0;                       // beat intervals received this second (diagnostic)
    var fStress; var fResp; var fIbi; var fTremor;

    // ---- Parkinson's mode: rest-tremor detector (settings page toggle, off by default) ----
    var parkinsonMode = false;
    var magBuf = [];                      // last 64 accelerometer magnitudes (~2.6 s at 25 Hz)
    var tremorRatio = 0.0;                // share of motion power in the 3.5-7.5 Hz tremor band
    var tremorAmp = 0.0;                  // tremor peak amplitude, milli-g
    var tremorScore = 0.0;                // smoothed 0..1 "tremor present" evidence
    var tremorActive = false;
    var tremorSnoozeUntil = 0;

    // ---- live mirror for the demo page ----
    var mirrorBusy = false;
    var mirrorSentAt = -100;              // when the in-flight request went out
    var mirrorPending = false;            // something changed while a request was in flight
    var lastMirror = -100;
    var lastStage = -1;

    // ---- today's event log (logs screen + sent to the call coach) ----
    var daylog;
    var exerciseSec = 0;                  // consecutive seconds of ACTIVE
    var fSlope; var fEx; var fVib; var fLabel; var fSpeed; var fBase;

    hidden function clampInt(v, lo, hi) {
        var n = v.toNumber();
        if (n < lo) { return lo; }
        if (n > hi) { return hi; }
        return n;
    }

    hidden function startRecording() {
        try {
            session = ActivityRecording.createSession({
                :name => "CalmBand",
                :sport => Activity.SPORT_GENERIC,
                :subSport => Activity.SUB_SPORT_GENERIC
            });
            var o = {:mesgType => FitContributor.MESG_TYPE_RECORD};
            fState  = session.createField("state",   0, FitContributor.DATA_TYPE_UINT8,  o);
            fConf   = session.createField("conf_pct", 1, FitContributor.DATA_TYPE_UINT8,  o);
            fMotion = session.createField("motion",  2, FitContributor.DATA_TYPE_UINT16, o);
            fJerk   = session.createField("jerk",    3, FitContributor.DATA_TYPE_UINT16, o);
            fRmssd  = session.createField("rmssd",   4, FitContributor.DATA_TYPE_UINT8,  o);
            fElev   = session.createField("elev",    5, FitContributor.DATA_TYPE_SINT8,  o);
            fSlope  = session.createField("slope_x10", 6, FitContributor.DATA_TYPE_SINT16, o);
            fEx     = session.createField("exmem_pct", 7, FitContributor.DATA_TYPE_UINT8, o);
            fVib    = session.createField("vib",     8, FitContributor.DATA_TYPE_UINT8,  o);
            fLabel  = session.createField("label",  10, FitContributor.DATA_TYPE_UINT8,  o);
            fSpeed  = session.createField("speed_x10", 11, FitContributor.DATA_TYPE_UINT16, o);
            fBase   = session.createField("baseline", 12, FitContributor.DATA_TYPE_UINT8, o);
            fStress = session.createField("stress",  13, FitContributor.DATA_TYPE_UINT8,  o);
            fResp   = session.createField("resp",    14, FitContributor.DATA_TYPE_UINT8,  o);
            fIbi    = session.createField("ibi_n",   15, FitContributor.DATA_TYPE_UINT8,  o);
            fTremor = session.createField("tremor_pct", 16, FitContributor.DATA_TYPE_UINT8, o);
            session.start();
        } catch (e) {
            session = null;
        }
    }

    hidden function record(r) {
        if (session == null) { return; }
        try {
            fState.setData(classifier.top);
            fConf.setData(clampInt(classifier.probs[classifier.top] * 100, 0, 100));
            fMotion.setData(clampInt(motion, 0, 65000));
            fJerk.setData(clampInt(jerk, 0, 65000));
            fRmssd.setData(r == null ? 255 : clampInt(r, 0, 250));   // 255 = no beat-interval data
            fElev.setData(clampInt(classifier.elev, -120, 120));
            fSlope.setData(clampInt(classifier.slope * 10, -30000, 30000));
            fEx.setData(clampInt(classifier.exMem * 100, 0, 100));
            fVib.setData(haptics.active ? 1 : 0);
            fLabel.setData(label);
            fSpeed.setData(clampInt(speed * 10, 0, 65000));
            fBase.setData(clampInt(classifier.baseline, 0, 250));
            fStress.setData(stress == null ? 255 : clampInt(stress, 0, 100));
            fResp.setData(resp == null ? 255 : clampInt(resp, 0, 100));
            fIbi.setData(clampInt(ibiNew, 0, 250));
            // tremor band share (%), 255 when Parkinson's mode is off
            fTremor.setData(parkinsonMode ? clampInt(tremorRatio * 100, 0, 100) : 255);
        } catch (e) {}
    }

    // START button: cycle the ground-truth label you are currently living (buzzes to confirm)
    function cycleLabel() {
        label = 1;                    // "the app's reading is off right now"
        markUntil = seconds + 45;     // press again to extend
        haptics.test();
    }

    function initialize() {
        classifier = new Classifier();
        haptics = new Haptics();
        daylog = new DayLog();
    }

    function start() {
        try {
            parkinsonMode = (Application.Storage.getValue("parkinsons") == true);
        } catch (e) {}
        // The baseline is learned from your first readings (not the profile's resting HR, which is
        // a sleeping/lowest value and made normal awake HR look "elevated" right after launch).

        Sensor.setEnabledSensors([Sensor.SENSOR_HEARTRATE]);
        Sensor.enableSensorEvents(method(:onSensor));

        // 25 Hz accelerometer + beat-to-beat intervals (for HRV), delivered once a second
        try {
            var opts = {
                :period => 1,
                :accelerometer => {:enabled => true, :sampleRate => 25},
                :heartBeatIntervals => {:enabled => true}
            };
            Sensor.registerSensorDataListener(method(:onData), opts);
        } catch (e) {}

        Position.enableLocationEvents(Position.LOCATION_CONTINUOUS, method(:onPosition));

        startRecording();

        timer = new Timer.Timer();
        timer.start(method(:tick), 1000, true);
    }

    function stop() {
        if (timer != null) { timer.stop(); }
        if (session != null) {
            try {
                session.stop();
                session.save();
            } catch (e) {}
            session = null;
        }
        Sensor.setEnabledSensors([]);
        Sensor.enableSensorEvents(null);
        try { Sensor.unregisterSensorDataListener(); } catch (e) {}
        Position.enableLocationEvents(Position.LOCATION_DISABLE, method(:onPosition));
    }

    // ---- sensor callbacks ----
    function onSensor(info as Sensor.Info) as Void {
        if (info.heartRate != null) {
            realHr = info.heartRate;
            if (mode != 2) { hr = realHr; }
        }
    }

    function onPosition(info as Position.Info) as Void {
        if (info.speed != null) {
            speed = info.speed;
        }
    }

    function onData(sd as Sensor.SensorData) as Void {
        var a = sd.accelerometerData;
        if (a != null && a.x != null && a.x.size() > 1) {
            var n = a.x.size();
            var mags = new [n];
            var sum = 0.0;
            for (var i = 0; i < n; i++) {
                mags[i] = Math.sqrt(a.x[i].toFloat() * a.x[i] + a.y[i].toFloat() * a.y[i] + a.z[i].toFloat() * a.z[i]);
                sum += mags[i];
            }
            var mean = sum / n;
            var dev = 0.0;
            var mj = 0.0;
            for (var i = 0; i < n; i++) {
                dev += abs(mags[i] - mean);
                if (i > 0) {
                    var dj = abs(mags[i] - mags[i - 1]);
                    if (dj > mj) { mj = dj; }
                }
            }
            motion = dev / n;     // gravity cancels out; milli-g of "shake"
            jerk = mj;
            if (parkinsonMode) {
                magBuf.addAll(mags);
                if (magBuf.size() > 64) { magBuf = magBuf.slice(magBuf.size() - 64, null); }
                if (magBuf.size() == 64) { analyzeTremor(); }
            }
        }
        var h = sd.heartRateData;
        if (h != null && h.heartBeatIntervals != null) {
            for (var i = 0; i < h.heartBeatIntervals.size(); i++) {
                ibis.add(h.heartBeatIntervals[i]);
                ibiNew++;
            }
            if (ibis.size() > 90) {
                ibis = ibis.slice(ibis.size() - 90, null);
            }
        }
    }

    hidden function abs(x) {
        return x < 0 ? -x : x;
    }

    // RMSSD (ms) over the last ~minute of beats, ignoring artefacts
    hidden function computeRmssd() {
        var n = ibis.size();
        if (n < 20) { return null; }
        var sum = 0.0;
        var cnt = 0;
        for (var i = 1; i < n; i++) {
            var d = ibis[i] - ibis[i - 1];
            if (ibis[i] > 250 && ibis[i] < 2000 && abs(d) < 200) {
                sum += d.toFloat() * d;
                cnt++;
            }
        }
        if (cnt < 10) { return null; }
        return Math.sqrt(sum / cnt);
    }

    // Stress score (0-100, derived from HRV) and respiration rate (breaths/min), as the
    // watch itself computes them. They update slowly (about once a minute or slower).
    hidden function readGarminVitals() {
        try {
            var am = ActivityMonitor.getInfo();
            if ((am has :stressScore) && am.stressScore != null) { stress = am.stressScore; }
            if ((am has :respirationRate) && am.respirationRate != null) { resp = am.respirationRate; }
        } catch (e) {}
    }

    // ---- user controls ----
    // DOWN button: "that's a false positive". Stops the vibration immediately, removes that
    // state from the classifier for SNOOZE_SEC, and tags the recording (label = dismissed).
    // Rest tremor check, once a second on the last 64 samples. Goertzel filters measure power at
    // each frequency bin (0.39 Hz apart); Parkinson's rest tremor sits around 4-6 Hz, walking
    // arm-swing around 1-2 Hz. Checked on simulated signals only - not clinically validated.
    hidden function analyzeTremor() {
        var n = 64;
        var fs = 25.0;
        var mean = 0.0;
        for (var i = 0; i < n; i++) { mean += magBuf[i]; }
        mean /= n;
        var x = new [n];
        var wsum = 0.0;
        for (var i = 0; i < n; i++) {
            var w = 0.5 - 0.5 * Math.cos(2.0 * Math.PI * i / (n - 1));   // Hann window
            wsum += w;
            x[i] = (magBuf[i] - mean) * w;
        }
        var band = 0.0;
        var ref = 0.0;
        var peak = 0.0;
        for (var k = 1; k < 32; k++) {
            var f = k * fs / n;
            var c = 2.0 * Math.cos(2.0 * Math.PI * k / n);
            var s1 = 0.0;
            var s2 = 0.0;
            for (var i = 0; i < n; i++) {
                var s0 = x[i] + c * s1 - s2;
                s2 = s1;
                s1 = s0;
            }
            var p = s1 * s1 + s2 * s2 - c * s1 * s2;
            if (f >= 3.5 && f <= 7.5) {
                band += p;
                if (p > peak) { peak = p; }
            } else if ((f >= 0.8 && f < 3.5) || (f > 7.5 && f <= 12.0)) {
                ref += p;
            }
        }
        tremorRatio = band / (band + ref + 0.000001);
        tremorAmp = 2.0 * Math.sqrt(peak) / wsum;
        var now = (tremorRatio > 0.6 && tremorAmp >= 15 && tremorAmp <= 1500
                   && classifier.exMem < 0.5) ? 1.0 : 0.0;    // rhythmic, real, and not exercising
        tremorScore += (now - tremorScore) / 6.0;              // needs several seconds in a row
        tremorActive = tremorScore > 0.6;
    }

    function toggleParkinson() {
        parkinsonMode = !parkinsonMode;
        try { Application.Storage.setValue("parkinsons", parkinsonMode); } catch (e) {}
        magBuf = [];
        tremorScore = 0.0;
        tremorActive = false;
        if (!parkinsonMode && haptics.active && haptics.kind == TREMOR_KIND) {
            haptics.cancel(seconds);
        }
        haptics.test();
    }

    // start steady cue pulses when a tremor has held for a while
    hidden function tremorCue() {
        if (!parkinsonMode || !tremorActive || haptics.active || seconds < tremorSnoozeUntil
            || callState == 1 || nudgeActive) {
            return;
        }
        if (haptics.trigger(TREMOR_KIND, seconds)) {
            setAction("steady pulses");
            mirrorNow();
            daylog.start("tremor", seconds, 0);
        }
    }

    function dismiss() {
        simSettle();
        // A tremor response is snoozed separately from the anxiety logic - whether the pulses
        // are running or the tremor has only just been detected.
        var tremorPulsing = haptics.active && haptics.kind == TREMOR_KIND;
        if (tremorPulsing || (parkinsonMode && tremorActive && seconds >= tremorSnoozeUntil)) {
            if (tremorPulsing) { haptics.cancel(seconds); }
            tremorSnoozeUntil = seconds + SNOOZE_SEC;
            tremorScore = 0.0;
            tremorActive = false;
            setAction("snoozed");
            daylog.remove("tremor");          // snoozed events are not logged
            return;
        }
        // DOWN during the countdown cancels the call and counts as dismissing the anxiety alert
        if (callState == 1) {
            daylog.remove("anxiety");
            callState = 0;
            anxSec = 0;
            anxTriggers = [];
            haptics.cancel(seconds);
            dismissClass = C_ANXIETY;
            dismissUntil = seconds + SNOOZE_SEC;
            classifier.mask = C_ANXIETY;
            streak = 0;
            label = 2;
            markUntil = seconds + 45;
            setAction("snoozed");
            return;
        }
        var cls = haptics.active ? haptics.kind : classifier.top;
        // a dismissed anxiety session doesn't count toward a call
        if (cls == C_ANXIETY && anxTriggers.size() > 0
            && seconds - anxTriggers[anxTriggers.size() - 1] < 120) {
            anxTriggers = anxTriggers.slice(0, anxTriggers.size() - 1);
        }
        if (cls == C_ANXIETY) { anxSec = 0; }
        if (cls == C_CALM || cls == C_EXERCISE || cls == C_RECOVER) {
            setAction("all clear");
            return;
        }
        haptics.cancel(seconds);
        dismissClass = cls;
        dismissUntil = seconds + SNOOZE_SEC;
        classifier.mask = cls;
        streak = 0;
        label = 2;
        markUntil = seconds + 45;
        setAction("snoozed");
        if (cls >= 0 && cls < N_CLASSES) { daylog.remove(CLASS_NAMES[cls].toLower()); }
    }

    // Gray one-off messages ("snoozed", "all clear", "sleep mode on", ...) show for 5 s.
    // The timestamp only moves when the text actually changes.
    function setAction(s) {
        if (!s.equals(lastAction)) {
            lastAction = s;
            actionAt = seconds;
        }
    }

    // The main screen's status line, as text - used by CalmView and the demo page.
    function statusLine() {
        if (callState == 1) {
            var left = countdownEnd - seconds;
            return "support in " + (left < 0 ? 0 : left) + "s";
        }
        if (callState >= 2 && seconds < callMsgUntil) { return callMsg; }
        if (haptics.active && haptics.kind == TREMOR_KIND) { return "tremor detected"; }
        if (haptics.active) { return ""; }       // the buttons screen explains DOWN = snooze
        if (lastAction.equals("monitoring") || seconds - actionAt >= ACTION_SHOW_SEC) { return ""; }
        return lastAction;
    }

    // how sure the tremor detector is (0-100), for the ring / bar in the TREMOR stage
    function tremorPct() {
        if (!parkinsonMode) { return 0; }
        if (haptics.active && haptics.kind == TREMOR_KIND) { return 100; }
        return clampInt(tremorScore * 100, 0, 100);
    }

    function modeName() {
        if (mode == 2) { return "SIM: ANXIETY"; }
        return sleepMode ? "SLEEP MODE" : "LIVE";
    }

    // Send what the watch is showing to the server (every ~2 s, one request at a time).
    hidden function mirror() {
        if (!MIRROR_DISPLAY) { return; }
        // a request that never called back (Bluetooth dropped) must not block the mirror forever
        if (mirrorBusy && seconds - mirrorSentAt > 8) { mirrorBusy = false; }
        if (mirrorBusy) { return; }
        if (seconds - lastMirror < 2) { return; }
        lastMirror = seconds;
        mirrorSentAt = seconds;
        mirrorBusy = true;
        mirrorPending = false;
        var p = [];
        for (var i = 0; i < N_CLASSES; i++) { p.add((classifier.probs[i] * 100).toNumber()); }
        var payload = {
            "hr" => hr,
            "st" => stage(),
            "p" => p,
            "tp" => tremorPct(),
            "status" => statusLine(),
            "showNumber" => (callState >= 2 && seconds < callMsgUntil),
            "countdown" => callState == 1,
            "nudge" => nudgeActive,
            "pd" => parkinsonMode,
            "tremor" => parkinsonMode && tremorActive,
            "sleep" => sleepMode,
            "mode" => modeName(),
            "vib" => haptics.active,
            "lvl" => haptics.level,
            "page" => page,
            "number" => SUPPORT_NUMBER,
            "ther" => THERAPIST_NUMBER,
            "emer" => EMERGENCY_NUMBER,
            "pulse" => (haptics.active && haptics.kind == TREMOR_KIND) ? "tremor" : (haptics.active ? "breath" : "")
        };
        try {
            Communications.makeWebRequest(SERVER_URL + "/watch/state", payload, {
                :method => Communications.HTTP_REQUEST_METHOD_POST,
                :headers => {
                    "Content-Type" => Communications.REQUEST_CONTENT_TYPE_JSON,
                    "X-CalmBand-Token" => ALERT_TOKEN
                },
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
            }, method(:onMirror));
        } catch (e) {
            mirrorBusy = false;
        }
    }

    function onMirror(code as Number, data as Dictionary or String or Null) as Void {
        mirrorBusy = false;
        if (mirrorPending) {              // a change happened mid-flight: send it straight away
            lastMirror = -100;
            mirror();
        }
    }

    // Something visible just changed (screen, vibration, snooze, mode): update the demo page now.
    function mirrorNow() {
        if (mirrorBusy && seconds - mirrorSentAt <= 8) {
            mirrorPending = true;
            return;
        }
        lastMirror = -100;
        mirror();
    }

    // keep today's log up to date (called once a second)
    hidden function updateLog() {
        var top = classifier.top;
        if (top == C_EXERCISE) {
            exerciseSec++;
            if (exerciseSec == 60) { daylog.start("exercise", seconds, 60); }
            daylog.touch("exercise", seconds);
        } else {
            exerciseSec = 0;
            if (top == C_ANXIETY || top == C_NIGHTMARE || top == C_EXCITED) {
                daylog.touch(CLASS_NAMES[top].toLower(), seconds);
            }
        }
        if (parkinsonMode && tremorActive) { daylog.touch("tremor", seconds); }
        if (seconds % 60 == 0) { daylog.save(); }
    }


    // ---- main 1 Hz loop ----
    function tick() as Void {
        seconds++;
        // Sleep is automatic: night hours (23:00-07:00) and no wrist movement for a while.
        var hour = System.getClockTime().hour;
        var asleep = sleepManual || ((hour >= 23 || hour < 7) && classifier.actSlow < 30);
        if (mode == 2) { asleep = false; }    // the anxiety sim is an awake scenario
        sleepMode = asleep;
        var mot = motion;
        if (mode == 2) {
            // Anxiety simulation: sitting still while the heart rate climbs ~30 bpm/min,
            // levelling off about 38 bpm above resting. The real classifier, haptics and
            // escalation run on it exactly as they would on a real reading.
            // It starts with a short head start already in the history, so calming begins ~10 s in.
            // After a snooze or the support call, the heart rate settles back down to resting.
            var t = seconds - simStart;
            if (simCalmAt >= 0) {
                var k = Math.pow(2.718281828, -(seconds - simCalmAt) / 15.0);
                hr = (simBase + (simCalmFrom - simBase) * k).toNumber();
            } else {
                var rise = SIM_HEADSTART * SIM_PRE_RATE + t * SIM_RATE;
                if (rise > 38.0) { rise = 38.0; }
                hr = (simBase + rise + 1.5 * Math.sin(t * 0.7)).toNumber();
            }
            mot = 4.0;
        } else {
            hr = realHr;
        }
        var r = computeRmssd();
        rmssd = r;
        readGarminVitals();
        haptics.cooldownSec = DEMO_MODE ? 30 : 120;

        if (dismissClass >= 0 && seconds >= dismissUntil) {
            dismissClass = -1;
            classifier.mask = -1;
        }
        classifier.update(hr, mot, mode == 2 ? 0.0 : speed, mode == 2 ? null : r, asleep);
        decide();
        updateEscalation();
        tremorCue();
        if (parkinsonMode && tremorActive && !haptics.active && seconds >= tremorSnoozeUntil) {
            setAction("tremor detected");
        }
        updateLog();
        var st = stage();
        if (st != lastStage) {                // state changed (e.g. TREMOR appeared): mirror it now
            lastStage = st;
            mirrorNow();
        }
        mirror();
        if (label > 0 && seconds > markUntil) { label = 0; }
        record(r);
        ibiNew = 0;
        if (seconds % 5 == 0) {
            System.println("t=" + seconds + " hr=" + hr + " mot=" + motion.format("%.0f") + " jerk=" + jerk.format("%.0f")
                + " spd=" + speed.format("%.1f") + " rmssd=" + (r == null ? "na" : r.format("%.0f"))
                + " base=" + classifier.baseline.format("%.0f") + " elev=" + classifier.elev.format("%.0f")
                + " slope=" + classifier.slope.format("%.1f") + " top=" + CLASS_NAMES[classifier.top]
                + " p=" + classifier.probs[classifier.top].format("%.2f") + " vib=" + haptics.active);
        }
        var wasBuzzing = haptics.active;
        haptics.tick(seconds);
        if (wasBuzzing && !haptics.active) { mirrorNow(); }   // calming finished on its own
        WatchUi.requestUpdate();
    }

    // Only intervene when a distressed state is the clear winner for a few seconds,
    // and stop immediately if it turns out to be exercise.
    hidden function decide() {
        var top = classifier.top;
        var conf = classifier.probs[top];
        if (top == streakClass) {
            streak++;
        } else {
            streakClass = top;
            streak = 1;
        }

        if (top == C_EXERCISE || top == C_CALM || top == C_RECOVER) {
            if (haptics.active && top != C_CALM && haptics.kind != TREMOR_KIND) {
                haptics.cancel(seconds);
                setAction("stopped");
                mirrorNow();
            }
            return;
        }
        if (conf >= 0.5 && streak >= 5) {
            if (haptics.trigger(top, seconds)) {
                setAction("calming");
                mirrorNow();
                if (top == C_ANXIETY) { anxTriggers.add(seconds); }
                daylog.start(CLASS_NAMES[top].toLower(), seconds, streak);
            }
        }
    }

    // ---- escalation ----
    hidden function showCallMsg(msg, secs) {
        callMsg = msg;
        callMsgUntil = seconds + secs;
    }

    // "not now" (or the nudge timing out): the number stays on the main screen for 5 s, then goes
    function closeNudge() {
        nudgeActive = false;
        if (callState >= 2) { callMsgUntil = seconds + ACTION_SHOW_SEC; }
    }

    // Is the watch buzzing right now (calming, tremor pulses, or the support countdown)?
    // DOWN snoozes when it is, and moves to the next screen when it isn't.
    function isBuzzing() {
        return haptics.active || callState == 1;
    }

    // UP: live -> sleep mode -> anxiety sim -> live ...
    // (the automatic night-time sleep detection still applies in live mode)
    function cycleMode() {
        var prev = mode;
        mode = (mode + 1) % 3;
        sleepManual = (mode == 1);
        if (prev == 2) { endSim(); }
        if (mode == 2) { startSim(); }
        haptics.test();
        setAction(mode == 0 ? "live mode" : (mode == 1 ? "sleep mode on" : "anxiety sim"));
        mirrorNow();
    }

    // forget what came before, as if you'd been sitting still for a while
    hidden function clearState() {
        haptics.cancel(seconds);
        haptics.lastEndSec = -100000;
        if (callState == 1) { callState = 0; }
        dismissClass = -1;
        classifier.mask = -1;
        streak = 0;
        anxSec = 0;
        anxTriggers = [];
    }

    hidden function startSim() {
        clearState();
        simStart = seconds;
        simCalmAt = -1;
        simBase = (classifier.haveBaseline && classifier.baseline > 40) ? classifier.baseline
                  : (realHr > 40 ? realHr.toFloat() : 70.0);
        classifier.quiet();
        // history: a minute at resting, then the head start of the rise
        var buf = [];
        for (var i = 0; i < 60; i++) { buf.add(simBase.toNumber()); }
        for (var i = 0; i < SIM_HEADSTART; i++) { buf.add((simBase + SIM_PRE_RATE * i).toNumber()); }
        classifier.hrBuf = buf;
        classifier.baseline = simBase;
        classifier.haveBaseline = true;
    }

    // in the sim, a snooze or the support call lets the heart rate come back down
    hidden function simSettle() {
        if (mode == 2 && simCalmAt < 0) {
            simCalmAt = seconds;
            simCalmFrom = hr.toFloat();
        }
    }

    // Parkinson's mode: while a rest tremor is detected (or its pulses run), the main screen shows
    // TREMOR as the state instead of the heart-rate reading - unless an anxiety/nightmare/excited
    // calming session is running, which keeps its own state.
    function tremorStage() {
        if (!parkinsonMode) { return false; }
        if (haptics.active) { return haptics.kind == TREMOR_KIND; }
        return tremorActive || tremorScore > 0.3;
    }

    function stage() {
        return tremorStage() ? TREMOR_STAGE : classifier.top;
    }

    hidden function endSim() {
        clearState();
        hr = realHr;
        classifier.reset();                 // drop the simulated heart rates...
        classifier.haveBaseline = false;    // ...and relearn the baseline from real ones
    }

    // "I'm calling": close the nudge and clear the number from the main screen too
    function nudgeCalling() {
        nudgeActive = false;
        callMsgUntil = 0;
    }

    // Hidden demo trigger (hold START 3 s): runs the real escalation now - countdown, alert to
    // the server with the live readings, then the nudge - without waiting for an ANXIETY reading.
    function demoTrigger() {
        if (callState == 1 || nudgeActive) { return; }
        label = 0;                            // the START press that began the hold isn't a mark
        lastCallSec = -100000;                // ignore the escalation cooldown
        startCountdown("demo");
        WatchUi.requestUpdate();
    }

    hidden function updateEscalation() {
        if (nudgeActive) {
            var elapsed = seconds - nudgeStart;
            if (elapsed >= NUDGE_SEC) {
                closeNudge();
            } else if (elapsed > 0 && elapsed % NUDGE_REMIND_SEC == 0 && nudgeBuzzes < NUDGE_REMINDERS) {
                haptics.nudge();
                nudgeBuzzes++;
            }
        }
        if (classifier.top == C_ANXIETY && classifier.probs[C_ANXIETY] >= 0.5) {
            anxSec++;
        } else {
            anxSec = 0;
        }
        var window = DEMO_MODE ? REPEAT_WINDOW_SEC_DEMO : REPEAT_WINDOW_SEC_REAL;
        var keep = [];
        for (var i = 0; i < anxTriggers.size(); i++) {
            if (seconds - anxTriggers[i] <= window) { keep.add(anxTriggers[i]); }
        }
        anxTriggers = keep;

        if (callState == 1) {
            var left = countdownEnd - seconds;
            if (left <= 0) {
                sendAlert();
            } else if (left % 3 == 0) {
                haptics.alert();
            }
            return;
        }
        var cooldown = DEMO_MODE ? CALL_COOLDOWN_SEC_DEMO : CALL_COOLDOWN_SEC_REAL;
        if (seconds - lastCallSec < cooldown) { return; }
        var sustain = DEMO_MODE ? SUSTAIN_SEC_DEMO : SUSTAIN_SEC_REAL;
        if (anxSec >= sustain) {
            startCountdown("sustained");
        } else if (anxTriggers.size() >= REPEAT_COUNT) {
            startCountdown("repeated");
        }
    }

    hidden function startCountdown(reason) {
        callState = 1;
        escReason = reason;
        countdownEnd = seconds + CANCEL_GRACE_SEC;
        haptics.cancel(seconds);
        haptics.alert();
        page = 0;                           // make sure the countdown is visible
        mirrorNow();
    }

    hidden function sendAlert() {
        simSettle();
        callState = 2;
        lastCallSec = seconds;
        showCallMsg("call support", ACTION_SHOW_SEC);   // the full-screen nudge shows the number meanwhile
        daylog.start("support alert", seconds, 0);
        nudgeActive = true;
        nudgeStart = seconds;
        nudgeBuzzes = 0;
        page = 0;
        var payload = {
            "reason" => escReason,
            "hr" => hr,
            "baseline" => classifier.baseline.toNumber(),
            "elev" => classifier.elev.toNumber(),
            "slope" => (classifier.slope * 10).toNumber() / 10.0,
            "anxSec" => anxSec,
            "triggers" => anxTriggers.size(),
            "conf" => (classifier.probs[C_ANXIETY] * 100).toNumber(),
            "motion" => classifier.actSlow.toNumber(),
            "asleep" => sleepMode,
            "demo" => escReason.equals("demo") || mode == 2,
            "log" => daylog.entries
        };
        anxSec = 0;
        anxTriggers = [];
        try {
            Communications.makeWebRequest(SERVER_URL + "/alert", payload, {
                :method => Communications.HTTP_REQUEST_METHOD_POST,
                :headers => {
                    "Content-Type" => Communications.REQUEST_CONTENT_TYPE_JSON,
                    "X-CalmBand-Token" => ALERT_TOKEN
                },
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
            }, method(:onAlertResponse));
        } catch (e) {
            callState = 4;
        }
    }

    // The number is shown either way, so the user can still call if the server wasn't reached
    // (then the coach just won't have the watch data).
    function onAlertResponse(code as Number, data as Dictionary or String or Null) as Void {
        callState = (code == 200) ? 3 : 4;
        if (code != 200) {
            // negative codes are Bluetooth / phone-link errors, positive ones are HTTP status codes
            System.println("alert failed: " + code);
        }
        WatchUi.requestUpdate();
    }
}
