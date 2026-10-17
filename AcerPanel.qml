// Acer XB273U V3 bar widget + popup: brightness, contrast, colour
// temperature preset and RGB gain over DDC/CI.
// Modeled on the built-in omarchy.monitor panel.
import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "puck.acer-xb273u-v3"
  ipcTarget: "puck.acer-xb273u-v3"

  // An explicit "bus" setting wins; otherwise `ddcutil detect` finds the monitor once.
  readonly property string busOverride: String(setting("bus", ""))
  property string detectedBus: ""
  readonly property string bus: busOverride !== "" ? busOverride : detectedBus

  // "detecting" until a bus is known, "missing" when no Acer display was found,
  // then "ready" or "silent" depending on whether the last read answered.
  property string status: busOverride !== "" ? "silent" : "detecting"
  readonly property bool ready: status === "ready"

  // Last known monitor values.
  property int brightness: 0
  property int contrast: 0
  property int preset: 0
  property int gainR: 50
  property int gainG: 50
  property int gainB: 50

  // Refresh rate, switched through Hyprland rather than DDC/CI. The Hyprland
  // output (e.g. "DP-3") comes from `ddcutil detect`; "output" in shell.json wins.
  readonly property string outputOverride: String(setting("output", ""))
  property string detectedOutput: ""
  readonly property string output: outputOverride !== "" ? outputOverride : detectedOutput
  property var mon: null          // Model.parseMonitor result, null until read
  // "balancedHz" picks the closest rate the monitor offers (default 60);
  // "performanceHz" does the same, 0 meaning the highest.
  readonly property var balancedRate: mon ? Model.nearestRate(mon.rates, Number(setting("balancedHz", 60))) : null
  readonly property var performanceRate: mon ? Model.nearestRate(mon.rates, Number(setting("performanceHz", 0))) : null
  readonly property bool rateAvailable: mon !== null && balancedRate !== null && performanceRate !== null
                                        && balancedRate.hz !== performanceRate.hz
  readonly property real refreshHz: mon ? mon.refresh : 0
  readonly property bool highPerformance: rateAvailable
      && Model.isHighPerformance(refreshHz, balancedRate.hz, performanceRate.hz)
  // The rate asked for, until the next read confirms it.
  property real requestedHz: 0

  // Live FPS: how many frames the open popup actually paints per second.
  // Painting is vsync-locked, so this follows the monitor's refresh rate. It
  // is not a game or desktop frame counter.
  property int measuredFps: 0
  property int framesSinceTick: 0
  property real lastTickMs: 0

  // Coalescing writer: one slot per code, one ddcutil process at a time.
  property var pending: ({})
  property int inflightCode: -1
  // Changing the preset can move other values, so re-read once the queue drains.
  readonly property var switchCodes: [Model.VCP.preset]

  // Keyboard cursor: one entry per visible row.
  readonly property var rows: (rateAvailable ? ["rate"] : []).concat(
      ["brightness", "contrast", "preset", "gainR", "gainG", "gainB"])
  property string cursorRow: "brightness"
  property bool cursorActive: false
  onRowsChanged: if (rows.indexOf(cursorRow) < 0) cursorRow = rows[0]

  function write(code, value) {
    pending = Model.enqueue(pending, code, value)
    pump()
  }

  function pump() {
    if (writer.running || bus === "") return
    var next = Model.takeNext(pending)
    if (!next) {
      if (switchCodes.indexOf(inflightCode) >= 0) refresh()
      inflightCode = -1
      return
    }
    pending = next.rest
    inflightCode = next.code
    writer.command = ["ddcutil", "--bus", root.bus, "--permit-unknown-feature", "--noverify",
                      "setvcp", Model.hex(next.code), String(next.value)]
    writer.running = true
  }

  function busy(code) {
    return inflightCode === code || pending[code] !== undefined
  }

  function setBrightness(v) { brightness = Model.clamp(v, 0, 100); write(Model.VCP.brightness, brightness) }
  function setContrast(v)   { contrast = Model.clamp(v, 0, 100); write(Model.VCP.contrast, contrast) }
  function setPreset(v)     { preset = v; write(Model.VCP.preset, v) }
  function setGainR(v)      { gainR = Model.clamp(v, 0, 100); write(Model.VCP.gainR, gainR) }
  function setGainG(v)      { gainG = Model.clamp(v, 0, 100); write(Model.VCP.gainG, gainG) }
  function setGainB(v)      { gainB = Model.clamp(v, 0, 100); write(Model.VCP.gainB, gainB) }

  function refresh() {
    if (bus === "") detect()
    else if (!reader.running) reader.running = true
    readMonitor()
  }

  function readMonitor() {
    if (output !== "" && !monReader.running) monReader.running = true
  }

  // Applies the balanced or high-performance rate. Runtime only: it does not
  // touch monitors.lua, so a Hyprland reload goes back to the configured rate.
  function setHighPerformance(on) {
    if (!rateAvailable || rateWriter.running) return
    var rate = on ? performanceRate : balancedRate
    var lua = Model.buildRateEval(mon, rate)
    if (lua === "") return
    requestedHz = rate.hz
    rateWriter.command = ["hyprctl", "eval", lua]
    rateWriter.running = true
  }

  function detect() {
    if (detector.running) return
    status = "detecting"
    detector.running = true
  }

  function applyDetect(displays) {
    detectedBus = Model.pickBus(displays)
    detectedOutput = ""
    for (var i = 0; i < displays.length; i++)
      if (displays[i].bus === bus) detectedOutput = displays[i].output
    if (bus === "") { status = "missing"; return }
    status = "silent"
    refresh()
  }

  function applyMonitor(m) {
    mon = m
    requestedHz = 0
  }

  function applyRead(s) {
    var V = Model.VCP
    // Skip codes with a write queued or in flight so the UI never bounces back.
    if (s[V.brightness] !== undefined && !busy(V.brightness)) brightness = s[V.brightness]
    if (s[V.contrast] !== undefined && !busy(V.contrast)) contrast = s[V.contrast]
    if (s[V.preset] !== undefined && !busy(V.preset)) preset = s[V.preset]
    if (s[V.gainR] !== undefined && !busy(V.gainR)) gainR = s[V.gainR]
    if (s[V.gainG] !== undefined && !busy(V.gainG)) gainG = s[V.gainG]
    if (s[V.gainB] !== undefined && !busy(V.gainB)) gainB = s[V.gainB]
    status = s[V.brightness] !== undefined ? "ready" : "silent"
  }

  // Keyboard: j/k move rows, h/l adjust.
  function moveCursor(d) {
    var i = rows.indexOf(cursorRow) + d
    cursorRow = rows[Math.max(0, Math.min(rows.length - 1, i))]
  }
  function stepPreset(d) {
    var P = Model.PRESETS
    var i = 0
    for (var k = 0; k < P.length; k++) if (P[k].value === preset) i = k
    setPreset(P[Math.max(0, Math.min(P.length - 1, i + d))].value)
  }
  function activate() {
    if (cursorRow === "rate") setHighPerformance(!highPerformance)
  }
  function adjust(d) {
    switch (cursorRow) {
      case "rate": setHighPerformance(d > 0); break
      case "brightness": setBrightness(brightness + d * 5); break
      case "contrast": setContrast(contrast + d * 5); break
      case "preset": stepPreset(d); break
      case "gainR": setGainR(gainR + d * 5); break
      case "gainG": setGainG(gainG + d * 5); break
      case "gainB": setGainB(gainB + d * 5); break
    }
  }

  property real wheelAccumulator: 0

  function stateJson() {
    return JSON.stringify({ refreshHz: refreshHz, highPerformance: highPerformance,
                            measuredFps: measuredFps,
                            balancedHz: balancedRate ? balancedRate.hz : null,
                            performanceHz: performanceRate ? performanceRate.hz : null,
                            output: output, brightness: brightness, contrast: contrast, preset: preset,
                            gainR: gainR, gainG: gainG, gainB: gainB,
                            status: status, bus: bus, queued: Object.keys(pending).length })
  }

  // Same entry points the popup uses, so scripts (and tests) drive the real path:
  //   quickshell -p $OMARCHY_PATH/shell ipc call puck.acer-xb273u-v3.monitor set brightness 40
  function setIpc(name, value) {
    var n = parseInt(value, 10)
    switch (name) {
      case "brightness": setBrightness(n); break
      case "contrast": setContrast(n); break
      case "preset": setPreset(n); break
      case "performance": setHighPerformance(value === "on" || n === 1); break
      case "gain-r": setGainR(n); break
      case "gain-g": setGainG(n); break
      case "gain-b": setGainB(n); break
      default: return "unknown " + name
    }
    return stateJson()
  }

  IpcHandler {
    target: "puck.acer-xb273u-v3.monitor"
    function state(): string { return root.stateJson() }
    function refresh(): void { root.refresh() }
    function set(name: string, value: string): string { return root.setIpc(name, value) }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Always detect once: even with a "bus" override, detect supplies the Hyprland output.
  Component.onCompleted: detect()
  onOpenedChanged: if (opened) {
    // A silent auto-detected bus may be stale (monitor moved ports), so look again.
    if (status === "silent" && busOverride === "") detectedBus = ""
    refresh(); cursorActive = false; cursorRow = "brightness"; measuredFps = 0
  }

  Timer { interval: 5000; repeat: true; running: root.opened; onTriggered: root.refresh() }
  // Keep the values roughly current while closed. Detection is not retried
  // here; opening the popup retries it.
  Timer { interval: 60000; repeat: true; running: !root.opened && root.bus !== ""; onTriggered: root.refresh() }

  Process {
    id: detector
    command: ["ddcutil", "detect", "--brief"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyDetect(Model.parseDetect(text))
    }
  }

  Process {
    id: reader
    command: ["ddcutil", "--bus", root.bus, "--permit-unknown-feature", "--brief",
              "getvcp", "10", "12", "14", "16", "18", "1a"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyRead(Model.parseBrief(text))
    }
  }

  Process {
    id: monReader
    command: ["hyprctl", "monitors", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyMonitor(Model.parseMonitor(text, root.output))
    }
  }

  Process {
    id: rateWriter
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: if (!running) rateSettle.restart()
  }

  // Hyprland needs a moment to finish the modeset before it reports the new rate.
  Timer { id: rateSettle; interval: 700; onTriggered: root.readMonitor() }

  Process {
    id: writer
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: if (!running) root.pump()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.status === "missing" ? "󰶐" : "󰃞"
    onPressed: function(b) { root.toggle() }
    onWheelMoved: function(delta) {
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps !== 0) root.setBrightness(root.brightness + wheel.steps * 5)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(760))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.adjust(dx)
      }
      onActivateRequested: if (root.cursorActive) root.activate()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        // ---------- Hero ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroText.implicitHeight)
          Text {
            id: heroIcon
            text: "󰃞"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.verticalCenter: parent.verticalCenter
          }
          Column {
            id: heroText
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: fpsBadge.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)
            Text {
              text: "Acer XB273U V3"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Text {
              text: ({ detecting: "LOOKING FOR MONITOR",
                       missing: "NO ACER MONITOR FOUND",
                       silent: "MONITOR NOT RESPONDING ON BUS " + root.bus,
                       ready: "DDC/CI · BUS " + root.bus })[root.status]
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
            }
          }

          // Live FPS counter, top right.
          Column {
            id: fpsBadge
            anchors.right: parent.right
            anchors.rightMargin: Style.space(6)
            anchors.top: parent.top
            visible: root.opened && root.measuredFps > 0
            spacing: Style.space(2)
            Text {
              anchors.right: parent.right
              text: String(root.measuredFps)
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Text {
              anchors.right: parent.right
              text: "FPS"
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
            }
          }

          // Keeps the popup repainting while it is open (and only then), and
          // counts the frames the window really swaps to the screen.
          FrameAnimation { running: root.opened }
          Connections {
            target: fpsBadge.Window.window
            ignoreUnknownSignals: true
            function onFrameSwapped() { if (root.opened) root.framesSinceTick++ }
          }
          Timer {
            interval: 500
            repeat: true
            running: root.opened
            onRunningChanged: if (running) { root.framesSinceTick = 0; root.lastTickMs = Date.now() }
            onTriggered: {
              var now = Date.now()
              var seconds = (now - root.lastTickMs) / 1000
              if (seconds > 0) root.measuredFps = Math.round(root.framesSinceTick / seconds)
              root.framesSinceTick = 0
              root.lastTickMs = now
            }
          }
        }

        Column {
          visible: root.rateAvailable
          width: parent.width
          spacing: Style.space(12)

          PanelSeparator { foreground: root.bar.foreground }

          Item {
            width: parent.width
            implicitHeight: rateHeader.implicitHeight
            PanelSectionHeader {
              id: rateHeader
              text: "󰍹  REFRESH RATE"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              text: root.requestedHz > 0 ? "→ " + Math.round(root.requestedHz) + " FPS"
                                         : Math.round(root.refreshHz) + " FPS"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.right: parent.right
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          CursorSurface {
            id: rateRow
            width: parent.width
            implicitHeight: rateSwitch.implicitHeight + Style.spacing.controlGap
            hasCursor: root.cursorActive && root.cursorRow === "rate"
            foreground: root.bar.foreground
            outline: true

            Text {
              text: root.highPerformance ? "High performance · " + Math.round(root.performanceRate.hz)
                                         : "Balanced · " + Math.round(root.balancedRate.hz)
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              anchors.left: parent.left
              anchors.leftMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
            }
            ToggleSwitch {
              id: rateSwitch
              checked: root.highPerformance
              foreground: root.bar.foreground
              cursorRing: false
              anchors.right: parent.right
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              onToggled: root.setHighPerformance(!root.highPerformance)
            }
            MouseArea {
              anchors.fill: parent
              anchors.rightMargin: rateSwitch.width + Style.space(6)
              hoverEnabled: true
              onContainsMouseChanged: if (containsMouse) { root.cursorActive = true; root.cursorRow = "rate" }
              onClicked: root.setHighPerformance(!root.highPerformance)
            }
          }
        }

        Column {
          visible: root.ready
          width: parent.width
          spacing: Style.space(12)

          PanelSeparator { foreground: root.bar.foreground }

          SliderRow {
            row: "brightness"; icon: "󰃠"; label: "BRIGHTNESS"
            minimum: 0; maximum: 100; value: root.brightness; suffix: "%"
            onPicked: function(v) { root.setBrightness(v) }
          }

          SliderRow {
            row: "contrast"; icon: "󰆕"; label: "CONTRAST"
            minimum: 0; maximum: 100; value: root.contrast; suffix: "%"
            onPicked: function(v) { root.setContrast(v) }
          }

          PanelSeparator { foreground: root.bar.foreground }

          Item {
            width: parent.width
            implicitHeight: presetHeader.implicitHeight
            PanelSectionHeader {
              id: presetHeader
              text: "󰔄  COLOUR TEMPERATURE"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              text: Model.presetLabel(root.preset)
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.right: parent.right
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          CursorSurface {
            width: parent.width
            implicitHeight: presetButtons.implicitHeight + Style.spacing.controlGap
            hasCursor: root.cursorActive && root.cursorRow === "preset"
            foreground: root.bar.foreground
            outline: true
            HoverHandler { onHoveredChanged: if (hovered) { root.cursorActive = true; root.cursorRow = "preset" } }

            Grid {
              id: presetButtons
              anchors.centerIn: parent
              width: parent.width - Style.space(12)
              columns: 3
              spacing: Style.spacing.xs
              Repeater {
                model: Model.PRESETS
                Button {
                  required property var modelData
                  width: (presetButtons.width - 2 * presetButtons.spacing) / 3
                  text: modelData.label
                  fontSize: Style.font.caption
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  verticalPadding: Style.spacing.controlPaddingY
                  bordered: true
                  active: root.preset === modelData.value
                  onClicked: root.setPreset(modelData.value)
                }
              }
            }
          }

          PanelSeparator { foreground: root.bar.foreground }

          SliderRow {
            row: "gainR"; icon: "󰝤"; label: "RED GAIN"
            minimum: 0; maximum: 100; value: root.gainR
            onPicked: function(v) { root.setGainR(v) }
          }

          SliderRow {
            row: "gainG"; icon: "󰝤"; label: "GREEN GAIN"
            minimum: 0; maximum: 100; value: root.gainG
            onPicked: function(v) { root.setGainG(v) }
          }

          SliderRow {
            row: "gainB"; icon: "󰝤"; label: "BLUE GAIN"
            minimum: 0; maximum: 100; value: root.gainB
            onPicked: function(v) { root.setGainB(v) }
          }
        }

        Item { width: parent.width; height: Style.space(4) }
      }
    }
  }

  component SliderRow: Column {
    id: sr
    property string row
    property string icon
    property string label
    property real minimum: 0
    property real maximum: 100
    property int ticks: 0
    property int value: 0
    property string suffix: ""
    property string valueText: String(Math.round(slider.dragging ? slider.liveValue : value)) + suffix
    signal picked(int v)

    width: parent ? parent.width : 0
    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: header.implicitHeight
      PanelSectionHeader {
        id: header
        text: sr.icon + "  " + sr.label
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }
      Text {
        text: sr.valueText
        color: Qt.darker(root.bar.foreground, 1.4)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        anchors.right: parent.right
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    CursorSurface {
      width: parent.width
      height: slider.implicitHeight + Style.spacing.controlGap
      hasCursor: root.cursorActive && root.cursorRow === sr.row
      foreground: root.bar.foreground
      outline: true
      PanelSlider {
        id: slider
        bar: root.bar
        anchors.fill: parent
        anchors.leftMargin: Style.space(6)
        anchors.rightMargin: Style.space(6)
        minimum: sr.minimum
        maximum: sr.maximum
        step: 1
        integer: true
        tickCount: sr.ticks
        value: sr.value
        // Instant: every move is written; the queue drops superseded values.
        onMoved: function(v) { if (Math.round(v) !== sr.value) sr.picked(Math.round(v)) }
        onReleased: function(v) { if (Math.round(v) !== sr.value) sr.picked(Math.round(v)) }
      }
      HoverHandler { onHoveredChanged: if (hovered) { root.cursorActive = true; root.cursorRow = sr.row } }
    }
  }
}
