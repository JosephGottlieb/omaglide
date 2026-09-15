#!/usr/bin/env python3
"""Regression check for resizing over windows while real Super remains held.

Run only with the guarded disposable compositor runtime. Never targets desktop.
"""
import argparse
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import selectors
import shlex
import shutil
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("runtime")
parser.add_argument("--carousel-source", type=Path, help="Explicit pre-fix Carousel snapshot for regression proof")
parser.add_argument("--preview", type=Path, help="Save a screenshot of synthetic windows only (requires grim)")
args = parser.parse_args()
source = Path(__file__).resolve().parents[1]
infrastructure = source / "tests"
loader = importlib.machinery.SourceFileLoader("workspace_guard", str(infrastructure / "setup-nested-output"))
spec = importlib.util.spec_from_loader(loader.name, loader)
guard = importlib.util.module_from_spec(spec)
loader.exec_module(guard)
compositor = guard.NestedCompositor(args.runtime)
compositor.apply()
runtime = compositor.runtime
fixture = runtime.parent / "shell.qml"
if fixture.exists():
    raise RuntimeError("Refusing to overwrite an existing test fixture")
for name in ("Carousel.qml", "WorkspacePreview.qml", "logic.js", "workspace.js", "shortcuts.js"):
    shutil.copy2(source / name, runtime.parent / name)
if args.carousel_source:
    shutil.copy2(args.carousel_source, runtime.parent / "Carousel.qml")
shutil.copy2(source / "tests/InteractionHarness.qml", fixture)
(runtime.parent / "Commons").symlink_to("/usr/share/omarchy/shell/Commons", target_is_directory=True)
environment = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), OMADESKTOP_TEST_RUNTIME=str(runtime),
                   WAYLAND_DISPLAY="wayland-1", HYPRLAND_INSTANCE_SIGNATURE=compositor.instance.name)
environment.pop("WAYLAND_SOCKET", None)
helpers = source / ".test-build"
keyboard = helpers / "keyboard-build/virtual-keyboard"
pointer = helpers / "pointer-build/virtual-pointer"
chord_keyboard = runtime.parent / "omaglide-test-keyboard"
build = subprocess.run(["cc", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-I" + str(helpers / "keyboard-build"), str(source / "tests/virtual-keyboard.c"),
                        str(helpers / "keyboard-build/virtual-keyboard-protocol.c"),
                        "-o", str(chord_keyboard), "-lwayland-client", "-lxkbcommon"],
                       text=True, capture_output=True, timeout=15)
if build.returncode:
    raise RuntimeError(build.stderr)
keepers = []

def run(command, timeout=5):
    compositor.verify_peer()
    result = subprocess.run(command, env=environment, text=True, capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(result.stderr or result.stdout)
    return result.stdout.strip()

def ipc(target, method, *values):
    return run(["quickshell", "ipc", "-p", str(fixture), "call", "--", target, method, *values])

def status():
    return json.loads(ipc("omaglide", "status"))

def fixture_status():
    result = json.loads(ipc("fixture", "status"))
    if result.get("synthetic") is not True:
        raise RuntimeError("Unrecognized IPC fixture")
    return result

def wait(predicate, timeout=5, getter=status):
    deadline = time.monotonic() + timeout
    result = None
    while time.monotonic() < deadline:
        try:
            result = getter()
            if predicate(result):
                return result
        except RuntimeError:
            pass
        time.sleep(.06)
    raise AssertionError(f"Condition timed out: {result}")

def check(condition, label, evidence=None):
    print(json.dumps({"check": label, "passed": bool(condition), "evidence": evidence}), flush=True)
    if not condition:
        raise AssertionError(label)

def dispatch(expression):
    result = compositor.ctl("dispatch", expression)
    if result.strip() != "ok":
        raise RuntimeError(result)

def key(code):
    run([str(keyboard), f"key:{code}"])

def clients():
    return json.loads(compositor.ctl("-j", "clients"))

def active_workspace():
    return json.loads(compositor.ctl("-j", "activeworkspace"))

def select_workspace(number):
    for _ in range(12):
        state = status()
        if state["entries"][state["selected"]]["workspaceId"] == number:
            return wait(lambda s: (s.get("preview") or {}).get("capture", {}).get("workspaceId") == number)
        ipc("omaglide", "next")
        time.sleep(.22)
    raise AssertionError("Workspace absent from carousel")


def geometry():
    return {c["address"]: {"at": c["at"], "size": c["size"], "floating": c["floating"]} for c in clients()}

def drag_case(with_super):
    ipc("omaglide", "hide")
    ipc("omaglide", "resize", "reset")
    # Put an app directly behind the future lower-right resize grip.
    target = clients()[-1]
    selector = json.dumps("address:" + target["address"])
    if not target["floating"]:
        dispatch("hl.dsp.window.float({window=" + selector + "})")
    dispatch("hl.dsp.window.resize({x=1200,y=800,window=" + selector + "})")
    dispatch("hl.dsp.window.move({x=120,y=50,window=" + selector + "})")
    dispatch("hl.dsp.focus({window=" + selector + "})")
    held = None
    if with_super:
        compositor.verify_peer()
        held = subprocess.Popen([str(chord_keyboard), "hold-super:5000"], env=environment,
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        time.sleep(.15)
        compositor.verify_peer()
        # Lua's deliberate error() transports this read-only value on stdout
        # with status 1, just as the production release watcher expects.
        held_state = subprocess.run(["hyprctl", "eval", 'error(tostring(hl.is_key_down("Super_L")))'],
                                    env=environment, text=True, capture_output=True, timeout=3).stdout
        check("true" in held_state, "real Super key is held before resize", held_state.strip())
    try:
        ipc("omaglide", "show")
        wait(lambda s: s["open"])
        time.sleep(.3)
        preview = status()["preview"]
        width = preview["tileWidth"]
        x = round(preview["width"] / 2 + width / 2 - 22)
        y = round(preview["height"] / 2 + (width * .625 + 54) / 2 - 22)
        before = geometry()
        compositor.verify_peer()
        motion = subprocess.Popen([str(pointer), "--width", "1440", "--height", "900",
                                   f"move:{x}:{y}", "pause:120", "down", "pause:180",
                                   f"move:{x+80}:{y}", "pause:600",
                                   f"move:{x+160}:{y}", "pause:600", "up", "pause:100"],
                                  env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        samples = []
        try:
            while motion.poll() is None:
                samples.append(fixture_status())
                time.sleep(.08)
            output, error = motion.communicate(timeout=3)
            if motion.returncode:
                raise RuntimeError(error or output)
        finally:
            if motion.poll() is None:
                motion.terminate()
                motion.communicate(timeout=3)
        after = geometry()
        result = {
            "heldSuper": with_super, "before": before, "after": after,
            "shortcutsInhibited": preview.get("shortcutsInhibited", False),
            "startTileWidth": width,
            "endTileWidth": fixture_status()["preferredWidth"],
            "everResizing": any(s.get("resizing") for s in samples),
            "maxTileWidth": max(s.get("preferredWidth", 0) for s in samples),
            "underlyingWindowsChanged": before != after,
        }
        print(json.dumps({"dragEvidence": result}), flush=True)
        return result
    finally:
        if held:
            output, error = held.communicate(timeout=7)
            if held.returncode:
                raise RuntimeError(error or output)

try:
    for helper, prefix in ((keyboard, "Keyboard ready;"), (pointer, "Pointer ready;")):
        compositor.verify_peer()
        process = subprocess.Popen([str(helper), "--keep-alive", "90"], env=environment,
                                   text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        keepers.append(process)
        with selectors.DefaultSelector() as poller:
            poller.register(process.stdout, selectors.EVENT_READ)
            if not poller.select(4) or not process.stdout.readline().startswith(prefix):
                raise RuntimeError("Synthetic input seat did not become ready")
    command = "env OMADESKTOP_TEST_RUNTIME=" + shlex.quote(str(runtime)) + " quickshell -p " + shlex.quote(str(fixture))
    dispatch("hl.dsp.exec_cmd(" + json.dumps(command) + ")")
    wait(lambda s: s["synthetic"], getter=fixture_status)
    wait(lambda c: len(c) == 3, getter=clients)
    for expression in [
        'hl.bind("SUPER + mouse:272", hl.dsp.window.drag(), {mouse=true})',
        'hl.bind("SUPER + mouse:273", hl.dsp.window.resize(), {mouse=true})',
    ]:
        response = compositor.ctl("eval", expression)
        if "error" in response.lower():
            raise RuntimeError(response)
    bindings = json.loads(compositor.ctl("-j", "binds"))
    check(len([b for b in bindings if b.get("key") in ("mouse:272", "mouse:273") and b.get("modmask") == 64]) == 2,
          "production-equivalent Super mouse move/resize bindings installed", bindings)
    plain = drag_case(False)
    check(plain["everResizing"] and plain["endTileWidth"] >= 878 and not plain["underlyingWindowsChanged"],
          "unmodified drag resizes tile without moving app underneath", plain)
    modified = drag_case(True)
    check(modified["everResizing"] and modified["endTileWidth"] >= 878 and not modified["underlyingWindowsChanged"],
          "Super-held drag resizes tile without moving app underneath", modified)
    check(modified["shortcutsInhibited"], "compositor shortcut inhibitor is active during overlay")
    key(1)
    wait(lambda s: not s["open"])
    old_keys = fixture_status()["appKeys"]
    key(30)
    wait(lambda f: f["appKeys"] > old_keys, getter=fixture_status)
    check(True, "Escape returns keyboard input to underlying app")
    # The surface-scoped inhibitor must not permanently disable normal desktop
    # Super+drag once the overlay is closed.
    target = next(c for c in clients() if c["floating"])
    dispatch("hl.dsp.focus({window=" + json.dumps("address:" + target["address"]) + "})")
    before = geometry()
    compositor.verify_peer()
    held = subprocess.Popen([str(chord_keyboard), "hold-super:2200"], env=environment,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        time.sleep(.15)
        run([str(pointer), "--width", "1440", "--height", "900", "move:400:300", "pause:100",
             "down", "pause:100", "move:480:340", "pause:150", "up", "pause:100"])
        after = geometry()
        check(after[target["address"]]["at"] != before[target["address"]]["at"],
              "normal Super+mouse move binding works again after Escape", {"before": before, "after": after})
    finally:
        output, error = held.communicate(timeout=4)
        if held.returncode:
            raise RuntimeError(error or output)
    result = compositor.ctl("eval", 'hl.bind("ALT + W", hl.dsp.global("omaglide-isolated-test:workspaces"))')
    if "error" in result.lower():
        raise RuntimeError(result)
    compositor.verify_peer()
    chord = subprocess.Popen([str(chord_keyboard), "alt-key:17"], env=environment,
                             text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        chord_open = wait(lambda s: s["open"] and s["mode"] == "workspaces", timeout=2)
        check(chord_open["holdMode"], "Alt+W opens workspace mode after resize")
    finally:
        output, error = chord.communicate(timeout=4)
        if chord.returncode:
            raise RuntimeError(error or output)
    wait(lambda s: not s["open"])
    check(True, "Alt release closes workspace mode with inhibitor enabled")
    # Test the public interaction, not just a direct workspace shortcut.
    compositor.ctl("eval", 'hl.bind("ALT + TAB", hl.dsp.global("omaglide-isolated-test:next"), {description="OmaGlide windows"})')
    compositor.verify_peer()
    chord = subprocess.Popen([str(chord_keyboard), "alt-workspaces"], env=environment,
                             text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        wait(lambda s: s["open"] and s["mode"] == "windows", timeout=2)
        wait(lambda s: s["open"] and s["mode"] == "workspaces", timeout=2)
    finally:
        output, error = chord.communicate(timeout=4)
        if chord.returncode:
            raise RuntimeError(error or output)
    wait(lambda s: not s["open"])
    check(True, "Alt+Tab then W while Alt stays held switches modes; Alt release selects")
    ipc("omaglide", "show")
    wait(lambda s: "Windows: Alt+Tab" in s.get("shortcutText", ""))
    compositor.ctl("eval", 'hl.unbind("ALT + TAB"); hl.bind("ALT + SPACE", hl.dsp.global("omaglide-isolated-test:next"), {description="OmaGlide windows"})')
    updated = wait(lambda s: "Windows: Alt+Space" in s.get("shortcutText", "") and "Alt+Tab" not in s.get("shortcutText", ""))
    check(True, "footer tracks live rebinds without restarting", updated["shortcutText"])
    compositor.ctl("eval", 'hl.unbind("ALT + SPACE"); hl.bind("ALT + TAB", hl.dsp.global("omaglide-isolated-test:next"), {description="OmaGlide windows"})')
    wait(lambda s: "Windows: Alt+Tab" in s.get("shortcutText", ""))
    if args.preview:
        if args.preview.exists():
            raise RuntimeError("Refusing to overwrite a preview file")
        wait(lambda s: s.get("preview", {}).get("capture", {}).get("hasContent"))
        run(["grim", "-o", "TEST-1", str(args.preview.resolve())])
        check(True, "captured synthetic-only preview", str(args.preview))
    print(json.dumps({"result": "passed", "runtime": str(runtime)}), flush=True)
finally:
    try:
        ipc("omaglide", "hide")
        ipc("fixture", "done")
    except (RuntimeError, subprocess.SubprocessError):
        pass
    for process in keepers:
        if process.poll() is None:
            process.terminate()
        process.communicate(timeout=4)
