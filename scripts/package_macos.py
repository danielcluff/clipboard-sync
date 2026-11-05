#!/usr/bin/env python3
"""Package a built app as a drag-to-Applications DMG (requires dmgbuild 1.6.7)."""

import argparse
from pathlib import Path
import subprocess
import tempfile

import dmgbuild


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="Path to the built Clipboard Sync.app")
    parser.add_argument("output", type=Path, help="Destination .dmg file")
    args = parser.parse_args()
    app = args.app.resolve()
    output = args.output.resolve()
    if not app.is_dir() or app.suffix != ".app":
        parser.error("app must be an existing .app bundle")
    if output.suffix != ".dmg":
        parser.error("output must have a .dmg extension")
    if output.exists():
        parser.error("output already exists; choose a new path")
    subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    dmgbuild.build_dmg(
        str(output),
        "Clipboard Sync",
        settings={
            "format": "UDZO",
            "filesystem": "HFS+",
            "files": [str(app)],
            "symlinks": {"Applications": "/Applications"},
            "icon": str(app / "Contents/Resources/AppIcon.icns"),
            "background": str(Path(__file__).resolve().parent.parent / "assets/dmg-background.png"),
            "window_rect": ((200, 200), (640, 280)),
            "default_view": "icon-view",
            "icon_size": 96,
            "text_size": 14,
            "icon_locations": {app.name: (140, 120), "Applications": (500, 120)},
            # Do not hide the .app extension with FinderInfo: that xattr breaks
            # strict verification of an otherwise valid signed app bundle.
            "show_toolbar": False,
            "show_sidebar": False,
            "show_status_bar": False,
            "show_pathbar": False,
        },
    )
    subprocess.run(["hdiutil", "verify", str(output)], check=True)
    with tempfile.TemporaryDirectory(prefix="clipboard-dmg-verify-") as mount:
        subprocess.run(
            ["hdiutil", "attach", str(output), "-readonly", "-nobrowse", "-mountpoint", mount],
            check=True,
        )
        try:
            packaged = Path(mount) / app.name
            subprocess.run(["codesign", "--verify", "--strict", str(packaged)], check=True)
            shortcut = Path(mount) / "Applications"
            if not shortcut.is_symlink() or shortcut.readlink() != Path("/Applications"):
                raise RuntimeError("Packaged Applications shortcut is missing or invalid")
        finally:
            subprocess.run(["hdiutil", "detach", mount], check=True)


if __name__ == "__main__":
    main()
