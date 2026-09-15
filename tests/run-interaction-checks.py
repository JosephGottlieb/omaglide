#!/usr/bin/env python3
"""Read-only production code; real input only into a verified disposable compositor.

Start tests/run-nested-hyprland, apply its setup-nested-output,
copy InteractionHarness.qml as shell.qml beside copies of Carousel.qml and
logic.js in that private directory, and start the fixture plus input keepers.
This runner never connects to the user's compositor and never saves settings.
"""
import argparse
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("runtime")
args = parser.parse_args()
source = Path(__file__).resolve().parents[1]
infrastructure = source / "tests"
guard_loader = importlib.machinery.SourceFileLoader("omaglide_compositor_guard", str(infrastructure / "setup-nested-output"))
guard_spec = importlib.util.spec_from_loader(guard_loader.name, guard_loader)
guard = importlib.util.module_from_spec(guard_spec)
guard_loader.exec_module(guard)
compositor = guard.NestedCompositor(args.runtime)
runtime = compositor.runtime
fixture = runtime.parent / "shell.qml"
if not fixture.is_file() or fixture.is_symlink():
    raise RuntimeError("Fixture must be a regular file in the verified private runtime parent")
environment = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), OMADESKTOP_TEST_RUNTIME=str(runtime),
                   WAYLAND_DISPLAY="wayland-1", HYPRLAND_INSTANCE_SIGNATURE=compositor.instance.name)
environment.pop("WAYLAND_SOCKET", None)
helpers = source / ".test-build"
pointer = helpers / "pointer-build/virtual-pointer"
keyboard = helpers / "keyboard-build/virtual-keyboard"

def run(command, timeout=5):
    compositor.verify_peer()
    result = subprocess.run(command, env=environment, text=True, capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(result.stderr or result.stdout)
    return result.stdout.strip()

def ipc(target, method, *values):
    return run(["quickshell", "ipc", "-p", str(fixture), "call", "--", target, method, *values])

def status():
    result = json.loads(ipc("fixture", "status"))
    if result.get("synthetic") is not True:
        raise RuntimeError("IPC response is not our synthetic fixture")
    return result

def wait(predicate, timeout=3):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = status()
        if predicate(result):
            return result
        time.sleep(.04)
    raise AssertionError(f"Fixture condition timed out: {result}")

def check(condition, label, evidence=None):
    print(json.dumps({"check": label, "passed": bool(condition), "evidence": evidence}), flush=True)
    if not condition:
        raise AssertionError(label)

def key(code):
    run([str(keyboard), f"key:{code}"])

try:
    check(status()["synthetic"], "isolated fixture is responsive")
    ipc("omaglide", "resize", "reset")
    ipc("omaglide", "show")
    initial = wait(lambda s: s["open"] and s["count"] == 3)
    check(initial["preferredWidth"] == 560, "three synthetic windows open at default width", initial)
    time.sleep(.35) # Layer mapping and keyboard-enter follow the open state.
    key(13) # '='
    larger = wait(lambda s: s["preferredWidth"] == 608)
    check(larger["open"], "real keyboard resize grows by48px and stays open", larger)
    key(12) # '-'
    wait(lambda s: s["preferredWidth"] == 560)
    metrics = json.loads(ipc("omaglide", "status"))["preview"]
    width = metrics["tileWidth"]
    x = round(metrics["width"] / 2 + width / 2 - 22)
    y = round(metrics["height"] / 2 + (width * .625 + 54) / 2 - 22)
    command = [str(pointer), "--width", "1440", "--height", "900",
               f"move:{x}:{y}", "pause:100", "down", "pause:100",
               f"move:{x+100}:{y}", "pause:800",
               f"move:{x+200}:{y}", "pause:800",
               f"move:{x+250}:{y}", "pause:800", "up", "pause:100"]
    compositor.verify_peer()
    drag = subprocess.Popen(command, env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        first = wait(lambda s: s["resizing"] and s["preferredWidth"] >= 758)
        check(first["open"], "held pointer first movement grows tile to760px", first)
        second = wait(lambda s: s["resizing"] and s["preferredWidth"] >= 958)
        check(second["open"], "pointer grab survives geometry change and grows tile to960px", second)
        third = wait(lambda s: s["resizing"] and s["preferredWidth"] >= 1058)
        check(third["open"], "same held pointer continues to1060px without restarting drag", third)
    finally:
        output, error = drag.communicate(timeout=5)
        if drag.returncode:
            raise RuntimeError(error or output)
    released = wait(lambda s: not s["resizing"] and s["saved"].get("tileWidth") == 1060)
    check(released["open"], "mouse release ends resize and persists only into fixture memory", released)
    rendered = json.loads(ipc("omaglide", "status"))["preview"]
    check(rendered["tileWidth"] == 1060, "rendered geometry matches enlarged preference", rendered)
    key(1)
    canceled = wait(lambda s: not s["open"])
    before_keys = canceled["appKeys"]
    key(30)
    delivered = wait(lambda s: s["appKeys"] > before_keys)
    check(delivered["appKeys"] > before_keys, "Escape releases keyboard grab back to normal fixture window", delivered)
    ipc("omaglide", "show")
    reopened = wait(lambda s: s["open"])
    time.sleep(.35)
    key(15)
    stepped = wait(lambda s: s["selected"] != reopened["selected"])
    expected = json.loads(ipc("omaglide", "status"))["preview"]["capture"]["address"]
    key(28)
    wait(lambda s: not s["open"])
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        active = json.loads(compositor.ctl("-j", "activewindow"))
        if active.get("address") == expected:
            break
        time.sleep(.05)
    check(active.get("address") == expected, "Tab selects and Enter activates the chosen real synthetic window", active.get("title"))
    print(json.dumps({"result": "passed", "runtime": str(runtime)}), flush=True)
finally:
    ipc("omaglide", "hide")
