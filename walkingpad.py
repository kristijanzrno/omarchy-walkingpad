#!/usr/bin/python3
"""Bluetooth bridge between the Omarchy shell and a KingSmith WalkingPad.

Talks to BlueZ over D-Bus (dbus-fast, no other dependencies) and speaks the
WalkingPad "FE00" protocol used by the A1/R1/R1 Pro/C1 family.

stdin  — one command per line:
    start | stop | speed <km/h> | faster | slower | mode <manual|auto|standby>
    connect | disconnect | forget | quit
stdout — one JSON object per line, the full current state every time it
         changes (see State.snapshot()).

Run by hand for debugging:  /usr/bin/python3 walkingpad.py --verbose
"""

import argparse
import asyncio
import datetime
import json
import os
import re
import sys
import time

from dbus_fast import BusType, Message, MessageType, Variant
from dbus_fast.aio import MessageBus

BLUEZ = "org.bluez"
SERVICE_UUID = "0000fe00-0000-1000-8000-00805f9b34fb"
NOTIFY_UUID = "0000fe01-0000-1000-8000-00805f9b34fb"
WRITE_UUID = "0000fe02-0000-1000-8000-00805f9b34fb"
NAME_RE = re.compile(r"walkingpad|^ks-|^r1|^a1|^c1|^c2|^z1", re.I)

MODES = {"auto": 0, "manual": 1, "standby": 2}
MODE_NAMES = {v: k for k, v in MODES.items()}
# The pad wants a little room between commands or it drops them.
COMMAND_GAP = 0.7
POLL_INTERVAL = 1.0

STATE_DIR = os.path.join(
    os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"), "omarchy-walkingpad"
)
DEVICE_FILE = os.path.join(STATE_DIR, "device.json")
HISTORY_FILE = os.path.join(STATE_DIR, "history.json")
HISTORY_DAYS = 30

VERBOSE = False


def log(*args):
    if VERBOSE:
        print(*args, file=sys.stderr, flush=True)


# ── Protocol ────────────────────────────────────────────────────────────────


def frame(*payload):
    """F7 <payload…> <checksum> FD, checksum = sum(payload) & 0xFF."""
    body = bytes(payload)
    return bytes([0xF7]) + body + bytes([sum(body) & 0xFF, 0xFD])


def cmd_ask_stats():
    return frame(0xA2, 0x00, 0x00)


def cmd_speed(tenths):
    return frame(0xA2, 0x01, max(0, min(255, int(tenths))))


def cmd_mode(mode):
    return frame(0xA2, 0x02, mode)


def cmd_start_belt():
    return frame(0xA2, 0x04, 0x01)


def u24(b, i):
    return (b[i] << 16) | (b[i + 1] << 8) | b[i + 2]


def parse_status(data):
    """F8 A2 frame → dict, or None for anything else."""
    if len(data) < 17 or data[0] != 0xF8 or data[1] != 0xA2:
        return None
    return {
        "belt": data[2],  # 0 idle, 1 running, 9 starting, others = transitional
        "speed": data[3] / 10.0,  # km/h
        "mode": MODE_NAMES.get(data[4], str(data[4])),
        "time": u24(data, 5),  # seconds this session
        "distance": u24(data, 8) * 10,  # metres this session
        "steps": u24(data, 11),
    }


# ── Persistence ─────────────────────────────────────────────────────────────


def read_json(path, fallback):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return fallback


def write_json(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(value, f)
    os.replace(tmp, path)


class History:
    """Per-day totals built from the pad's per-session counters.

    The pad's counters only go up within a session and drop back to zero when
    a new one begins, so a drop means "new session": count the new value from
    zero instead of as a negative delta.
    """

    def __init__(self):
        self.days = read_json(HISTORY_FILE, {})
        self.last = None
        self.dirty_since = 0.0

    def today_key(self):
        return datetime.date.today().isoformat()

    def update(self, status):
        cur = (status["steps"], status["distance"], status["time"])
        if self.last is None:
            # First reading after (re)connecting: we can't know what part of it
            # was already counted, so just take it as the baseline.
            self.last = cur
            return
        deltas = [c - p if c >= p else c for c, p in zip(cur, self.last)]
        self.last = cur
        if not any(deltas):
            return
        day = self.days.setdefault(self.today_key(), {"steps": 0, "distance": 0, "time": 0})
        day["steps"] += deltas[0]
        day["distance"] += deltas[1]
        day["time"] += deltas[2]
        if not self.dirty_since:
            self.dirty_since = time.monotonic()

    def reset_baseline(self):
        self.last = None

    def flush(self, force=False):
        if not self.dirty_since:
            return
        if not force and time.monotonic() - self.dirty_since < 30:
            return
        keep = sorted(self.days)[-HISTORY_DAYS:]
        self.days = {k: self.days[k] for k in keep}
        write_json(HISTORY_FILE, self.days)
        self.dirty_since = 0.0

    def recent(self, n=7):
        today = datetime.date.today()
        out = []
        for i in range(n - 1, -1, -1):
            d = (today - datetime.timedelta(days=i)).isoformat()
            entry = self.days.get(d, {"steps": 0, "distance": 0, "time": 0})
            out.append({"date": d, **entry})
        return out


# ── BlueZ ───────────────────────────────────────────────────────────────────


class Bridge:
    def __init__(self, address=None):
        saved = read_json(DEVICE_FILE, {})
        self.address = (address or saved.get("address") or "").upper()
        self.name = saved.get("name", "")
        self.bus = None
        self.adapter = None
        self.device_path = None
        self.write_path = None
        self.notify_path = None

        self.connection = "idle"  # idle|scanning|connecting|connected|disconnected|no-adapter|error
        self.error = ""
        self.status = None
        self.history = History()
        self.want_connected = True
        self.start_speed = None  # (km/h, deadline) to apply once the belt runs

        self.queue = asyncio.Queue()
        self.wake = asyncio.Event()
        self.last_emit = None

    # Output ------------------------------------------------------------------

    def emit(self):
        snap = {
            "connection": self.connection,
            "address": self.address,
            "name": self.name,
            "error": self.error,
            "status": self.status,
            "today": self.history.recent(1)[0],
            "week": self.history.recent(7),
        }
        line = json.dumps(snap, separators=(",", ":"))
        if line != self.last_emit:
            self.last_emit = line
            print(line, flush=True)

    def set_connection(self, value, error=""):
        self.connection = value
        self.error = error
        if value != "connected":
            self.status = None
            self.history.reset_baseline()
        self.emit()

    # D-Bus helpers -----------------------------------------------------------

    async def call(self, path, interface, member, signature="", body=None, timeout=None):
        msg = Message(
            destination=BLUEZ,
            path=path,
            interface=interface,
            member=member,
            signature=signature,
            body=body or [],
        )
        coro = self.bus.call(msg)
        reply = await (asyncio.wait_for(coro, timeout) if timeout else coro)
        if reply.message_type == MessageType.ERROR:
            raise RuntimeError(f"{reply.error_name}: {reply.body[0] if reply.body else ''}")
        return reply.body

    async def objects(self):
        (objs,) = await self.call("/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects")
        return objs

    async def prop(self, path, interface, name):
        (v,) = await self.call(
            path, "org.freedesktop.DBus.Properties", "Get", "ss", [interface, name]
        )
        return v.value

    async def find_adapter(self):
        for path, ifaces in (await self.objects()).items():
            if "org.bluez.Adapter1" in ifaces:
                if ifaces["org.bluez.Adapter1"]["Powered"].value:
                    return path
        return None

    def match_device(self, path, ifaces):
        dev = ifaces.get("org.bluez.Device1")
        if not dev or not path.startswith(self.adapter + "/"):
            return False
        addr = dev["Address"].value.upper()
        if self.address:
            return addr == self.address
        uuids = dev["UUIDs"].value if "UUIDs" in dev else []
        name = dev["Name"].value if "Name" in dev else ""
        return SERVICE_UUID in uuids or bool(NAME_RE.search(name))

    async def find_device(self):
        for path, ifaces in (await self.objects()).items():
            if self.match_device(path, ifaces):
                return path, ifaces["org.bluez.Device1"]
        return None, None

    async def discover(self, timeout=25):
        """Scan until the pad shows up, then stop scanning."""
        self.set_connection("scanning")
        try:
            await self.call(
                self.adapter,
                "org.bluez.Adapter1",
                "SetDiscoveryFilter",
                "a{sv}",
                [{"Transport": Variant("s", "le")}],
            )
        except RuntimeError as e:
            log("discovery filter:", e)
        started = False
        try:
            try:
                await self.call(self.adapter, "org.bluez.Adapter1", "StartDiscovery")
                started = True
            except RuntimeError as e:
                # InProgress is fine: someone else is scanning and we'll see it.
                if "InProgress" not in str(e):
                    raise
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline and self.want_connected:
                path, dev = await self.find_device()
                if path:
                    return path, dev
                await asyncio.sleep(1)
            return None, None
        finally:
            if started:
                try:
                    await self.call(self.adapter, "org.bluez.Adapter1", "StopDiscovery")
                except RuntimeError:
                    pass

    # Connection --------------------------------------------------------------

    async def connect_once(self):
        self.adapter = await self.find_adapter()
        if not self.adapter:
            self.set_connection("no-adapter", "No powered Bluetooth adapter")
            return False

        path, dev = await self.find_device()
        if not path:
            path, dev = await self.discover()
        if not path:
            self.set_connection(
                "disconnected",
                "WalkingPad not found. Is it powered on and not connected to the phone app?",
            )
            return False

        self.device_path = path
        self.address = dev["Address"].value.upper()
        self.name = dev["Name"].value if "Name" in dev else self.name or "WalkingPad"
        write_json(DEVICE_FILE, {"address": self.address, "name": self.name})

        self.set_connection("connecting")
        if not await self.prop(path, "org.bluez.Device1", "Connected"):
            await self.call(path, "org.bluez.Device1", "Connect", timeout=30)

        for _ in range(40):
            if await self.prop(path, "org.bluez.Device1", "ServicesResolved"):
                break
            await asyncio.sleep(0.25)
        else:
            raise RuntimeError("Services never resolved")

        self.write_path = self.notify_path = None
        for p, ifaces in (await self.objects()).items():
            ch = ifaces.get("org.bluez.GattCharacteristic1")
            if not ch or not p.startswith(path + "/"):
                continue
            uuid = ch["UUID"].value.lower()
            if uuid == WRITE_UUID:
                self.write_path = p
            elif uuid == NOTIFY_UUID:
                self.notify_path = p
        if not (self.write_path and self.notify_path):
            raise RuntimeError("This device doesn't expose the WalkingPad FE01/FE02 characteristics")

        await self.call(self.notify_path, "org.bluez.GattCharacteristic1", "StartNotify")
        self.set_connection("connected")
        return True

    async def disconnect(self):
        if self.device_path:
            try:
                await self.call(self.device_path, "org.bluez.Device1", "Disconnect", timeout=10)
            except Exception as e:  # noqa: BLE001 — best effort
                log("disconnect:", e)
        self.set_connection("idle")

    def on_signal(self, msg):
        if msg.message_type != MessageType.SIGNAL or msg.member != "PropertiesChanged":
            return
        iface, changed = msg.body[0], msg.body[1]
        if iface == "org.bluez.GattCharacteristic1" and msg.path == self.notify_path:
            if "Value" in changed:
                data = bytes(changed["Value"].value)
                log("<-", data.hex(" "))
                st = parse_status(data)
                if st:
                    if self.start_speed and st["belt"] == 1:
                        target, deadline = self.start_speed
                        self.start_speed = None
                        if time.monotonic() < deadline:
                            self.queue.put_nowait(f"speed {target}")
                    self.status = st
                    self.history.update(st)
                    self.emit()
        elif iface == "org.bluez.Device1" and msg.path == self.device_path:
            if "Connected" in changed and not changed["Connected"].value:
                log("device dropped")
                if self.connection == "connected":
                    self.set_connection("disconnected", "Connection lost")
                self.wake.set()

    async def write(self, data):
        log("->", data.hex(" "))
        await self.call(
            self.write_path,
            "org.bluez.GattCharacteristic1",
            "WriteValue",
            "aya{sv}",
            [data, {}],
            timeout=5,
        )

    # Commands ----------------------------------------------------------------

    def current_speed(self):
        return self.status["speed"] if self.status else 0.0

    async def run_command(self, line, limits):
        parts = line.strip().split()
        if not parts:
            return
        cmd, args = parts[0].lower(), parts[1:]
        log("cmd:", line.strip())

        if cmd == "quit":
            raise SystemExit
        if cmd == "connect":
            self.want_connected = True
            self.wake.set()
            return
        if cmd == "disconnect":
            self.want_connected = False
            await self.disconnect()
            return
        if cmd == "forget":
            self.want_connected = False
            await self.disconnect()
            self.address, self.name = "", ""
            try:
                os.remove(DEVICE_FILE)
            except OSError:
                pass
            self.emit()
            return

        if self.connection != "connected":
            self.error = "Not connected"
            self.emit()
            return

        lo, hi, step = limits
        if cmd == "start":
            if self.status and self.status["mode"] != "manual":
                await self.write(cmd_mode(MODES["manual"]))
                await asyncio.sleep(COMMAND_GAP)
            await self.write(cmd_start_belt())
            # The pad ignores speed changes until the belt is actually moving,
            # so the start speed waits for the first "running" status.
            if args:
                self.start_speed = (round(max(lo, min(hi, float(args[0]))), 1), time.monotonic() + 20)
        elif cmd == "stop":
            self.start_speed = None
            await self.write(cmd_speed(0))
        elif cmd in ("speed", "faster", "slower"):
            if cmd == "speed":
                target = float(args[0])
            else:
                target = self.current_speed() + (step if cmd == "faster" else -step)
            target = round(max(lo, min(hi, target)), 1)
            await self.write(cmd_speed(round(target * 10)))
        elif cmd == "mode" and args and args[0] in MODES:
            await self.write(cmd_mode(MODES[args[0]]))
        elif cmd == "toggle":
            if self.status and self.status["belt"] == 1:
                await self.write(cmd_speed(0))
            else:
                await self.run_command("start", limits)
                return
        else:
            self.error = f"Unknown command: {line.strip()}"
            self.emit()
            return
        await asyncio.sleep(COMMAND_GAP)

    # Loops -------------------------------------------------------------------

    async def connection_loop(self):
        backoff = 3
        while True:
            if self.want_connected and self.connection != "connected":
                try:
                    if await self.connect_once():
                        backoff = 3
                except Exception as e:  # noqa: BLE001
                    log("connect failed:", e)
                    self.set_connection("disconnected", str(e))
                if self.connection != "connected":
                    self.wake.clear()
                    try:
                        await asyncio.wait_for(self.wake.wait(), backoff)
                    except asyncio.TimeoutError:
                        pass
                    backoff = min(30, backoff * 2)
                    continue
            self.wake.clear()
            try:
                await asyncio.wait_for(self.wake.wait(), 5)
            except asyncio.TimeoutError:
                pass

    async def command_loop(self, limits):
        """Single writer: commands and stat polls share one queue so the pad
        always gets its breathing room between frames."""
        while True:
            try:
                line = await asyncio.wait_for(self.queue.get(), POLL_INTERVAL)
            except asyncio.TimeoutError:
                line = None
            try:
                if line is not None:
                    await self.run_command(line, limits)
                elif self.connection == "connected":
                    await self.write(cmd_ask_stats())
            except SystemExit:
                raise
            except Exception as e:  # noqa: BLE001
                log("command failed:", e)
                self.error = str(e)
                self.emit()
            self.history.flush()

    async def stdin_loop(self):
        loop = asyncio.get_running_loop()
        reader = asyncio.StreamReader()
        await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin)
        while True:
            line = await reader.readline()
            if not line:  # shell went away
                raise SystemExit
            await self.queue.put(line.decode(errors="replace"))

    async def run(self, limits):
        self.bus = await MessageBus(bus_type=BusType.SYSTEM).connect()
        self.bus.add_message_handler(self.on_signal)
        await self.call_bus_match(
            "type='signal',sender='org.bluez',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged'"
        )
        self.emit()
        tasks = [
            asyncio.create_task(self.connection_loop()),
            asyncio.create_task(self.command_loop(limits)),
            asyncio.create_task(self.stdin_loop()),
        ]
        try:
            done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_EXCEPTION)
            for t in done:
                t.result()
        finally:
            for t in tasks:
                t.cancel()
            self.history.flush(force=True)
            # Leave the pad free for the phone app once the shell lets go.
            if self.connection == "connected":
                await self.disconnect()

    async def call_bus_match(self, rule):
        await self.bus.call(
            Message(
                destination="org.freedesktop.DBus",
                path="/org/freedesktop/DBus",
                interface="org.freedesktop.DBus",
                member="AddMatch",
                signature="s",
                body=[rule],
            )
        )


def main():
    global VERBOSE
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--address", help="Bluetooth address (otherwise auto-detect, then remembered)")
    ap.add_argument("--min-speed", type=float, default=0.5)
    ap.add_argument("--max-speed", type=float, default=6.0)
    ap.add_argument("--step", type=float, default=0.5)
    ap.add_argument("--no-auto-connect", action="store_true", help="wait for a 'connect' command")
    ap.add_argument("--verbose", "-v", action="store_true", help="log frames to stderr")
    a = ap.parse_args()
    VERBOSE = a.verbose
    bridge = Bridge(a.address)
    bridge.want_connected = not a.no_auto_connect
    try:
        asyncio.run(bridge.run((a.min_speed, a.max_speed, a.step)))
    except (SystemExit, KeyboardInterrupt):
        pass


if __name__ == "__main__":
    main()
