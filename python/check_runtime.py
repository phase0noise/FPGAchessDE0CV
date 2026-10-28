"""Check the standalone chess folder without using files from its parent."""
from pathlib import Path
import argparse
import re


def check(root):
    root = Path(root).resolve()
    required = (
        "run.py", "run.sh", "run.ps1", "spi_chess.py", "web_app.py",
        "requirements.txt", "requirements-dev.txt", "setup.sh",
        "de0cv-chess.service.in", "install_service.py", "README.md", "pi_start.py",
        "linux_spi.py", "vendor/flask/__init__.py", "vendor/waitress/__init__.py",
        "web/index.html", "web/style.css", "web/chess.js", "web/fpga.js",
        "web/app.js", "web/pieces.png",
    )
    for name in required:
        path = (root / name).resolve()
        assert path.is_relative_to(root) and path.is_file(), f"Missing local runtime file: {name}"
    html = (root / "web/index.html").read_text(encoding="utf-8")
    assert not re.search(r'(?:src|href)=["\']https?://', html), "Page has external runtime assets"
    print("PASS: standalone Python folder contains all runtime, web and Pi installer files.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", nargs="?", type=Path, default=Path(__file__).resolve().parent)
    check(parser.parse_args().root)
