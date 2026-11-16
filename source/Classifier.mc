using Toybox.Math;

// State classes. Order matters: it indexes the probability array.
enum {
    C_CALM = 0,
    C_EXERCISE = 1,
    C_ANXIETY = 2,
    C_NIGHTMARE = 3,
    C_EXCITED = 4,
    C_RECOVER = 5
}

const CLASS_NAMES = ["CALM", "ACTIVE", "ANXIETY", "NIGHTMARE", "EXCITED", "RECOVERING"];
const N_CLASSES = 6;
// Parkinson's mode only: shown in place of the classifier's state while a rest tremor is detected
const TREMOR_STAGE = 6;

// Naive-Bayes-flavoured probabilistic classifier. Each hidden state gets a score
// from interpretable evidence features (0..1 "ramps"), then softmax turns scores
// into a probability distribution. Weights are hand-tuned priors; they are the
// obvious thing to replace with learned values once you have more labelled data.
//
// Field findings that shaped this (FR165, 2 h of real wear):
//  - the watch gives apps no HRV, respiration, or usable stress score;
//  - almost every sharp HR rise (standing up, walking, eating) was preceded by a short
//    arm-motion burst, so brief movement must "explain" a raised HR for a few minutes.
class Classifier {
    var hrBuf = [];          // 1 Hz heart-rate history, max 180 s
    var baseline = 0.0;      // slow resting-HR estimate (bpm)
    var haveBaseline = false;

    var probs = [1.0, 0.0, 0.0, 0.0, 0.0, 0.0];

    // activity memory: HR lags movement by minutes, so we must remember movement
    var actMid = 0.0;        // motion averaged over ~20 s
    var actSlow = 0.0;       // motion averaged over ~2 min
    var act3 = 0.0;          // motion averaged over ~3 s (catches short bursts like standing up)
    var exMem = 0.0;         // "recently exercised" (0..1), decays over ~6 min
    var movMem = 0.0;        // "recently moved at all" (0..1), decays over ~3 min
    var ticks = 0;
    var sinceMove = 999;     // seconds since the last sustained movement
    var movRing = new [30];  // 1 = that second had real motion (last 30 s)
    var movIdx = 0;
    var movSum = 0;
    var mask = -1;           // a state the user dismissed as a false positive (excluded for a while)
    var top = 0;
    // exposed features (for UI / debugging)
    var elev = 0.0;
    var slope = 0.0;
    var spike = 0.0;

    function initialize() {
        for (var i = 0; i < 30; i++) { movRing[i] = 0; }
    }

    function seedBaseline(bpm) {
        baseline = bpm.toFloat();
        haveBaseline = true;
    }

    function reset() {
        hrBuf = [];
        actMid = 0.0;
        actSlow = 0.0;
        act3 = 0.0;
        exMem = 0.0;
        movMem = 0.0;
        sinceMove = 999;
        for (var i = 0; i < 30; i++) { movRing[i] = 0; }
        movIdx = 0;
        movSum = 0;
    }

    // forget recent movement (keeps the heart-rate history and baseline)
    function quiet() {
        actMid = 0.0;
        actSlow = 0.0;
        act3 = 0.0;
        exMem = 0.0;
        movMem = 0.0;
        sinceMove = 999;
        for (var i = 0; i < 30; i++) { movRing[i] = 0; }
        movSum = 0;
        mask = -1;
    }

    hidden function ramp(x, lo, hi) {
        var v = (x - lo).toFloat() / (hi - lo).toFloat();
        if (v < 0.0) { v = 0.0; }
        if (v > 1.0) { v = 1.0; }
        return v;
    }

    // mean of buf[size-fromEnd-count .. size-fromEnd)
    hidden function meanRange(fromEnd, count) {
        var n = hrBuf.size();
        var end = n - fromEnd;
        var start = end - count;
        if (start < 0) { start = 0; }
        if (end <= start) { return hrBuf[n - 1].toFloat(); }
        var s = 0.0;
        for (var i = start; i < end; i++) {
            s += hrBuf[i];
        }
        return s / (end - start);
    }

    // hr: bpm, motion: mean |accel deviation| in milli-g, speed: m/s,
    // rmssd: ms or null (not available on the FR165), asleep: bool
    function update(hr, motion, speed, rmssd, asleep) {
        if (hr == null || hr < 30) {
            return;
        }
        hrBuf.add(hr);
        if (hrBuf.size() > 180) {
            hrBuf = hrBuf.slice(1, null);
        }
        if (!haveBaseline) {
            baseline = hr.toFloat();
            haveBaseline = true;
        }

        var n = hrBuf.size();
        var recent = meanRange(0, 5);
        elev = recent - baseline;

        // HR trend in bpm/min: least-squares line over the last <=90 s. (Comparing window
        // ends misreads a decaying spike as a rise.)
        slope = 0.0;
        if (n >= 45) {
            var m = n < 90 ? n : 90;
            var xm = (m - 1) / 2.0;
            var ym = 0.0;
            for (var i = n - m; i < n; i++) {
                ym += hrBuf[i];
            }
            ym /= m;
            var num = 0.0;
            var den = 0.0;
            for (var i = 0; i < m; i++) {
                var dx = i - xm;
                num += dx * (hrBuf[n - m + i] - ym);
                den += dx * dx;
            }
            slope = 60.0 * num / den;
        }
        ticks++;

        // fast jump: last 3 s vs. 10-20 s ago
        spike = 0.0;
        if (n >= 20) {
            spike = meanRange(0, 3) - meanRange(10, 10);
        }

        // ---- activity features ----
        // smooth motion over time so brief pauses (eating, gesturing) don't read as "still"
        actMid += (motion - actMid) / 20.0;
        actSlow += (motion - actSlow) / 120.0;
        act3 += (motion - act3) / 3.0;
        var exercise = ramp(speed, 1.5, 3.0) + ramp(actMid, 150, 450);
        if (exercise > 1.0) { exercise = 1.0; }
        if (exercise > exMem) {
            exMem = exercise;
        } else {
            exMem -= 1.0 / 360.0;
            if (exMem < 0.0) { exMem = 0.0; }
        }
        // Sustained movement (standing up, walking, eating) explains a raised HR for a few minutes.
        // It has to last: at least ~4-10 of the last 30 s with real motion, so raising the wrist to
        // look at the watch doesn't count. The first 20 s after launch (opening the app) are ignored.
        var movedNow = (motion > 60 && ticks > 20) ? 1 : 0;
        movSum += movedNow - movRing[movIdx];
        movRing[movIdx] = movedNow;
        movIdx = (movIdx + 1) % 30;
        var light = 0.9 * ramp(movSum, 4, 10);
        if (light > movMem) {
            movMem = light;
        } else {
            movMem -= 1.0 / 180.0;
            if (movMem < 0.0) { movMem = 0.0; }
        }
        if (light > 0.3) { sinceMove = 0; } else { sinceMove++; }
        var anyMem = exMem > movMem ? exMem : movMem;

        // Resting baseline: drops fast when HR is below it; creeps up only while still and
        // not rising (so a stress ramp can't drag it along). Starts quicker for the first 2.5 min.
        if (hr < baseline) {
            baseline += (hr - baseline) * 0.05;
        } else if (actSlow < 60 && slope < 3.0 && hr < 120
                   && !(n >= 20 && meanRange(0, 10) - meanRange(10, 10) >= 2.0)) {
            baseline += (hr - baseline) * (ticks < 150 ? 0.02 : 0.004);
        }

        // ---- evidence features ----
        var still = 1.0 - ramp(actSlow, 30, 120);
        var recov = ramp(-slope, 2.0, 8.0);      // HR clearly falling
        var slowRise = ramp(slope, 3.0, 10.0);
        var jump = ramp(spike, 12.0, 30.0);
        var hrvLow = 0.5;                        // neutral unless the watch ever provides RMSSD
        if (rmssd != null) {
            hrvLow = 1.0 - ramp(rmssd, 15, 40);
        }
        var elevEv = ramp(elev, 8.0, 25.0);
        var sleep = asleep ? 1.0 : 0.0;
        // After movement, HR peaks within about a minute and then falls. If you've been still for
        // over 60-90 s and HR is still climbing, the earlier movement no longer explains it.
        var risingAfterStill = ramp(sinceMove, 60, 90) * slowRise;
        var memEff = anyMem * (1.0 - risingAfterStill);
        var exAny = exercise > memEff ? exercise : memEff;   // active now OR recently (and still explains it)

        // ---- scores per hidden state ----
        var s = new [N_CLASSES];
        s[C_CALM]      = 1.6 * (1.0 - elevEv) - 1.0 * jump - 0.8 * slowRise + 0.5 * recov * (1.0 - memEff);
        // no movement = not active (otherwise ACTIVE could "win" by default when other states are low)
        s[C_EXERCISE]  = 3.0 * exercise - 1.0 * sleep - 1.0 * (1.0 - exercise);
        // recovering means HR flat or falling after activity - a climbing HR is not recovery
        s[C_RECOVER]   = 2.4 * memEff * (0.4 + 0.6 * elevEv) + 0.8 * recov - 0.5 - 2.0 * exercise
                         - 2.0 * slowRise;
        s[C_ANXIETY]   = 1.3 * slowRise + 1.0 * hrvLow + 1.0 * still + 0.8 * elevEv
                         - 3.0 * exAny - 3.0 * sleep - 0.8 * jump - 0.8
                         - 2.0 * (1.0 - still) - 1.0 * (1.0 - elevEv) - 1.5 * recov;
        s[C_NIGHTMARE] = 3.0 * sleep - 1.5 + 1.2 * elevEv + 0.8 * jump + 0.6 * hrvLow
                         + 0.5 * slowRise - 2.5 * exAny - 1.0 * recov
                         - (asleep ? 0.0 : 4.0);              // a nightmare needs sleep
        s[C_EXCITED]   = 0.9 * elevEv + 0.5 * (1.0 - hrvLow) + 0.4 * still
                         - 3.0 * exAny - 3.0 * sleep - 1.0 * jump - 0.9 * slowRise - 0.7
                         - 1.5 * recov - 1.0 * (1.0 - still);

        // softmax
        var mx = s[0];
        for (var i = 1; i < N_CLASSES; i++) {
            if (s[i] > mx) { mx = s[i]; }
        }
        var sum = 0.0;
        var p = new [N_CLASSES];
        for (var i = 0; i < N_CLASSES; i++) {
            p[i] = Math.pow(2.718281828, s[i] - mx);
            if (i == mask) { p[i] = 0.0; }
            sum += p[i];
        }
        if (sum <= 0.0) { p[C_CALM] = 1.0; sum = 1.0; }
        var best = 0;
        for (var i = 0; i < N_CLASSES; i++) {
            p[i] = p[i] / sum;
            if (p[i] > p[best]) { best = i; }
        }
        probs = p;
        top = best;
    }
}
