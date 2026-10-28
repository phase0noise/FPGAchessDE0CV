"""Small spidev adapter using Linux's stable SPI ioctl interface.

The transfer structure has the same 32-byte layout on ARM32 and ARM64.
No compiled Python extension is needed.
"""
import ctypes
import os
import struct


class SpiDev:
    def __init__(self):
        self.fd = None
        self._mode = 0
        self._bits = 8
        self._speed = 1_000_000

    def open(self, bus, device):
        self.fd = os.open(f"/dev/spidev{bus}.{device}", os.O_RDWR)

    def close(self):
        if self.fd is not None:
            fd, self.fd = self.fd, None
            os.close(fd)

    def _setting(self, number, value, size):
        import fcntl
        fcntl.ioctl(self.fd, 0x40000000 | (size << 16) | (ord("k") << 8) | number,
                    struct.pack("=B" if size == 1 else "=I", value))

    @property
    def mode(self):
        return self._mode

    @mode.setter
    def mode(self, value):
        self._setting(1, value, 1)
        self._mode = value

    @property
    def bits_per_word(self):
        return self._bits

    @bits_per_word.setter
    def bits_per_word(self, value):
        self._setting(3, value, 1)
        self._bits = value

    @property
    def max_speed_hz(self):
        return self._speed

    @max_speed_hz.setter
    def max_speed_hz(self, value):
        self._setting(4, value, 4)
        self._speed = value

    def xfer2(self, frame):
        import fcntl
        tx = (ctypes.c_ubyte * len(frame))(*frame)
        rx = (ctypes.c_ubyte * len(frame))()
        transfer = struct.pack("=QQIIHBBBBBB", ctypes.addressof(tx), ctypes.addressof(rx),
                               len(frame), self._speed, 0, self._bits, 0, 0, 0, 0, 0)
        fcntl.ioctl(self.fd, 0x40206B00, transfer)
        return list(rx)
