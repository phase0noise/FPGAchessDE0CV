"""Start the standalone app and its Pi hotspot without requiring a systemd unit."""
from __future__ import annotations

import argparse
import ipaddress
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
from urllib.error import URLError
from urllib.request import urlopen
import uuid

ROOT = Path(__file__).resolve().parent
CACHE = ROOT / ".cache"
STATE = CACHE / "server.json"
LOG = CACHE / "server.log"
PROFILE = "de0cv-chess-hotspot"
ADDRESS = "10.42.0.1"


def is_pi():
    if sys.platform != "linux":
        return False
    model = Path("/proc/device-tree/model")
    return (model.exists() and b"Raspberry Pi" in model.read_bytes()) or bool(shutil.which("raspi-config"))


def command(arguments, *, root=False, check=True):
    prefix = ["sudo"] if root and os.geteuid() != 0 else []
    result = subprocess.run([*prefix, *arguments], capture_output=True, text=True,
                            env={**os.environ, "LC_ALL": "C"}, timeout=90)
    if check and result.returncode:
        raise RuntimeError(f"{' '.join(arguments[:3])} failed: {(result.stderr or result.stdout).strip()}")
    return result


def read_state():
    try:
        state = json.loads(STATE.read_text(encoding="utf-8"))
        if (not isinstance(state, dict) or not isinstance(state.get("port"), int)
                or not isinstance(state.get("pid"), int) or not isinstance(state.get("instance"), str)):
            return {}
        return state
    except (OSError, ValueError):
        return {}


def write_state(state):
    CACHE.mkdir(exist_ok=True)
    temporary = STATE.with_suffix(".tmp")
    temporary.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
    temporary.replace(STATE)


def ready(port):
    try:
        with urlopen(f"http://127.0.0.1:{port}/readyz", timeout=1) as response:
            result = json.load(response)
            return result if isinstance(result, dict) else {}
    except (OSError, ValueError, URLError):
        return {}


def running(state):
    if not state:
        return False
    status = ready(state["port"])
    return (status.get("app") == "de0cv-chess" and status.get("instance") == state.get("instance")
            and status.get("pid") == state.get("pid"))


def start_server(port):
    state = read_state()
    if running(state):
        if state["port"] != port:
            raise RuntimeError(f"This folder is already serving port {state['port']}. Run python3 run.py stop first.")
        return state
    with socket.socket() as listener:
        try:
            listener.bind(("0.0.0.0", port))
        except OSError as error:
            raise RuntimeError(f"Port {port} is already in use. Stop the older chess program before starting this copy.") from error
    CACHE.mkdir(exist_ok=True)
    instance = uuid.uuid4().hex
    arguments = [sys.executable, str(ROOT / "run.py"), "serve", "--port", str(port)]
    if is_pi() and Path("/dev/spidev0.0").exists() and not os.access("/dev/spidev0.0", os.R_OK | os.W_OK):
        import pwd
        user = pwd.getpwuid(os.getuid()).pw_name
        command(["usermod", "-a", "-G", "spi", user], root=True)
        if shutil.which("sg"):
            arguments = ["sg", "spi", "-c", shlex.join(arguments)]
    environment = {**os.environ, "CHESS_INSTANCE_ID": instance, "PYTHONUNBUFFERED": "1"}
    options = {"start_new_session": True} if os.name == "posix" else {
        "creationflags": subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP}
    with LOG.open("a", encoding="utf-8") as log:
        process = subprocess.Popen(arguments, cwd=ROOT, env=environment, stdin=subprocess.DEVNULL,
                                   stdout=log, stderr=subprocess.STDOUT, **options)
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        status = ready(port)
        if status.get("instance") == instance:
            state = dict(port=port, pid=status["pid"], instance=instance)
            write_state(state)
            return state
        if process.poll() is not None:
            break
        time.sleep(0.1)
    if process.poll() is None:
        process.terminate()
    raise RuntimeError("The web server did not start. Details:\n" + LOG.read_text(encoding="utf-8", errors="replace")[-4000:])


def select_wifi(interface=None):
    if not shutil.which("nmcli"):
        raise RuntimeError("Hotspot mode needs NetworkManager (Raspberry Pi OS Bookworm or newer). Use --lan to run on your existing network.")
    devices = command(["nmcli", "-t", "-f", "DEVICE,TYPE", "device", "status"]).stdout.splitlines()
    interfaces = [line.rsplit(":", 1)[0] for line in devices if line.endswith(":wifi")]
    if interface:
        interfaces = [name for name in interfaces if name == interface]
    for name in interfaces:
        capability = command(["nmcli", "-g", "WIFI-PROPERTIES.AP", "device", "show", name], check=False)
        if capability.stdout.strip().lower() == "yes":
            return name
    raise RuntimeError("No Wi-Fi interface supports access-point mode. Check the Pi's wireless country/radio settings, or use --lan.")


def hotspot_properties(interface, ssid, password):
    return ["connection.interface-name", interface, "connection.autoconnect", "yes",
            "connection.autoconnect-priority", "100",
            "802-11-wireless.ssid", ssid, "802-11-wireless.mode", "ap",
            "802-11-wireless.band", "bg", "802-11-wireless-security.key-mgmt", "wpa-psk",
            "802-11-wireless-security.psk", password, "ipv4.method", "shared",
            "ipv4.addresses", ADDRESS + "/24", "ipv6.method", "disabled"]

def repair_service(autostart=False):
    target = Path("/etc/systemd/system/de0cv-chess.service")
    if not autostart and not target.exists():
        return
    import grp
    import pwd
    from install_service import render
    user = pwd.getpwnam(os.environ.get("SUDO_USER") or pwd.getpwuid(os.getuid()).pw_name)
    group = grp.getgrgid(user.pw_gid).gr_name
    with tempfile.TemporaryDirectory(prefix="de0cv-unit-") as directory:
        candidate = Path(directory) / "de0cv-chess.service"
        candidate.write_text(render(user.pw_name, group), encoding="utf-8", newline="\n")
        command(["systemd-analyze", "verify", str(candidate)])
        command(["systemctl", "stop", "de0cv-chess.service"], root=True, check=False)
        command(["install", "-m", "0644", str(candidate), str(target)], root=True)
        command(["systemctl", "daemon-reload"], root=True)
        if autostart:
            command(["systemctl", "enable", "de0cv-chess.service"], root=True)
    print("Replaced the old chess service file with a validated unit using this folder.", flush=True)


def enable_hotspot(state, interface, ssid, password):
    previous = command(["nmcli", "-g", "GENERAL.CON-UUID", "device", "show", interface], check=False).stdout.strip()
    current = command(["nmcli", "-g", "GENERAL.CONNECTION", "device", "show", interface], check=False).stdout.strip()
    if current != PROFILE:
        state["previous_connection"] = previous if previous != "--" else ""
    state.update(interface=interface, ssid=ssid)
    write_state(state)
    exists = command(["nmcli", "-g", "connection.uuid", "connection", "show", "id", PROFILE], check=False)
    properties = hotspot_properties(interface, ssid, password)
    if exists.returncode:
        command(["nmcli", "connection", "add", "type", "wifi", "ifname", interface,
                 "con-name", PROFILE, "ssid", ssid, *properties], root=True)
    else:
        command(["nmcli", "connection", "modify", "id", PROFILE, *properties], root=True)
    command(["nmcli", "radio", "wifi", "on"], root=True)
    print(f"Wi-Fi: {ssid}\nPassword: {password}\nOpen http://{ADDRESS}:{state['port']}", flush=True)
    print("The web server is running. Switching this Wi-Fi interface to the chess hotspot now.", flush=True)
    try:
        command(["nmcli", "--wait", "30", "connection", "up", "id", PROFILE, "ifname", interface], root=True)
        addresses = command(["nmcli", "-g", "IP4.ADDRESS", "device", "show", interface]).stdout
        if ADDRESS + "/24" not in addresses:
            raise RuntimeError("The hotspot did not acquire its fixed address.")
    except (RuntimeError, subprocess.TimeoutExpired):
        if state.get("previous_connection"):
            command(["nmcli", "--wait", "20", "connection", "up", "uuid", state["previous_connection"]], root=True, check=False)
        raise


def local_urls(port):
    addresses = {"127.0.0.1"}
    if sys.platform == "linux":
        result = command(["hostname", "-I"], check=False)
        addresses.update(result.stdout.split())
    else:
        addresses.update(item[4][0] for item in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET))
    return [f"http://{address}:{port}" for address in sorted(addresses)
            if ipaddress.ip_address(address).version == 4]


def stop():
    state = read_state()
    if running(state):
        os.kill(state["pid"], signal.SIGTERM)
        deadline = time.monotonic() + 8
        while running(state) and time.monotonic() < deadline:
            time.sleep(0.1)
        if running(state):
            raise RuntimeError("The chess process did not stop.")
    if state.get("interface") and shutil.which("nmcli"):
        current = command(["nmcli", "-g", "GENERAL.CONNECTION", "device", "show", state["interface"]], check=False).stdout.strip()
        if current == PROFILE:
            command(["nmcli", "connection", "down", "id", PROFILE], root=True, check=False)
            if state.get("previous_connection"):
                command(["nmcli", "connection", "up", "uuid", state["previous_connection"]], root=True, check=False)
    STATE.unlink(missing_ok=True)
    print("Chess stopped.")
    return 0


def main(action="start", arguments=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lan", "--no-hotspot", action="store_true", help="Use the existing network without changing Wi-Fi.")
    parser.add_argument("--hotspot", action="store_true", help="Enable the fixed-address hotspot on Linux.")
    parser.add_argument("--ssid", default="DE0CV-Chess")
    parser.add_argument("--password", default="fpgachess")
    parser.add_argument("--interface")
    parser.add_argument("--autostart", action="store_true", help="Install the corrected service for startup after reboot.")
    parser.add_argument("--port", type=int, default=8080)
    options = parser.parse_args(arguments)
    try:
        if action == "stop":
            return stop()
        if action == "status":
            state = read_state()
            if not running(state):
                print("Chess is not running from this folder.")
                return 1
            print("Chess is running. " + " ".join(local_urls(state["port"])))
            return 0
        if not 1 <= options.port <= 65535:
            parser.error("port must be 1..65535")
        if options.autostart and not is_pi():
            raise RuntimeError("--autostart is supported on Raspberry Pi OS.")
        use_hotspot = not options.lan and (is_pi() or options.hotspot)
        if use_hotspot:
            if sys.platform != "linux":
                raise RuntimeError("Hotspot control is supported on Raspberry Pi OS. Use --lan here.")
            if not 1 <= len(options.ssid.encode("utf-8")) <= 32 or not 8 <= len(options.password) <= 63 or not options.password.isascii():
                parser.error("SSID must be 1..32 UTF-8 bytes and password 8..63 ASCII characters.")
            interface = select_wifi(options.interface)
            if not shutil.which("dnsmasq") and not Path("/usr/sbin/dnsmasq").exists():
                print("Installing dnsmasq-base, which supplies DHCP for the hotspot.", flush=True)
                command(["apt-get", "install", "-y", "dnsmasq-base"], root=True)
        if is_pi() and not Path("/dev/spidev0.0").exists() and shutil.which("raspi-config"):
            command(["raspi-config", "nonint", "do_spi", "0"], root=True)
            if not Path("/dev/spidev0.0").exists():
                print("SPI has been enabled. Reboot the Pi once if the FPGA remains disconnected.", flush=True)
        if is_pi():
            repair_service(options.autostart)
        state = start_server(options.port)
        print("Chess is running. Stop it with: python3 run.py stop", flush=True)
        if use_hotspot:
            enable_hotspot(state, interface, options.ssid, options.password)
        else:
            print("Open " + " or ".join(local_urls(state["port"])), flush=True)
        return 0
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"Chess startup: {error}", file=sys.stderr)
        if running(read_state()):
            print("The web server is still available on the existing network: " +
                  " ".join(local_urls(read_state()["port"])), file=sys.stderr)
        return 1
