"""Build a self-contained Compii folder for Windows: the app plus Compii Core with its own Python.

    python packaging/build_windows.py [--app <flutter Release folder>] [--out dist/Compii]

Result (dist/Compii):
    compii.exe, data/, *.dll        the Flutter app (also the overlay with --overlay)
    core/python/pythonw.exe         a private, relocatable Python (python-build-standalone via uv)
    core/python/Lib/site-packages   Compii Core and its packages
The app starts Core from core/python when it finds it next to compii.exe, so nothing needs
installing. Voice models are downloaded by the app on first use into ~/Compii/models.
Packages are copied from compii_core/.venv (the environment Compii already runs with): this
script downloads nothing.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "compii_core"
DEFAULT_APP = ROOT / ".build-check" / "compii_flutter" / "apps" / "companion" / "build" / "windows" / "x64" / "runner" / "Release"
# Parts of the standard library a background service never needs.
SKIP_STDLIB = {"test", "idlelib", "tkinter", "turtledemo", "ensurepip", "lib2to3", "__pycache__"}
SKIP_TOP = {"include", "libs", "tcl", "Doc"}


def run(*cmd: str | Path, **kw) -> str:
    print("  $", " ".join(str(c) for c in cmd))
    return subprocess.run([str(c) for c in cmd], check=True, capture_output=True, text=True, **kw).stdout


def find_python() -> Path:
    """The uv-managed CPython that Compii Core's .venv was built with (same version, same wheels)."""
    cfg = (CORE / ".venv" / "pyvenv.cfg").read_text(encoding="utf-8")
    home = next(line.split("=", 1)[1].strip() for line in cfg.splitlines() if line.startswith("home"))
    return Path(home)


def copy_python(src: Path, dst: Path) -> None:
    def ignore(folder: str, names: list[str]) -> set[str]:
        here = Path(folder)
        skip = {n for n in names if n in SKIP_STDLIB or n == "site-packages"}
        if here == src:
            skip |= {n for n in names if n in SKIP_TOP}
        return skip

    shutil.copytree(src, dst, ignore=ignore)
    (dst / "Lib" / "site-packages").mkdir(parents=True, exist_ok=True)
    marker = dst / "Lib" / "EXTERNALLY-MANAGED"
    if marker.exists():
        marker.unlink()  # this copy belongs to Compii: packages may be installed into it


# Developer-only packages and the editable link back to the source folder stay out.
SKIP_PACKAGES = ("pytest", "_pytest", "pluggy", "iniconfig", "compii_core", "_compii_core", "__editable__", "py.py",
                 "_virtualenv")


def copy_packages(src: Path, dst: Path) -> None:
    for item in src.iterdir():
        name = item.name.lower()
        if name.startswith(SKIP_PACKAGES) or name.endswith(".pth") and "compii" in name or name == "__pycache__":
            continue
        target = dst / item.name
        if item.is_dir():
            shutil.copytree(item, target, ignore=shutil.ignore_patterns("__pycache__"))
        else:
            shutil.copy2(item, target)


def size(path: Path) -> str:
    total = sum(f.stat().st_size for f in path.rglob("*") if f.is_file())
    return f"{total / 1_048_576:.0f} MB"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", type=Path, default=DEFAULT_APP, help="flutter build windows --release output")
    ap.add_argument("--out", type=Path, default=ROOT / "dist" / "Compii")
    args = ap.parse_args()
    if not (args.app / "compii.exe").exists():
        sys.exit(f"No compii.exe in {args.app}. Build the app first (flutter build windows --release).")
    start = time.time()
    out: Path = args.out
    if out.exists():
        shutil.rmtree(out)
    print(f"1/4 App from {args.app}")
    shutil.copytree(args.app, out)
    py_src = find_python()
    print(f"2/4 Python from {py_src}")
    py = out / "core" / "python"
    copy_python(py_src, py)
    print("3/4 Compii Core and its packages (copied from the working .venv: nothing is downloaded)")
    copy_packages(CORE / ".venv" / "Lib" / "site-packages", py / "Lib" / "site-packages")
    shutil.copytree(CORE / "compii_core", py / "Lib" / "site-packages" / "compii_core",
                    ignore=shutil.ignore_patterns("__pycache__"))
    run(py / "python.exe", "-m", "compileall", "-q", "-j", "0", py / "Lib" / "site-packages" / "compii_core")
    print("4/4 Check that Core starts from the bundle")
    version = run(py / "python.exe", "-c", "import compii_core, fastapi, faster_whisper, kokoro_onnx, uiautomation;"
                  "print(compii_core.__version__)").strip()
    (out / "core" / "VERSION").write_text(version, encoding="utf-8")
    print(f"\nDone in {time.time() - start:.0f} s: {out} ({size(out)}), Compii Core {version}")


if __name__ == "__main__":
    main()
