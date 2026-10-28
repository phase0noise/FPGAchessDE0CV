#!/usr/bin/env python3
"""DE0-CV chess mailbox over spirpi's mode-0 register protocol.

This module transports commands only. Move generation and selection run in VHDL.
"""
from __future__ import annotations

import argparse
import binascii
import json
import os
import secrets
import struct
import tempfile
import time
from threading import RLock

IDENTITY = bytes([0xC5, 3, 7])
APP_MAGIC = b"CHS3"
ENGINE_PROTOCOL = 5
MAX_SPEED_HZ = 5_000_000
DEFAULT_SPEED_HZ = 1_000_000

class SpiCommunicationError(RuntimeError):
    pass

def crc16(data: bytes) -> int:
    return binascii.crc_hqx(data, 0xFFFF)

def engine_status(raw: bytes) -> dict:
    """Validate the advanced engine before reporting the hardware as healthy."""
    if len(raw) != 40 or raw[:4] != b"SCF2" or raw[15] != ENGINE_PROTOCOL:
        raise SpiCommunicationError(
            "FPGA engine status is incompatible. Load the advanced de0cv_chess.sof."
        )
    frequency = int.from_bytes(raw[36:40], "big")
    if not 1_000_000 <= frequency <= 250_000_000:
        raise SpiCommunicationError("FPGA reported an invalid clock frequency")
    return dict(busy=bool(raw[4]), done=bool(raw[5]), engine_version=raw[15],
                clock_hz=frequency, legal_count=int.from_bytes(raw[8:10], "big"),
                requested_depth=raw[28], completed_depth=raw[29])


class SpiDevice:
    """One process owns SPI0/CE0; every frame uses xfer2 to hold chip select."""
    def __init__(self, bus=0, device=0, speed_hz=DEFAULT_SPEED_HZ):
        if not 0 <= bus <= 255 or not 0 <= device <= 255:
            raise ValueError("SPI bus/device must be 0..255")
        if not 10_000 <= speed_hz <= MAX_SPEED_HZ:
            raise ValueError(f"SPI speed must be 10000..{MAX_SPEED_HZ} Hz")
        self.spi = None
        self.lock_file = None
        try:
            import fcntl
            try:
                import spidev
                SpiDev = spidev.SpiDev
            except ImportError:
                from linux_spi import SpiDev
            name = os.path.join(tempfile.gettempdir(), f"de0cv-chess-spi{bus}.{device}.lock")
            self.lock_file = open(name, "a+")
            try:
                fcntl.flock(self.lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise SpiCommunicationError("Another chess process owns this SPI device") from error
            self.spi = SpiDev()
            self.spi.open(bus, device)
            self.spi.mode = 0
            self.spi.bits_per_word = 8
            self.spi.max_speed_hz = speed_hz
        except (ImportError, OSError, SpiCommunicationError) as error:
            self.close()
            if isinstance(error, SpiCommunicationError):
                raise
            raise SpiCommunicationError(
                f"Cannot open SPI{bus}/CE{device}: {error}. Enable SPI and check device permissions."
            ) from error

    def close(self):
        spi, self.spi = self.spi, None
        try:
            if spi is not None:
                spi.close()
        finally:
            if self.lock_file is not None:
                self.lock_file.close()
                self.lock_file = None

    def _transfer(self, frame):
        try:
            result = self.spi.xfer2(frame)
        except OSError as error:
            raise SpiCommunicationError(f"SPI transfer failed: {error}") from error
        if len(result) != len(frame):
            raise SpiCommunicationError("SPI returned an incomplete frame")
        return bytes(result)

    @staticmethod
    def _range(address, length):
        if not 0 <= address < 256 or not 0 <= length <= 256-address:
            raise ValueError("SPI transfer crosses the 256-register boundary")

    def read(self, address, length=1):
        self._range(address, length)
        return self._transfer([0x80, address, *([0]*length)])[2:] if length else b""

    def write(self, address, data):
        data = bytes(data)
        self._range(address, len(data))
        if data:
            self._transfer([0x00, address, *data])

class ChessSPI:
    def __init__(self, device, sequence=None, timeout=1.0):
        self.device = device
        self.sequence = secrets.randbits(32) if sequence is None else sequence & 0xFFFFFFFF
        self.timeout = timeout
        self.lock = RLock()

    def close(self):
        self.device.close()

    def identity(self):
        raw = self.device.read(0, 8)
        if len(raw) != 8 or raw[:3] != IDENTITY or raw[4:] != APP_MAGIC:
            raise SpiCommunicationError(
                f"Wrong FPGA identity ({raw.hex()}). Load de0cv_chess.sof and check SPI wiring."
            )
        return dict(board="DE0-CV", bridge="Raspberry Pi SPI", interface=raw[1], signature=raw[0])

    def _wait(self, deadline, ready=False):
        while time.monotonic() < deadline:
            flags = self.device.read(3, 1)
            if len(flags) != 1:
                raise SpiCommunicationError("Missing mailbox flags")
            if not flags[0] & 1 and (not ready or flags[0] & 2):
                return
            time.sleep(0.001)
        raise SpiCommunicationError("FPGA command mailbox timed out")

    def _reply(self, sequence):
        raw = self.device.read(8, 7)
        if len(raw) != 7:
            raise SpiCommunicationError("Incomplete FPGA reply header")
        token, status, length = struct.unpack("!IBH", raw)
        if token != sequence:
            raise SpiCommunicationError("FPGA reply sequence changed")
        if length > 1024:
            raise SpiCommunicationError("FPGA reply exceeds 1024 bytes")
        data = bytearray()
        for page in range((length+127)//128):
            self.device.write(0x18, bytes([page]))
            part = self.device.read(0x80, min(128, length-len(data)))
            data.extend(part)
        checksum = self.device.read(0x1A, 2)
        if len(data) != length or len(checksum) != 2 or crc16(b"\x01"+raw+data) != int.from_bytes(checksum, "big"):
            raise SpiCommunicationError("FPGA reply CRC mismatch; check SPI signal quality")
        return status, bytes(data)

    def command(self, payload):
        payload = bytes(payload)
        if not 1 <= len(payload) <= 81:
            raise ValueError("A chess command contains 1..81 bytes")
        with self.lock:
            self.identity()
            self.sequence = (self.sequence+1) & 0xFFFFFFFF
            sequence = self.sequence
            prefix = struct.pack("!IB", sequence, len(payload))
            checksum = crc16(b"\x01"+prefix+payload)
            last_error = None
            for _ in range(3):
                try:
                    deadline = time.monotonic()+self.timeout
                    self._wait(deadline)
                    # Length resets the FPGA's received-byte bitmap. The data
                    # follows in its own frame; execute is a third clean frame.
                    self.device.write(0x10, prefix+struct.pack("!H", checksum))
                    self.device.write(0x20, payload)
                    self.device.write(0x0F, b"\xA5")
                    self._wait(deadline, ready=True)
                    status, data = self._reply(sequence)
                    if status == 5:
                        raise SpiCommunicationError("FPGA rejected incomplete or corrupt command bytes")
                    if status == 6:
                        raise SpiCommunicationError("FPGA detected a reused sequence with different data")
                    self.device.write(0x0F, b"\x5A")
                    return status, data
                except SpiCommunicationError as error:
                    last_error = error
                    # The same sequence and CRC preserve idempotence when a
                    # transfer/reply was lost after a mutation already ran.
            raise last_error

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bus", type=int, default=0)
    parser.add_argument("--device", type=int, default=0)
    parser.add_argument("--speed", type=int, default=DEFAULT_SPEED_HZ)
    parser.add_argument("action", choices=["info", "status"], default="status", nargs="?")
    args = parser.parse_args()
    link = None
    try:
        link = ChessSPI(SpiDevice(args.bus, args.device, args.speed))
        identity = link.identity()
        status, raw = link.command(b"\x00")
        if status:
            raise SpiCommunicationError(f"FPGA status command failed (status {status})")
        print(json.dumps({**identity, "speed_hz": args.speed, **engine_status(raw)}, indent=2))
    except (SpiCommunicationError, ValueError) as error:
        parser.exit(1, f"{error}\n")
    finally:
        if link is not None:
            link.close()

if __name__ == "__main__":
    main()
