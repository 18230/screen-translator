#!/usr/bin/env python3
"""Replace only this app bundle using fresh files, retaining user configuration."""
from pathlib import Path
import argparse
import os
import plistlib
import shutil
import signal
import subprocess
import time

PROJECT = Path(__file__).resolve().parent.parent
IDENTIFIER = "local.gaoqi.screen-translator"
REGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


def bundle_id(path):
    with (path / "Contents/Info.plist").open("rb") as stream:
        return plistlib.load(stream).get("CFBundleIdentifier")


def run(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--reset-screen-permission", action="store_true",
                        help="Clear only this app's obsolete screen-capture permission; user must authorize again.")
    options = parser.parse_args()
    source = PROJECT / ".build/package/截屏翻译.app"
    target = Path.home() / "Applications/截屏翻译.app"
    obsolete = PROJECT / "dist/截屏翻译.app"
    if bundle_id(source) != IDENTIFIER:
        raise RuntimeError("Unexpected build identity")
    run(["codesign", "--verify", "--strict", str(source)])
    for path in [target, obsolete]:
        if path.exists() and (path.is_symlink() or bundle_id(path) != IDENTIFIER):
            raise RuntimeError("Refusing to remove an unrelated app: " + str(path))
    result = run(["ps", "-axo", "pid=,comm="], capture_output=True, text=True)
    pids = []
    for line in result.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and any(parts[1] == str(path / "Contents/MacOS/ScreenTranslator") for path in [target, obsolete]):
            pid = int(parts[0]); os.kill(pid, signal.SIGTERM); pids.append(pid)
    for _ in range(30):
        alive = []
        for pid in pids:
            try:
                os.kill(pid, 0); alive.append(pid)
            except ProcessLookupError:
                pass
        if not alive:
            break
        time.sleep(0.1)
    else:
        raise RuntimeError("Previous app has not exited; replacement cancelled")
    # Remove the registered old bundles completely; never overwrite a running inode.
    for path in [target, obsolete]:
        if path.exists():
            subprocess.run([REGISTER, "-u", str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            shutil.rmtree(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    run(["ditto", str(source), str(target)])
    run(["codesign", "--verify", "--strict", str(target)])
    run([REGISTER, "-f", str(target)], stdout=subprocess.DEVNULL)
    if options.reset_screen_permission:
        # tccutil resolves the bundle identifier via LaunchServices, so register
        # the fresh app before clearing its old permission entry.
        run(["tccutil", "reset", "ScreenCapture", IDENTIFIER])
    archive = PROJECT / "dist/截屏翻译.zip"
    archive.parent.mkdir(parents=True, exist_ok=True)
    run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(target), str(archive)])
    shutil.rmtree(source)
    print("Fresh app installed:", target)
    print("Archive:", archive)
    print("Preferences and Keychain credentials retained; no second runnable build left in dist.")


if __name__ == "__main__":
    main()
