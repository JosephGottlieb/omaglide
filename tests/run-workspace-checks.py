#!/usr/bin/env python3
"""Exercise workspace and window mode only inside a verified disposable compositor.

Start tests/run-nested-hyprland 300, then pass its /tmp/od.XXXXXX/r.
This script applies the guarded headless output setup, copies the source into
the private fixture directory, and starts bounded synthetic input/window clients.
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
shutil.copy2(source / "tests/WorkspaceHarness.qml", fixture)
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
    application_list = wait(lambda c: len(c) == 3, getter=clients)
    check(all(c["title"].startswith("OmaGlide workspace fixture ") for c in application_list),
          "only three synthetic test windows are present")
    for client in application_list:
        destination = "2" if client["title"].endswith("Gamma") else "1"
        dispatch("hl.dsp.window.move({workspace=" + json.dumps(destination) + ",window="
                 + json.dumps("address:" + client["address"]) + ",follow=false})")
    # Keep an empty workspace reported even after focusing another workspace.
    result = compositor.ctl("eval", 'hl.workspace_rule({workspace="3",monitor="TEST-1",persistent=true})')
    if "error" in result.lower():
        raise RuntimeError(result)
    dispatch('hl.dsp.focus({workspace="3"})')
    dispatch('hl.dsp.focus({workspace="1"})')
    time.sleep(.25)
    ipc("omaglide", "workspaces")
    initial = wait(lambda s: s["open"] and s["mode"] == "workspaces" and s["count"] == 2)
    counts = {e["workspaceId"]: e["windowCount"] for e in initial["entries"]}
    check(counts == {1: 2, 2: 1}, "groups occupied workspaces and excludes persistent empty workspace", counts)
    select_workspace(1)
    populated = wait(lambda s: len(s["preview"]["capture"].get("windows", [])) == 2
                     and all(w["hasContent"] for w in s["preview"]["capture"]["windows"]), timeout=10)
    buffers = populated["preview"]["capture"]["windows"]
    check(len({w["address"] for w in buffers}) == 2 and all(w["nativeWidth"] > w["renderedWidth"] > 0 for w in buffers),
          "both windows have independent native-resolution buffers", buffers)
    state_entries = fixture_status()["entries"]
    scene = next(e for e in state_entries if e["workspaceId"] == 1)
    real_clients = {c["address"]: c for c in clients()}
    check(all(w["x"] == real_clients[w["address"]]["at"][0]
              and w["y"] == real_clients[w["address"]]["at"][1]
              and w["width"] == real_clients[w["address"]]["size"][0]
              and w["height"] == real_clients[w["address"]]["size"][1] for w in scene["windows"]),
          "workspace composition preserves actual synthetic window geometry", scene["windows"])
    ipc("omaglide", "resize", "reset")
    before = wait(lambda s: s["preferredWidth"] == 560)
    time.sleep(.2)
    key(13)
    enlarged = wait(lambda s: s["preferredWidth"] == 608)
    after_buffers = enlarged["preview"]["capture"]["windows"]
    before_buffers = before["preview"]["capture"]["windows"]
    check(enlarged["mode"] == "workspaces" and all(a["renderedWidth"] > b["renderedWidth"]
          and a["nativeWidth"] == b["nativeWidth"] for a, b in zip(after_buffers, before_buffers)),
          "keyboard resize enlarges workspace content without reducing native buffers", after_buffers)
    # Real Tab selects the next occupied workspace, skipping empty workspace 3.
    select_workspace(1)
    key(15)
    occupied = wait(lambda s: s["entries"][s["selected"]]["workspaceId"] == 2)
    check(occupied["preview"]["capture"]["count"] == 1, "Tab cycles onto next occupied workspace")
    key(28)
    wait(lambda s: not s["open"])
    chosen = wait(lambda w: w.get("id") == 2, getter=active_workspace)
    check(chosen["id"] == 2, "Enter activates chosen occupied workspace", chosen["id"])
    # Existing individual-window mode remains independently usable.
    ipc("omaglide", "show")
    windows_mode = wait(lambda s: s["open"] and s["mode"] == "windows" and s["count"] == 3)
    time.sleep(.25)
    key(15)
    window_step = wait(lambda s: s["selected"] != windows_mode["selected"])
    expected = window_step["preview"]["capture"]["address"]
    key(28)
    wait(lambda s: not s["open"])
    selected_window = wait(lambda w: w.get("address") == expected,
                           getter=lambda: json.loads(compositor.ctl("-j", "activewindow")))
    check(selected_window["address"] == expected, "window mode still cycles and activates an individual window")
    ipc("omaglide", "workspaces")
    wait(lambda s: s["open"])
    time.sleep(.25)
    key(1)
    wait(lambda s: not s["open"])
    old_keys = fixture_status()["appKeys"]
    key(30)
    delivered = wait(lambda f: f["appKeys"] > old_keys, getter=fixture_status)
    check(delivered["appKeys"] > old_keys, "Escape releases workspace keyboard grab to normal app")
    # Validate the replacement chord using both real modifier key events and
    # masks. Ctrl+Super+function keys can be consumed as VT switching by XKB.
    expression = 'hl.bind("ALT + W", hl.dsp.global("omaglide-workspace-test:workspaces"))'
    result = compositor.ctl("eval", expression)
    if "error" in result.lower():
        raise RuntimeError(result)
    compositor.verify_peer()
    chord = subprocess.Popen([str(chord_keyboard), "alt-key:17"],
                             env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        chord_open = wait(lambda s: s["open"] and s["mode"] == "workspaces", timeout=2)
        check(chord_open["holdMode"], "private Alt+W global shortcut opens workspace mode")
    finally:
        output, error = chord.communicate(timeout=4)
        if chord.returncode:
            raise RuntimeError(error or output)
    wait(lambda s: not s["open"])
    print(json.dumps({"result": "passed", "runtime": str(runtime),
                      "globalChord": "passed"}), flush=True)
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
