import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Bar button + popup for the WalkingPad.
//
// Bar:   left = popup · right = start/stop · middle = connect/disconnect
//        scroll = speed up/down (while walking)
// Popup: space/s = start/stop · ←/→ or -/+ = speed · m = cycle mode
//        c = connect/disconnect · esc = close
Panel {
  id: root
  moduleName: "io.github.kristijanzrno.walkingpad"
  ipcTarget: "io.github.kristijanzrno.walkingpad"
  manageIpc: false

  readonly property string glyphWalk: "󰖃"
  readonly property string glyphPlay: "󰐊"
  readonly property string glyphStop: "󰓛"
  readonly property string glyphMinus: "󰍴"
  readonly property string glyphPlus: "󰐕"

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color accent: Commons.Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string barLabel: String(setting("barLabel", "speed"))
  readonly property string barText: {
    if (!pad.running || barLabel === "icon") return glyphWalk
    if (barLabel === "steps") return glyphWalk + " " + (pad.status ? pad.status.steps : 0)
    if (barLabel === "today") return glyphWalk + " " + formatSteps(pad.today.steps)
    return glyphWalk + " " + pad.displaySpeed.toFixed(1)
  }

  // ── Formatting ────────────────────────────────────────────────────────────
  function formatDuration(sec) {
    sec = Math.max(0, Math.floor(sec || 0))
    var h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60
    function two(n) { return n < 10 ? "0" + n : String(n) }
    return h > 0 ? h + ":" + two(m) + ":" + two(s) : m + ":" + two(s)
  }
  function formatKm(metres) { return ((metres || 0) / 1000).toFixed(2) }
  function formatSteps(n) {
    n = n || 0
    return n >= 10000 ? (n / 1000).toFixed(1) + "k" : String(n)
  }

  function cycleMode() {
    var order = ["manual", "auto", "standby"]
    var i = order.indexOf(pad.mode)
    pad.setMode(order[(i + 1) % order.length])
  }

  // One shared service owns the Bluetooth link; every bar's widget reads it.
  readonly property var sharedPad: bar && bar.shell ? bar.shell.serviceFor("io.github.kristijanzrno.walkingpad") : null
  readonly property var pad: sharedPad || fallbackPad

  Service {
    id: fallbackPad
    primary: false
  }

  // The host doesn't hand services their settings; the widget does.
  function pushSettings() { if (sharedPad) sharedPad.settings = root.settings }
  onSettingsChanged: pushSettings()
  onSharedPadChanged: pushSettings()

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  onOpenedChanged: if (opened) Qt.callLater(function() { keyCatcher.forceActiveFocus() })

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText
    fontSize: pad.running ? Style.font.body : Style.bar.iconFont
    horizontalMargin: pad.running && root.barLabel !== "icon" ? 8 : 7
    dimmed: !pad.connected
    tooltipText: root.opened ? "" : "WalkingPad · " + pad.statusText
    onPressed: function(b) {
      if (b === Qt.RightButton) pad.toggleBelt()
      else if (b === Qt.MiddleButton) pad.toggleConnection()
      else root.toggle()
    }
    onWheelMoved: function(delta) {
      if (delta > 0) pad.faster()
      else if (delta < 0) pad.slower()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        var d = dx !== 0 ? dx : -dy
        if (d > 0) pad.faster()
        else if (d < 0) pad.slower()
      }
      onActivateRequested: pad.toggleBelt()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var k = t.toLowerCase()
        if (k === " " || k === "s") pad.toggleBelt()
        else if (k === "+" || k === "=") pad.faster()
        else if (k === "-" || k === "_") pad.slower()
        else if (k === "m") root.cycleMode()
        else if (k === "c") pad.toggleConnection()
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: flick.width
          spacing: Style.space(12)

          // ── Header ────────────────────────────────────────────────────────
          PanelHero {
            id: hero
            width: parent.width
            title: pad.deviceName !== "" ? "WalkingPad " + pad.deviceName : "WalkingPad"
            meta: pad.statusText
            detail: pad.running ? pad.displaySpeed.toFixed(1) + " km/h" : ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: pad.connected ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                text: root.glyphWalk
                color: pad.running ? root.accent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              ToggleSwitch {
                id: linkSwitch
                checked: pad.connected || pad.busy
                busy: pad.busy
                foreground: root.foreground
                onToggled: pad.toggleConnection()
                PanelToolTip {
                  visible: linkSwitch.containsMouse
                  text: pad.connected ? "Disconnect (frees the pad for the phone app)" : "Connect over Bluetooth"
                  fontFamily: root.fontFamily
                }
              }
            }
          }

          Text {
            visible: pad.error !== "" && !pad.connected
            width: parent.width
            text: pad.error
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ── Belt ──────────────────────────────────────────────────────────
          Column {
            visible: pad.connected
            width: parent.width
            spacing: Style.space(12)

            PanelSeparator { foreground: root.foreground }

            Button {
              width: parent.width
              bordered: true
              text: pad.running || pad.starting ? "Stop belt" : "Start belt"
              iconText: pad.running || pad.starting ? root.glyphStop : root.glyphPlay
              foreground: root.foreground
              fontFamily: root.fontFamily
              tooltipText: pad.running || pad.starting ? "" : "The pad counts down 3 seconds before the belt moves"
              onClicked: pad.toggleBelt()
            }

            Item {
              width: parent.width
              implicitHeight: speedRow.implicitHeight

              RowLayout {
                id: speedRow
                anchors.left: parent.left
                anchors.right: parent.right
                spacing: Style.space(8)

                PanelActionButton {
                  iconText: root.glyphMinus
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  enabled: pad.running && pad.displaySpeed > pad.minSpeed
                  tooltipText: "Slower"
                  onClicked: pad.slower()
                }

                PanelSlider {
                  Layout.fillWidth: true
                  bar: root.bar
                  enabled: pad.running
                  opacity: enabled ? 1 : 0.4
                  minimum: pad.minSpeed
                  maximum: pad.maxSpeed
                  step: pad.speedStep
                  value: pad.displaySpeed
                  onReleased: function(v) { pad.setSpeed(Math.round(v / pad.speedStep) * pad.speedStep) }
                }

                PanelActionButton {
                  iconText: root.glyphPlus
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  enabled: pad.running && pad.displaySpeed < pad.maxSpeed
                  tooltipText: "Faster"
                  onClicked: pad.faster()
                }

                Text {
                  Layout.minimumWidth: Style.space(64)
                  horizontalAlignment: Text.AlignRight
                  text: pad.displaySpeed.toFixed(1) + " km/h"
                  color: pad.running ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
              }
            }

            ButtonGroup {
              options: [
                { value: "manual", label: "Manual", tooltip: "Speed set from here or the remote" },
                { value: "auto", label: "Auto", tooltip: "Speed follows where you stand on the belt" },
                { value: "standby", label: "Standby", tooltip: "Sleep" }
              ]
              value: pad.mode
              foreground: root.foreground
              fontFamily: root.fontFamily
              focusable: false
              onChanged: function(v) { pad.setMode(v) }
            }

            PanelSectionHeader {
              text: "SESSION"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            StatRow {
              width: parent.width
              time: pad.status ? pad.status.time : 0
              distance: pad.status ? pad.status.distance : 0
              steps: pad.status ? pad.status.steps : 0
            }
          }

          // ── Today / week ─────────────────────────────────────────────────
          PanelSeparator { foreground: root.foreground }

          PanelSectionHeader {
            text: "TODAY"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          StatRow {
            width: parent.width
            time: pad.today.time
            distance: pad.today.distance
            steps: pad.today.steps
          }

          WeekChart {
            width: parent.width
            visible: pad.week.length > 0
          }

          Text {
            visible: pad.deviceAddress !== ""
            width: parent.width
            text: pad.deviceAddress + (pad.connected ? "" : "  ·  click to forget")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignRight
            MouseArea {
              anchors.fill: parent
              enabled: !pad.connected
              cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
              onClicked: pad.forget()
            }
          }
        }
      }
    }
  }

  // Three numbers side by side: time, km, steps.
  component StatRow: RowLayout {
    property int time: 0
    property int distance: 0
    property int steps: 0
    spacing: Style.space(8)

    Stat { Layout.fillWidth: true; value: root.formatDuration(parent.time); label: "time" }
    Stat { Layout.fillWidth: true; value: root.formatKm(parent.distance); label: "km" }
    Stat { Layout.fillWidth: true; value: String(parent.steps); label: "steps" }
  }

  component Stat: Column {
    property string value: ""
    property string label: ""
    spacing: Style.space(1)

    Text {
      text: parent.value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.heading
      font.bold: true
    }
    Text {
      text: parent.label.toUpperCase()
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.2
    }
  }

  // Seven bars of daily steps, today on the right.
  component WeekChart: Item {
    id: chart
    readonly property int maxSteps: {
      var m = 1
      for (var i = 0; i < pad.week.length; i++) m = Math.max(m, pad.week[i].steps || 0)
      return m
    }
    readonly property real barArea: Style.space(44)
    implicitHeight: barArea + Style.space(16)

    Row {
      anchors.fill: parent
      spacing: Style.space(6)

      // Model is the day count, not the array: the bridge sends a fresh array
      // every second while walking, and binding to it would rebuild every
      // delegate (and drop an open tooltip) on each update.
      Repeater {
        model: pad.week.length
        Item {
          required property int index
          readonly property var modelData: pad.week[index] || ({ date: "", steps: 0, distance: 0 })
          readonly property bool isToday: index === pad.week.length - 1
          width: (chart.width - Style.space(6) * (pad.week.length - 1)) / Math.max(1, pad.week.length)
          height: chart.height

          Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: dayLabel.top
            anchors.bottomMargin: Style.space(3)
            width: parent.width
            height: Math.max(2, chart.barArea * (modelData.steps || 0) / chart.maxSteps)
            radius: Style.cornerRadius > 0 ? 2 : 0
            color: isToday ? root.accent : root.foreground
            opacity: (modelData.steps || 0) > 0 ? (isToday ? 1 : 0.55) : 0.15
          }

          Text {
            id: dayLabel
            anchors.bottom: parent.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            text: modelData.date === "" ? "" : ["S", "M", "T", "W", "T", "F", "S"][new Date(modelData.date + "T12:00:00").getDay()]
            color: isToday ? root.foreground : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: isToday
          }

          MouseArea {
            id: dayHover
            anchors.fill: parent
            hoverEnabled: true
          }
          PanelToolTip {
            visible: dayHover.containsMouse
            text: modelData.date + " · " + (modelData.steps || 0) + " steps · " + root.formatKm(modelData.distance) + " km"
            fontFamily: root.fontFamily
          }
        }
      }
    }
  }
}
