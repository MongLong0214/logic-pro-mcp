/*
 * LogicProMCP Scripter MIDI FX Template
 *
 * Install: Logic Pro > Channel Strip > MIDI FX > Scripter
 * Paste this script into Scripter's Script Editor.
 *
 * Maps MIDI CC 102-119 on Channel 16 to plugin parameters 1-18.
 * All other MIDI is passed through unchanged.
 *
 * Reference: PRD §4.7 Scripter Bridge Protocol
 */

var PluginParameters = [];
for (var i = 0; i < 18; i++) {
    PluginParameters.push({name: "Param " + (i + 1), type: "target"});
}

function HandleMIDI(event) {
    if (event instanceof ControlChange && event.channel == 16) {
        var paramIndex = event.number - 102;
        if (paramIndex >= 0 && paramIndex < 18) {
            var target = new TargetEvent();
            target.target = PluginParameters[paramIndex].name;
            target.value = event.value / 127.0;
            target.send();
            return; // consumed
        }
    }
    event.send(); // pass through
}
