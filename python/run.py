#!/usr/bin/env python3
"""Run the DE0-CV Python tools from any working directory."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import runpy
import subprocess
import sys
import venv

PYTHON_ROOT = Path(__file__).resolve().parent
VENV_ROOT = PYTHON_ROOT / ".venv"
VENV_PYTHON = VENV_ROOT / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
SCRIPTS = {
    "web": "web_app.py",
    "spi": "spi_chess.py",
    "check": "check_runtime.py",
    "check-project": "check_project.py",
    "fixtures": "tests/generate_fixtures.py",
    "search-fixtures": "tests/generate_search.py",
    "depth-fixtures": "tests/generate_depth.py",
    "strength-fixtures": "tests/generate_strength.py",
    "check-cache": "tests/check_cache.py",
    "check-destinations": "tests/check_destinations.py",
    "check-parallel": "tests/check_parallel.py",
    "check-advancement": "tests/check_advancement.py",
    "check-strength": "tests/check_strength.py",
    "service-unit": "install_service.py",
}


def setup(arguments):
    parser = argparse.ArgumentParser(description="Create a fresh local Python environment.")
    parser.add_argument("--dev", action="store_true", help="Include verification dependencies.")
    parser.add_argument("--system-site-packages", action="store_true",
                        help="Include Raspberry Pi OS packages such as python3-spidev.")
    options = parser.parse_args(arguments)
    # Recreate with the system interpreter, including when setup was called in a venv.
    if sys.prefix != sys.base_prefix:
        if os.name == "nt" and Path(sys.prefix).resolve() == VENV_ROOT.resolve():
            parser.error("Deactivate this environment, then run setup with py or run.ps1.")
        base_python = getattr(sys, "_base_executable", None)
        if not base_python or os.path.abspath(base_python) == os.path.abspath(sys.executable):
            parser.error("Run setup using your system Python outside the active virtual environment.")
        return subprocess.call([base_python, str(Path(__file__).resolve()), "setup", *arguments])
    venv.EnvBuilder(with_pip=True, clear=True,
                    system_site_packages=options.system_site_packages).create(VENV_ROOT)
    requirements = PYTHON_ROOT / ("requirements-dev.txt" if options.dev else "requirements.txt")
    subprocess.run([str(VENV_PYTHON), "-m", "pip", "install", "--disable-pip-version-check",
                    "-r", str(requirements)], check=True)
    print("Python environment ready. Run this launcher with web, spi, test, or check.")
    return 0


def main(arguments=None):
    if sys.version_info < (3, 10):
        raise SystemExit("Python 3.10 or newer is required.")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", nargs="?", choices=["setup", "test", "serve", *SCRIPTS])
    parser.add_argument("arguments", nargs=argparse.REMAINDER,
                        help="Options forwarded to the selected command.")
    options = parser.parse_args(arguments)
    if options.command is None:
        parser.print_help()
        return 0
    if options.command == "setup":
        return setup(options.arguments)
    # Use modules, never venv console-script shebangs that retain the old folder path.
    if VENV_PYTHON.is_file() and Path(sys.prefix).resolve() != VENV_ROOT.resolve():
        return subprocess.call([str(VENV_PYTHON), str(Path(__file__).resolve()),
                                options.command, *options.arguments])
    os.chdir(PYTHON_ROOT)
    if options.command == "test":
        return subprocess.call([sys.executable, "-m", "unittest", "discover",
                                "-s", str(PYTHON_ROOT / "tests"), "-p", "test_*.py",
                                "-v", *options.arguments])
    if options.command == "serve":
        return subprocess.call([sys.executable, "-m", "gunicorn", "--chdir", str(PYTHON_ROOT),
                                "--workers", "1", "--threads", "4", "--timeout", "30",
                                "--bind", "0.0.0.0:8080", "--access-logfile", "-",
                                *options.arguments, "web_app:app"])
    script = PYTHON_ROOT / SCRIPTS[options.command]
    sys.path.insert(0, str(script.parent))
    sys.argv = [str(script), *options.arguments]
    try:
        runpy.run_path(str(script), run_name="__main__")
    except ModuleNotFoundError as error:
        raise SystemExit(f"Missing Python dependency: {error.name}. Run this launcher with setup --dev.") from error
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
