import QtQuick
import Quickshell
import Quickshell.Io

// Shared plugin service (one per shell, however many bars there are): owns
// the walkingpad.py bridge process. The bridge keeps the Bluetooth link
// open and prints its whole state as one JSON line whenever anything changes;
// commands go back over its stdin. Everything here is a mirror of that state
// plus a little optimism so the UI reacts before the pad confirms.
Item {
  id: root

  property var settings: ({})
  // Panels fall back to an inert copy while the shared service is loading;
  // only the real one may start the bridge or claim the IPC target.
  property bool primary: true

  function setting(name, fallback) {
    var v = settings ? settings[name] : undefined
    return v === undefined || v === null || v === "" ? fallback : v
  }

  readonly property string scriptPath: Qt.resolvedUrl("walkingpad.py").toString().replace(/^file:\/\//, "")
  // System Python, not whatever mise/pyenv puts first on PATH: dbus-fast comes
  // from the python-dbus-fast package.
  readonly property string python: "/usr/bin/python3"

  readonly property real minSpeed: 0.5
  readonly property real maxSpeed: Number(setting("maxSpeed", "6.0")) || 6.0
  readonly property real speedStep: Number(setting("speedStep", "0.5")) || 0.5
  readonly property string startSpeed: String(setting("startSpeed", "2.0"))
  readonly property bool autoConnect: String(setting("autoConnect", "on")) !== "off"

  // Mirrored from the bridge.
  property string connection: "starting"
  property string deviceName: ""
  property string deviceAddress: ""
  property string error: ""
  property var status: null
  property var today: ({ steps: 0, distance: 0, time: 0 })
  property var week: []

  readonly property bool connected: connection === "connected"
  readonly property bool busy: connection === "scanning" || connection === "connecting" || connection === "starting"
  readonly property int belt: status ? status.belt : -1
  readonly property bool running: connected && belt === 1
  readonly property bool starting: connected && belt === 9
  readonly property string mode: status ? status.mode : ""
  readonly property real speed: status ? status.speed : 0

  // Optimistic target speed: set on click, cleared once the pad agrees or
  // gives up, so the slider doesn't snap back while the command is in flight.
  property real pendingSpeed: -1
  readonly property real displaySpeed: pendingSpeed >= 0 ? pendingSpeed : speed

  readonly property string statusText: {
    if (connection === "starting") return "Starting…"
    if (connection === "scanning") return "Searching for WalkingPad…"
    if (connection === "connecting") return "Connecting…"
    if (connection === "no-adapter") return "Bluetooth is off"
    if (!connected) return error !== "" ? "Disconnected" : "Not connected"
    if (!status) return "Connected"
    if (running) return "Walking · " + mode
    if (starting) return "Starting belt…"
    if (mode === "standby") return "Standby"
    return "Ready · " + mode
  }

  onStatusChanged: {
    if (pendingSpeed >= 0 && status && Math.abs(status.speed - pendingSpeed) < 0.05) pendingSpeed = -1
  }

  Timer {
    id: pendingTimeout
    interval: 8000
    onTriggered: root.pendingSpeed = -1
  }

  function send(line) {
    if (!bridge.running) return
    bridge.write(line + "\n")
  }

  function clampSpeed(v) {
    return Math.round(Math.max(minSpeed, Math.min(maxSpeed, v)) * 10) / 10
  }

  function start() {
    send(startSpeed === "keep" ? "start" : "start " + startSpeed)
  }
  function stop() { pendingSpeed = -1; send("stop") }
  function toggleBelt() { running || starting ? stop() : start() }
  function setSpeed(v) {
    var s = clampSpeed(v)
    pendingSpeed = s
    pendingTimeout.restart()
    send("speed " + s.toFixed(1))
  }
  function faster() { if (running) setSpeed(displaySpeed + speedStep) }
  function slower() { if (running) setSpeed(displaySpeed - speedStep) }
  function setMode(m) { send("mode " + m) }
  function connect() { send("connect") }
  function disconnect() { send("disconnect") }
  function toggleConnection() { connected || busy ? disconnect() : connect() }
  function forget() { send("forget") }

  function ingest(line) {
    var s
    try { s = JSON.parse(line) } catch (e) { return }
    connection = s.connection || "idle"
    deviceName = s.name || ""
    deviceAddress = s.address || ""
    error = s.error || ""
    status = s.status || null
    today = s.today || today
    week = s.week || week
  }

  readonly property var bridgeArgs: {
    var a = [python, scriptPath, "--min-speed", minSpeed.toFixed(1), "--max-speed", maxSpeed.toFixed(1), "--step", speedStep.toFixed(1)]
    if (!autoConnect) a.push("--no-auto-connect")
    return a
  }

  // Restart the bridge when its arguments change, after a short debounce so a
  // settings edit that touches several keys only restarts it once.
  onBridgeArgsChanged: if (bridge.running) restartDebounce.restart()

  Timer {
    id: restartDebounce
    interval: 300
    onTriggered: { root.send("quit"); respawn.restart() }
  }

  Process {
    id: bridge
    command: root.bridgeArgs
    stdinEnabled: true
    running: root.primary
    stdout: SplitParser {
      onRead: function(line) { root.ingest(line) }
    }
    stderr: SplitParser {
      onRead: function(line) { console.warn("walkingpad:", line) }
    }
    onExited: function(code) {
      root.connection = "starting"
      root.status = null
      respawn.restart()
    }
  }

  // If the bridge dies (Python missing, BlueZ restarted…) bring it back.
  Timer {
    id: respawn
    interval: 3000
    onTriggered: if (root.primary && !bridge.running) bridge.running = true
  }

  // omarchy-shell walkingpad <fn>  — for Hyprland keybindings and scripts.
  IpcHandler {
    enabled: root.primary
    target: "walkingpad"
    function start(): string { root.start(); return "ok" }
    function stop(): string { root.stop(); return "ok" }
    function toggle(): string { root.toggleBelt(); return "ok" }
    function faster(): string { root.faster(); return "ok" }
    function slower(): string { root.slower(); return "ok" }
    function speed(kmh: string): string { root.setSpeed(Number(kmh)); return "ok" }
    function mode(name: string): string { root.setMode(name); return "ok" }
    function connect(): string { root.connect(); return "ok" }
    function disconnect(): string { root.disconnect(); return "ok" }
    function status(): string {
      return JSON.stringify({ connection: root.connection, device: root.deviceName, status: root.status, today: root.today })
    }
  }

  Component.onDestruction: send("quit")
}
