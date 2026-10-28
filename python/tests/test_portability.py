"""Exercise relocated sources from a working directory outside the project."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class PortabilityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="de0cv relocation ")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.outside = Path(cls.temporary.name)
        cls.moved = cls.outside / "renamed chess project"
        cls.moved.mkdir()
        for name in ("python", "rpi", "rtl", "web"):
            shutil.copytree(ROOT / name, cls.moved / name,
                            ignore=shutil.ignore_patterns(".venv", "__pycache__", "*.pyc"))
        for name in ("README.md", "de0cv_chess.qpf", "de0cv_chess.qsf", "de0cv_chess.sdc"):
            shutil.copy2(ROOT / name, cls.moved / name)

    def run_command(self, *arguments):
        result = subprocess.run([sys.executable, str(self.moved / "python/run.py"), *arguments],
                                cwd=self.outside, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_project_check_uses_relocated_sources(self):
        self.assertIn("PASS:", self.run_command("check").stdout)

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
        result = subprocess.run([sys.executable, "-c", code, str(self.moved / "python")],
                                cwd=self.outside, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_systemd_unit_uses_current_location_and_module_launcher(self):
        destination = self.outside / "chess.service"
        self.run_command("service-unit", "pi", "pi", str(destination))
        unit = destination.read_text(encoding="utf-8")
        escaped_root = str(self.moved.resolve()).replace("\\", "\\\\")
        self.assertIn(f'WorkingDirectory="{escaped_root}/python"', unit)
        self.assertIn(f'"{escaped_root}/python/run.py" serve', unit)
        self.assertIn("User=pi\nGroup=pi", unit)
        self.assertNotIn("@ROOT@", unit)

    @unittest.skipUnless(os.name == "posix", "Bash launcher is exercised on POSIX")
    def test_bash_launcher_finds_its_own_directory(self):
        result = subprocess.run(["bash", str(self.moved / "python/run.sh"), "check"],
                                cwd=self.outside, capture_output=True, text=True, timeout=30,
                                env={**os.environ, "PYTHON": sys.executable})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    @unittest.skipUnless(os.name == "nt", "PowerShell launcher is exercised on Windows")
    def test_powershell_launcher_finds_its_own_directory(self):
        result = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
                                 "-File", str(self.moved / "python/run.ps1"), "check"],
                                cwd=self.outside, capture_output=True, text=True, timeout=30,
                                env={**os.environ, "PYTHON": sys.executable})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
