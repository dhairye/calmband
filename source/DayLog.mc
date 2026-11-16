import Toybox.Lang;
using Toybox.Application;
using Toybox.Communications;
using Toybox.Time;
using Toybox.Time.Gregorian;

// Today's important events, e.g. "2:05 PM anxiety 6m", "4:10 PM exercise 25m".
//  - An entry starts when an event begins and its duration grows while the event continues;
//    the same event coming back within 5 minutes extends the entry instead of adding a new one.
//  - Dismissing (DOWN / snooze) removes the entry for that event, so false alarms never appear.
//  - Kept on the watch for today only (survives app restarts, cleared the next day), and sent to
//    the CalmBand server whenever an entry is added or removed so the call coach knows your day.
class DayLog {
    var entries = [];     // [{"t" => "2:05 PM", "k" => "anxiety", "d" => seconds}, ...]
    var open = {};        // kind -> {"e" => entry, "start" => sec, "seen" => sec}
    var day = "";
    const MAX = 30;
    const MERGE_SEC = 300;

    function initialize() {
        day = today();
        try {
            var s = Application.Storage.getValue("daylog");
            if (s instanceof Dictionary && day.equals(s["day"]) && s["e"] instanceof Array) {
                entries = s["e"];
            }
        } catch (e) {}
    }

    hidden function today() {
        var i = Gregorian.info(Time.now(), Time.FORMAT_SHORT);
        return i.year + "-" + i.month + "-" + i.day;
    }

    // clock time `ago` seconds before now, e.g. "2:05 PM"
    hidden function clockAgo(ago) {
        var i = Gregorian.info(Time.now().subtract(new Time.Duration(ago)), Time.FORMAT_SHORT);
        var h = i.hour % 12;
        if (h == 0) { h = 12; }
        return h + ":" + i.min.format("%02d") + (i.hour < 12 ? " AM" : " PM");
    }

    hidden function rollDay() {
        var d = today();
        if (!d.equals(day)) {
            day = d;
            entries = [];
            open = {};
            save();
        }
    }

    function save() {
        try { Application.Storage.setValue("daylog", {"day" => day, "e" => entries}); } catch (e) {}
    }

    // An event of this kind is happening. `already` = seconds it has been going on.
    function start(kind, nowSec, already) {
        rollDay();
        var o = open[kind];
        if (o != null && nowSec - o["seen"] < MERGE_SEC) {
            o["seen"] = nowSec;               // it came back quickly: same entry
            return;
        }
        var e = {"t" => clockAgo(already), "k" => kind, "d" => already};
        entries.add(e);
        if (entries.size() > MAX) { entries = entries.slice(entries.size() - MAX, null); }
        open[kind] = {"e" => e, "start" => nowSec - already, "seen" => nowSec};
        save();
        sync();
    }

    // the event is still going: grow its duration
    function touch(kind, nowSec) {
        var o = open[kind];
        if (o == null || nowSec - o["seen"] >= MERGE_SEC) { return; }
        o["seen"] = nowSec;
        o["e"]["d"] = nowSec - o["start"];
    }

    // dismissed / snoozed: the entry is taken back
    function remove(kind) {
        var o = open[kind];
        if (o == null) { return; }
        entries.remove(o["e"]);
        open.remove(kind);
        save();
        sync();
    }

    // send today's log to the server (best effort; the alert also carries it)
    function sync() {
        try {
            Communications.makeWebRequest(SERVER_URL + "/log", {"day" => day, "entries" => entries}, {
                :method => Communications.HTTP_REQUEST_METHOD_POST,
                :headers => {
                    "Content-Type" => Communications.REQUEST_CONTENT_TYPE_JSON,
                    "X-CalmBand-Token" => ALERT_TOKEN
                },
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
            }, method(:onSync));
        } catch (e) {}
    }

    function onSync(code as Number, data as Dictionary or String or Null) as Void {}
}
