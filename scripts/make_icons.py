"""Install Compii's app icon into every platform's slots.

Render the sizes first (they are drawn, not scaled, so small ones stay sharp):

    cd compii_flutter/apps/companion
    flutter test test/app_icon_test.dart --dart-define=ICONS=true

then run this from the repository root:  python scripts/make_icons.py
"""

from pathlib import Path

from PIL import Image

APP = Path(__file__).resolve().parent.parent / "compii_flutter" / "apps" / "companion"
SRC = APP / "build" / "icon"


def icon(size: int, mac: bool = False) -> Image.Image:
    path = SRC / f"{'mac' if mac else 'icon'}_{size}.png"
    if not path.exists():
        raise SystemExit(f"Missing {path.name}: render the icons first (see this file's docstring).")
    return Image.open(path).convert("RGBA")


def main() -> None:
    # Windows: one .ico with every size the shell asks for, each drawn at that size.
    ico_sizes = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256]
    frames = [icon(s) for s in ico_sizes]
    frames[-1].save(APP / "windows" / "runner" / "resources" / "app_icon.ico",
                    format="ICO", sizes=[(s, s) for s in ico_sizes], append_images=frames[:-1])

    # macOS: the dock's margin is part of the picture.
    mac = APP / "macos" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    for s in (16, 32, 64, 128, 256, 512, 1024):
        icon(s, mac=True).save(mac / f"app_icon_{s}.png")

    # Android launcher densities.
    res = APP / "android" / "app" / "src" / "main" / "res"
    for folder, s in {"mipmap-mdpi": 48, "mipmap-hdpi": 72, "mipmap-xhdpi": 96,
                      "mipmap-xxhdpi": 144, "mipmap-xxxhdpi": 192}.items():
        icon(s).save(res / folder / "ic_launcher.png")

    print("Installed Compii's icon for Windows, macOS and Android.")


if __name__ == "__main__":
    main()
