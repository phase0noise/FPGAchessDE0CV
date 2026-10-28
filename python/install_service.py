"""Render a systemd unit using the current project location."""
import argparse
from pathlib import Path


def render(user, group):
    root = Path(__file__).resolve().parent
    text = (root / "de0cv-chess.service.in").read_text(encoding="utf-8")
    # systemd specifiers and quoted paths need escaping; no shell evaluates these.
    escaped_root = str(root).replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%").replace("$", "$$")
    return text.replace("@ROOT@", escaped_root).replace("@USER@", user).replace("@GROUP@", group)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("user")
    parser.add_argument("group")
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    args.destination.write_text(render(args.user, args.group), encoding="utf-8", newline="\n")
