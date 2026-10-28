"""Exercise relocated sources from a working directory outside the project."""
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from urllib.error import URLError
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]


class PortabilityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="de0cv relocation ")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.outside = Path(cls.temporary.name)
        cls.moved = cls.outside / "renamed chess project"
        shutil.copytree(ROOT, cls.moved,
                        ignore=shutil.ignore_patterns(".venv", ".cache", "__pycache__", "*.pyc"))

    def run_command(self, *arguments):
        result = subprocess.run([sys.executable, str(self.moved / "run.py"), *arguments],
                                cwd=self.outside, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_runtime_check_needs_only_the_copied_folder(self):
        self.assertIn("PASS:", self.run_command("check").stdout)
        self.assertFalse((self.outside / "rpi").exists())
        self.assertFalse((self.outside / "web").exists())
        self.assertFalse((self.outside / "de0cv_chess.qpf").exists())

    def test_all_fixture_commands_use_relocated_cache(self):
        self.run_command("fixtures", "--count", "2")
        self.run_command("search-fixtures")
        self.run_command("depth-fixtures")
        for name in ("rules.json", "chess_vectors.txt", "search_vectors.txt",
                     "depth_vectors.txt", "depth_live_vectors.txt"):
            self.assertTrue((self.moved / ".cache" / name).is_file(), name)
        self.assertFalse((self.outside / ".cache").exists())

    def test_web_assets_follow_relocated_module(self):
        code = ("import sys; sys.path.insert(0, sys.argv[1]); "
                "from web_app import create_app; client = create_app().test_client(); "
                "assert all(client.get('/' + name).status_code == 200 "
                "for name in ('', 'style.css', 'app.js', 'pieces.png'))")
        result = subprocess.run([sys.executable, "-c", code, str(self.moved)],
                                cwd=self.outside, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_http_server_runs_with_only_the_copied_folder(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        with tempfile.TemporaryFile(mode="w+", encoding="utf-8") as log:
            environment = {**os.environ, "PYTHONUNBUFFERED": "1"}
            environment.pop("PYTHONPATH", None)
            server = subprocess.Popen([sys.executable, str(self.moved / "run.py"), "web",
                                       "--host", "127.0.0.1", "--port", str(port)],
                                      cwd=self.outside, stdout=log, stderr=subprocess.STDOUT,
                                      env=environment)
            try:
                deadline = time.monotonic() + 15
                while True:
                    try:
                        with urlopen(f"http://127.0.0.1:{port}/", timeout=1) as response:
                            self.assertEqual(response.status, 200)
                        break
                    except URLError:
                        if server.poll() is not None or time.monotonic() >= deadline:
                            log.seek(0)
                            self.fail("Copied-folder server failed to start: " + log.read())
                        time.sleep(0.05)
                for name in ("index.html", "style.css", "chess.js", "fpga.js", "app.js", "pieces.png"):
                    route = "" if name == "index.html" else name
                    with urlopen(f"http://127.0.0.1:{port}/{route}", timeout=3) as response:
                        self.assertEqual(response.read(), (self.moved / "web" / name).read_bytes())
            finally:
                server.terminate()
                server.wait(timeout=10)

    def test_systemd_unit_uses_current_location_and_module_launcher(self):
        destination = self.outside / "chess.service"
        self.run_command("service-unit", "pi", "pi", str(destination))
        unit = destination.read_text(encoding="utf-8")
        escaped_root = str(self.moved.resolve()).replace("\\", "\\\\")
        self.assertNotIn("WorkingDirectory=", unit)
        self.assertIn(f'"{escaped_root}/run.py" serve', unit)
        self.assertIn("User=pi\nGroup=pi", unit)
        self.assertNotIn("@ROOT@", unit)

    @unittest.skipUnless(os.name == "posix", "Bash launcher is exercised on POSIX")
    def test_bash_launcher_finds_its_own_directory(self):
        result = subprocess.run(["bash", str(self.moved / "run.sh"), "check"],
                                cwd=self.outside, capture_output=True, text=True, timeout=30,
                                env={**os.environ, "PYTHON": sys.executable})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    @unittest.skipUnless(os.name == "nt", "PowerShell launcher is exercised on Windows")
    def test_powershell_launcher_finds_its_own_directory(self):
        result = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
                                 "-File", str(self.moved / "run.ps1"), "check"],
                                cwd=self.outside, capture_output=True, text=True, timeout=30,
                                env={**os.environ, "PYTHON": sys.executable})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
