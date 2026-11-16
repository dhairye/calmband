using Toybox.Application;
using Toybox.WatchUi;

class CalmBandApp extends Application.AppBase {
    var engine;

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state) {
        engine = new Engine();
        engine.start();
    }

    function onStop(state) {
        if (engine != null) {
            engine.stop();
        }
    }

    function getInitialView() {
        return [new CalmView(), new CalmDelegate()];
    }
}

function getApp() {
    return Application.getApp();
}
