"""Advanced status compatibility through the Pi diagnostic and health endpoint."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from spi_chess import SpiCommunicationError, engine_status
from web_app import create_app


def frame():
    data = bytearray(40)
    data[:4] = b'SCF2'
    data[5] = 1
    data[8:10] = (218).to_bytes(2, 'big')
    data[15] = 5
    data[28:30] = bytes([8, 5])
    data[36:40] = (50_000_000).to_bytes(4, 'big')
    return data


class Link:
    def __init__(self, data):
        self.data = data

    def command(self, _payload):
        return 0, self.data

    def close(self):
        pass


class EngineStatusTests(unittest.TestCase):
    def test_advanced_status_preserves_clock_depth_and_legal_count(self):
        status = engine_status(frame())
        self.assertEqual(status, dict(busy=False, done=True, engine_version=5,
                                     clock_hz=50_000_000, legal_count=218,
                                     requested_depth=8, completed_depth=5))

    def test_incompatible_or_truncated_images_are_unhealthy(self):
        legacy = bytearray(32)
        legacy[:4] = b'SCF1'
        legacy[15] = 3
        wrong_version = frame()
        wrong_version[15] = 6
        wrong_clock = frame()
        wrong_clock[36:40] = bytes(4)
        for data in (legacy, frame()[:-1], frame() + b'\0', wrong_version, wrong_clock):
            with self.subTest(data=data):
                with self.assertRaises(SpiCommunicationError):
                    engine_status(data)
                app = create_app(lambda: Link(data))
                try:
                    response = app.test_client().get('/healthz')
                    self.assertEqual(response.status_code, 503)
                    self.assertFalse(response.json['fpga'])
                finally:
                    app.extensions['chess_hardware'].close()

    def test_health_returns_current_device_capabilities(self):
        app = create_app(lambda: Link(frame()))
        try:
            response = app.test_client().get('/healthz')
            self.assertEqual(response.status_code, 200)
            self.assertTrue(response.json['fpga'])
            self.assertEqual(response.json['clock_hz'], 50_000_000)
            self.assertEqual(response.json['engine_version'], 5)
        finally:
            app.extensions['chess_hardware'].close()


if __name__ == '__main__':
    unittest.main()
