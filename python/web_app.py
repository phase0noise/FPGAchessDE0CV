#!/usr/bin/env python3
"""Serve the chess page and serialize hardware commands through Raspberry Pi SPI."""
from __future__ import annotations

import argparse
import atexit
import os
import sys
from pathlib import Path
from threading import RLock

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parent / "vendor"))
from flask import Flask, jsonify, request, send_from_directory
from werkzeug.exceptions import RequestEntityTooLarge
from spi_chess import ChessSPI, SpiCommunicationError, SpiDevice, DEFAULT_SPEED_HZ, engine_status

class HardwareManager:
    def __init__(self, factory):
        self.factory = factory
        self.link = None
        self.lock = RLock()

    def command(self, payload):
        with self.lock:
            try:
                if self.link is None:
                    self.link = self.factory()
                return self.link.command(payload)
            except (SpiCommunicationError, OSError):
                self.close()
                raise

    def close(self):
        with self.lock:
            if self.link is not None:
                try:
                    self.link.close()
                finally:
                    self.link = None

def create_app(factory=None):
    web_root = Path(__file__).resolve().parent/"web"
    app = Flask(__name__, static_folder=None)
    app.config["MAX_CONTENT_LENGTH"] = 162
    if factory is None:
        bus = int(os.environ.get("CHESS_SPI_BUS", "0"))
        device = int(os.environ.get("CHESS_SPI_DEVICE", "0"))
        speed = int(os.environ.get("CHESS_SPI_SPEED", str(DEFAULT_SPEED_HZ)))
        factory = lambda: ChessSPI(SpiDevice(bus, device, speed))
    manager = HardwareManager(factory)
    app.extensions["chess_hardware"] = manager
    atexit.register(manager.close)

    @app.after_request
    def headers(response):
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        return response

    @app.get("/")
    def index():
        return send_from_directory(web_root, "index.html")

    @app.get("/<name>")
    def asset(name):
        if name not in {"chess.js", "fpga.js", "app.js", "style.css", "pieces.png"}:
            return jsonify(error="Unknown path"), 404
        return send_from_directory(web_root, name)

    @app.post("/api/command")
    def command():
        raw = request.get_data(cache=False)
        if not 2 <= len(raw) <= 162 or len(raw)%2:
            return jsonify(error="Expected 1..81 command bytes encoded as hexadecimal"), 400
        try:
            text = raw.decode("ascii")
            if any(c not in "0123456789abcdefABCDEF" for c in text):
                raise ValueError()
            payload = bytes.fromhex(text)
        except (UnicodeDecodeError, ValueError):
            return jsonify(error="Invalid hexadecimal body"), 400
        try:
            status, data = manager.command(payload)
            return jsonify(status=status, payload=data.hex())
        except (SpiCommunicationError, OSError) as error:
            return jsonify(error=str(error)), 503

    @app.get("/api/info")
    def info():
        return jsonify(device="Raspberry Pi", board="DE0-CV", transport="SPI0/CE0",
                       speed_hz=int(os.environ.get("CHESS_SPI_SPEED", str(DEFAULT_SPEED_HZ))))

    @app.get("/readyz")
    def ready():
        return jsonify(app="de0cv-chess", ready=True, pid=os.getpid(),
                       instance=os.environ.get("CHESS_INSTANCE_ID", ""))

    @app.get("/healthz")
    def health():
        try:
            status, data = manager.command(b"\x00")
            if status:
                return jsonify(fpga=False, error=f"FPGA status command failed (status {status})"), 503
            return jsonify(fpga=True, **engine_status(data))
        except (SpiCommunicationError, OSError) as error:
            return jsonify(fpga=False, error=str(error)), 503

    @app.errorhandler(RequestEntityTooLarge)
    def too_large(_error):
        return jsonify(error="Command body exceeds 162 bytes"), 413

    return app

app = create_app()

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()
    from waitress import create_server
    import uuid
    from pi_start import read_state, write_state, STATE
    instance = os.environ.setdefault("CHESS_INSTANCE_ID", uuid.uuid4().hex)
    server = create_server(app, host=args.host, port=args.port, threads=4, channel_timeout=10)
    state = read_state()
    state.update(port=args.port, pid=os.getpid(), instance=instance)
    write_state(state)
    print(f"Chess server listening on port {args.port}.", flush=True)
    try:
        server.run()
    finally:
        server.close()
        if read_state().get("instance") == instance:
            STATE.unlink(missing_ok=True)
