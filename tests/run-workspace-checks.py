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

retention_loader = importlib.machinery.SourceFileLoader("retained_preview_checks",
    str(Path(__file__).resolve().parent / "retained-preview-checks.py"))
retention_spec = importlib.util.spec_from_loader(retention_loader.name, retention_loader)
retention = importlib.util.module_from_spec(retention_spec)
retention_loader.exec_module(retention)

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("runtime")
parser.add_argument("--preview", type=Path, help="Save the workspace carousel and filmstrip (synthetic windows only)")
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
for name in ("Carousel.qml", "SettingsPanel.qml", "WorkspacePreview.qml", "logic.js", "workspace.js", "shortcuts.js"):
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
    compositor.ctl("eval", 'hl.bind("ALT_L", hl.dsp.global("omaglide-workspace-test:release"), {release=true,dont_inhibit=true,non_consuming=true,ignore_mods=true,transparent=true}); hl.bind("ALT_R", hl.dsp.global("omaglide-workspace-test:release"), {release=true,dont_inhibit=true,non_consuming=true,ignore_mods=true,transparent=true})')
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
    check(initial["entries"][initial["selected"]]["workspaceId"] == 1,
          "persistent workspace overview starts on the current workspace")
    # A cold native-buffer upload can occupy the entire 50ms animation on a
    # busy test renderer. Observe a warm reopen if no intermediate frame ran.
    for animation_attempt in range(3):
        slid = wait(lambda f: f["entranceSamples"] and f["entranceSamples"][-1]["progress"] >= .999,
                    getter=fixture_status)
        slide_samples = slid["entranceSamples"]
        if any(0 < sample["progress"] < .99 for sample in slide_samples) or animation_attempt == 2:
            break
        ipc("omaglide", "hide")
        wait(lambda s: not s["open"])
        ipc("omaglide", "workspaces")
        initial = wait(lambda s: s["open"] and s["mode"] == "workspaces" and s["count"] == 2)
    check(initial["entranceDuration"] == 50
          and any(0 < sample["progress"] < .99 for sample in slide_samples)
          and any(sample["offset"] > .1 for sample in slide_samples)
          and abs(slide_samples[-1]["offset"]) < .01
          and all(sample["opacity"] == 1 for sample in slide_samples)
          and all(before["progress"] <= after["progress"] and before["offset"] >= after["offset"]
                  for before, after in zip(slide_samples, slide_samples[1:])),
          "entrance slides from the right in 50ms while staying fully opaque",
          {"durationMs": initial["entranceDuration"], "samples": slide_samples})
    strip = initial["preview"]["overview"]
    check(strip["visible"] and [i["key"] for i in strip["items"]] == [e["key"] for e in initial["entries"]]
          and sum(i["selected"] for i in strip["items"]) == 1,
          "bottom filmstrip shows each occupied workspace once with one selected entry")
    counts = {e["workspaceId"]: e["windowCount"] for e in initial["entries"]}
    check(counts == {1: 2, 2: 1}, "groups occupied workspaces and excludes persistent empty workspace", counts)
    select_workspace(1)
    populated = wait(lambda s: len(s["preview"]["capture"].get("windows", [])) == 2
                     and all(w["hasContent"] for w in s["preview"]["capture"]["windows"]), timeout=10)
    buffers = populated["preview"]["capture"]["windows"]
    check(len({w["address"] for w in buffers}) == 2 and all(w["nativeWidth"] > w["renderedWidth"] > 0 for w in buffers),
          "both windows have independent native-resolution buffers", buffers)
    state_entries = fixture_status()["entries"]
    filmstrip = wait(lambda s: len(s["preview"]["overview"]["items"]) == 2 and all(
        len(i.get("capture", {}).get("windows", [])) == counts.get(i.get("capture", {}).get("workspaceId"))
        and all(w["hasContent"] and w["nativeWidth"] > w["renderedWidth"] > 0
                and w["nativeHeight"] > w["renderedHeight"] > 0
                for w in i["capture"]["windows"])
        for i in s["preview"]["overview"]["items"]), timeout=10)
    scenes = {e["workspaceId"]: {w["address"] for w in e["windows"]} for e in state_entries}
    compositions = [i["capture"] for i in filmstrip["preview"]["overview"]["items"]]
    check(all(c["count"] == counts[c["workspaceId"]]
              and {w["address"] for w in c["windows"]} == scenes[c["workspaceId"]]
              for c in compositions),
          "bottom workspace thumbnails compose every contained native window", compositions)
    select_workspace(1)
    retention.check_retained_preview(compositor=compositor, status=status, wait=wait, ipc=ipc,
        fixture_status=fixture_status, key=key, run=run, check=check,
        namespace="omaglide-workspace-test", open_method="workspaces", mode="workspaces")
    select_workspace(1)
    scene = next(e for e in state_entries if e["workspaceId"] == 1)
    real_clients = {c["address"]: c for c in clients()}
    check(all(w["x"] == real_clients[w["address"]]["at"][0]
              and w["y"] == real_clients[w["address"]]["at"][1]
              and w["width"] == real_clients[w["address"]]["size"][0]
              and w["height"] == real_clients[w["address"]]["size"][1] for w in scene["windows"]),
          "workspace composition preserves actual synthetic window geometry", scene["windows"])
    if args.preview:
        if args.preview.exists(): raise RuntimeError("Refusing to overwrite workspace preview")
        time.sleep(.3)
        run(["grim", "-o", "TEST-1", str(args.preview.resolve())])
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

    ipc("omaglide", "workspaces")
    wait(lambda s: s["open"] and s["mode"] == "workspaces" and s["preview"]["shortcutsInhibited"] and s["entranceProgress"] == 1)
    key(2)  # 1 immediately activates workspace ID 1.
    wait(lambda s: not s["open"])
    wait(lambda w: w.get("id") == 1, getter=active_workspace)
    check(not status()["searchQuery"], "number key immediately closes OmaGlide and activates the numbered workspace")
    ipc("omaglide", "workspaces")
    wait(lambda s: s["open"] and s["preview"]["shortcutsInhibited"] and s["entranceProgress"] == 1)
    run([str(chord_keyboard), "ctrl-key:33", "key:30"])  # Ctrl+F, a.
    wait(lambda s: s["searchQuery"] == "a")
    key(3)  # 2 must jump even with the focused search field containing text.
    wait(lambda s: not s["open"])
    wait(lambda w: w.get("id") == 2, getter=active_workspace)
    check(status()["searchQuery"] == "a", "focused workspace search reserves digits for immediate workspace jumps")
    ipc("omaglide", "workspaces")
    wait(lambda s: s["open"] and s["preview"]["shortcutsInhibited"] and s["entranceProgress"] == 1)
    key(4)  # 3 is empty and absent from the occupied-workspace strip.
    wait(lambda s: not s["open"])
    wait(lambda w: w.get("id") == 3, getter=active_workspace)
    check(True, "workspace numbers can jump directly to an empty workspace")
    dispatch('hl.dsp.focus({workspace="2"})')

    # Existing individual-window mode remains independently usable.
    ipc("omaglide", "windows")
    windows_mode = wait(lambda s: s["open"] and s["mode"] == "windows" and s["count"] == 3)
    current_window = next(c["address"] for c in clients() if c.get("focusHistoryID") == 0)
    check(windows_mode["entries"][windows_mode["selected"]]["key"] == current_window,
          "persistent application overview starts on the current app")
    run([str(chord_keyboard), "ctrl-key:34"])  # Ctrl+G: optional app grouping.
    grouped = wait(lambda s: s["open"] and s["groupApps"] and s["count"] == 1
                   and s["preview"]["capture"] and s["preview"]["capture"]["hasContent"])
    check(grouped["entries"][0]["windowCount"] == 3,
          "optional app grouping combines three windows of the same application")
    group_address = grouped["preview"]["capture"]["address"]
    key(108)  # Down cycles windows in the selected group.
    another = wait(lambda s: s["count"] == 1 and s["preview"]["capture"]
                   and s["preview"]["capture"]["address"] != group_address)
    check(another["preview"]["capture"]["address"] in {c["address"] for c in clients()},
          "Down cycles the selected app group's representative window")
    key(103)  # Up reverses the group cycle.
    wait(lambda s: s["preview"]["capture"]["address"] == group_address)
    key(108)
    member_choice = wait(lambda s: s["preview"]["capture"]["address"] != group_address)["preview"]["capture"]["address"]
    ipc("omaglide", "expose")  # Exposé always shows every window.
    ungrouped_overview = wait(lambda s: s["exposed"] and s["count"] == 3)
    check(ungrouped_overview["entries"][ungrouped_overview["selected"]]["address"] == member_choice,
          "Exposé shows individual windows and preserves the chosen grouped window")
    ipc("omaglide", "windows")
    regrouped = wait(lambda s: not s["exposed"] and s["count"] == 1)
    check(regrouped["entries"][0]["address"] == member_choice,
          "returning from Exposé preserves the exact app-group member")
    searched_member = next(c for c in clients() if c["address"] != member_choice)
    ipc("omaglide", "search", searched_member["title"].split()[-1])
    searched_group = wait(lambda s: s["count"] == 1 and s["entries"][0]["address"] == searched_member["address"])
    check(searched_group["entries"][0]["windowCount"] == 1,
          "app grouping search can find a member that was not the visible representative")
    ipc("omaglide", "search", "")
    wait(lambda s: s["count"] == 1 and s["entries"][0]["address"] == member_choice)
    key(28)
    wait(lambda s: not s["open"])
    wait(lambda w: w.get("address") == member_choice,
         getter=lambda: json.loads(compositor.ctl("-j", "activewindow")))
    check(True, "Enter activates the chosen member of a grouped application")
    ipc("omaglide", "windows")
    wait(lambda s: s["open"] and s["count"] == 1 and s["preview"]["shortcutsInhibited"] and s["entranceProgress"] == 1)
    run([str(chord_keyboard), "ctrl-key:34"])
    windows_mode = wait(lambda s: not s["groupApps"] and s["count"] == 3)
    check(fixture_status()["saved"].get("groupApps") is False
          and windows_mode["entries"][windows_mode["selected"]]["address"] == member_choice,
          "ungrouping restores every window, preserves selection, and persists into fixture memory")
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
    wait(lambda w: w.get("id") == chord_open["entries"][chord_open["selected"]]["workspaceId"],
         getter=active_workspace)
    ipc("omaglide", "windows")
    wait(lambda s: s["open"] and s["mode"] == "windows")
    ipc("omaglide", "hide")
    wait(lambda s: not s["open"])
    compositor.ctl("eval", 'hl.bind("ALT + TAB", hl.dsp.global("omaglide-workspace-test:next")); hl.bind("ALT + SHIFT + TAB", hl.dsp.global("omaglide-workspace-test:previous")); hl.bind("ALT + grave", hl.dsp.global("omaglide-workspace-test:expose"))')
    before_switch = clients()
    expected_next = min((c for c in before_switch if c.get("focusHistoryID", -1) > 0),
                        key=lambda c: c["focusHistoryID"])["address"]
    held = subprocess.Popen([str(chord_keyboard), "alt-key:15"], env=environment,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        next_app = wait(lambda s: s["open"] and s["mode"] == "windows" and s["holdMode"])
        check(not next_app["exposed"] and next_app["entries"][next_app["selected"]]["key"] == expected_next,
              "held Alt+Tab initially selects the next most recently used app",
              {"expected": expected_next, "selected": next_app["entries"][next_app["selected"]]["key"],
               "focusedBefore": [{"key": c["address"], "focusHistoryID": c.get("focusHistoryID")} for c in before_switch]})
    finally:
        output, error = held.communicate(timeout=5)
        if held.returncode: raise RuntimeError(error or output)
    wait(lambda s: not s["open"])
    wait(lambda w: w.get("address") == expected_next,
         getter=lambda: json.loads(compositor.ctl("-j", "activewindow")))
    check(True, "Alt release activates the initially selected next app")

    current_workspace_before = active_workspace()["id"]
    held = subprocess.Popen([str(chord_keyboard), "alt-tab-grave"], env=environment,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        wait(lambda s: s["open"] and s["mode"] == "windows" and s["holdMode"])
        workspace_choice = wait(lambda s: s["open"] and s["mode"] == "workspaces" and s["holdMode"] and s["count"] == 2)
        expected_workspace = workspace_choice["entries"][workspace_choice["selected"]]["workspaceId"]
        check(not workspace_choice["exposed"] and not workspace_choice["searchQuery"]
              and expected_workspace == current_workspace_before,
              "backtick during held Alt+Tab changes to workspaces without starting search or Exposé")
    finally:
        output, error = held.communicate(timeout=5)
        if held.returncode: raise RuntimeError(error or output)
    wait(lambda s: not s["open"])
    wait(lambda w: w.get("id") == expected_workspace, getter=active_workspace)
    check(True, "Alt release still activates the selected workspace after a backtick mode change")

    ipc("omaglide", "windows")
    wait(lambda s: s["open"] and s["mode"] == "windows")
    ipc("omaglide", "hide")
    wait(lambda s: not s["open"])
    current_before_roundtrip = json.loads(compositor.ctl("-j", "activewindow"))["address"]
    held = subprocess.Popen([str(chord_keyboard), "alt-tab-grave-roundtrip"], env=environment,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        wait(lambda s: s["open"] and s["mode"] == "windows" and s["holdMode"])
        wait(lambda s: s["open"] and s["mode"] == "workspaces" and s["holdMode"] and s["count"] == 2)
        roundtrip = wait(lambda s: s["open"] and s["mode"] == "windows" and s["holdMode"] and s["count"] == 3)
        roundtrip_address = roundtrip["entries"][roundtrip["selected"]]["key"]
        check(not roundtrip["exposed"] and not roundtrip["searchQuery"]
              and roundtrip_address == current_before_roundtrip,
              "another held backtick returns to the app carousel")
    finally:
        output, error = held.communicate(timeout=5)
        if held.returncode: raise RuntimeError(error or output)
    wait(lambda s: not s["open"])
    wait(lambda w: w.get("address") == roundtrip_address,
         getter=lambda: json.loads(compositor.ctl("-j", "activewindow")))

    current_window = json.loads(compositor.ctl("-j", "activewindow"))["address"]
    held = subprocess.Popen([str(chord_keyboard), "alt-expose-cycle"], env=environment,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        overview = wait(lambda s: s["open"] and s["exposed"] and s["mode"] == "windows")
        check(not overview["holdMode"] and overview["entries"][overview["selected"]]["key"] == current_window,
              "closed Alt+backtick opens persistent app Exposé on the current app")
        second = wait(lambda s: s["open"] and s["exposed"]
                      and s["selected"] == (overview["selected"] + 1) % overview["count"])
        third = wait(lambda s: s["open"] and s["exposed"]
                     and s["selected"] == (overview["selected"] + 2) % overview["count"])
        check(not second["searchQuery"] and not third["searchQuery"] and not third["holdMode"],
              "repeated backtick while Alt stays held advances through Exposé without closing or searching")
    finally:
        output, error = held.communicate(timeout=5)
        if held.returncode: raise RuntimeError(error or output)
    check(status()["open"] and status()["exposed"], "Alt+backtick Exposé remains open after modifier release")
    key(1)
    wait(lambda s: not s["open"])

    # A number received before the snapshot exists must cancel that opening,
    # switch directly, and remain closed when the stale query completes.
    pending_number = ipc("fixture", "numberedWorkspaceWhileOpening", "2")
    wait(lambda s: not s["open"])
    wait(lambda w: w.get("id") == 2, getter=active_workspace)
    time.sleep(.2)
    check(pending_number == "true" and not status()["open"],
          "a workspace number during opening jumps immediately and cancels stale snapshot results")
    ipc("omaglide", "workspaces")
    wait(lambda s: s["preview"]["shortcutsInhibited"] and s["entranceProgress"] == 1)
    run([str(chord_keyboard), "ctrl-key:18"])
    time.sleep(.3)
    check(status()["mode"] == "workspaces" and not status()["exposed"], "Ctrl+E no longer switches views")
    ipc("omaglide", "expose")
    workspace_expose = wait(lambda s: s["open"] and s["mode"] == "windows" and s["exposed"] and s["count"] == 3)
    check(not workspace_expose["holdMode"], "Exposé from workspace mode shows individual windows")
    key(1)
    wait(lambda s: not s["open"])
    ipc("omaglide", "windows")
    wait(lambda s: s["open"] and s["mode"] == "windows" and s["preview"]["shortcutsInhibited"] and s["entranceProgress"] == 1)
    run([str(chord_keyboard), "ctrl-key:33", "key:44", "alt-key:4"])
    wait(lambda s: not s["open"])
    wait(lambda w: w.get("id") == 3, getter=active_workspace)
    check(not status()["open"] and status()["searchQuery"] == "z",
          "Alt+number jumps from filtered app search and its later Alt release cannot activate another entry")
    dispatch('hl.dsp.focus({workspace="1"})')

    # Release Alt during the entrance; opening must never wait for a slide to
    # finish before committing the next app or strand a keyboard grab.
    for attempt in range(3):
        expected_quick = min((c for c in clients() if c.get("focusHistoryID", -1) > 0),
                             key=lambda c: c["focusHistoryID"])["address"]
        run([str(chord_keyboard), "quick-alt-tab"])
        wait(lambda s: not s["open"])
        wait(lambda w: w.get("address") == expected_quick,
             getter=lambda: json.loads(compositor.ctl("-j", "activewindow")))
        check(True, "quick Alt+Tab switches apps without waiting for entrance", {"attempt": attempt + 1})

    ipc("omaglide", "workspaces")
    wait(lambda s: s["open"] and s["mode"] == "workspaces")
    ipc("omaglide", "hide")
    wait(lambda s: not s["open"])
    check(fixture_status()["saved"].get("carouselMode") == "workspaces",
          "choosing workspace carousel persists the mode alongside existing settings")
    for gesture in ("alt-key:15", "alt-shift-key:15"):
        before_workspace = active_workspace()["id"]
        held = subprocess.Popen([str(chord_keyboard), gesture], env=environment,
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            sticky = wait(lambda s: s["open"] and s["mode"] == "workspaces" and s["holdMode"])
            sticky_target = sticky["entries"][sticky["selected"]]["workspaceId"]
            check(sticky_target != before_workspace,
                  "held shortcut reopens the remembered workspace carousel", {"gesture": gesture})
        finally:
            output, error = held.communicate(timeout=5)
            if held.returncode: raise RuntimeError(error or output)
        wait(lambda s: not s["open"])
        wait(lambda w: w.get("id") == sticky_target, getter=active_workspace)
    compositor.ctl("eval", 'hl.bind("SUPER + CTRL + G", hl.dsp.global("omaglide-workspace-test:toggle"))')
    run([str(chord_keyboard), "alt-key:41"])
    temporary_expose = wait(lambda s: s["open"] and s["mode"] == "windows" and s["exposed"])
    check(temporary_expose["carouselMode"] == "workspaces"
          and fixture_status()["saved"].get("carouselMode") == "workspaces",
          "dedicated Exposé does not overwrite the remembered carousel mode")
    key(1)
    wait(lambda s: not s["open"])
    run([str(chord_keyboard), "super-ctrl-key:34"])
    wait(lambda s: s["open"] and s["mode"] == "workspaces" and not s["holdMode"])
    check(True, "persistent Super+Ctrl+G also reopens the remembered workspace carousel")
    key(41)
    wait(lambda s: s["open"] and s["mode"] == "windows" and s["carouselMode"] == "windows")
    key(1)
    wait(lambda s: not s["open"])
    quick_target = min((c for c in clients() if c.get("focusHistoryID", -1) > 0),
                       key=lambda c: c["focusHistoryID"])["address"]
    run([str(chord_keyboard), "quick-alt-tab"])
    wait(lambda s: not s["open"])
    wait(lambda w: w.get("address") == quick_target,
         getter=lambda: json.loads(compositor.ctl("-j", "activewindow")))
    check(status()["carouselMode"] == "windows", "backtick updates the remembered carousel while app MRU switching remains intact")

    # A real process restart reads persisted settings from the sandbox's
    # private HOME. No command or file write targets the host HOME.
    ipc("omaglide", "workspaces")
    wait(lambda s: s["open"] and s["carouselMode"] == "workspaces")
    saved_entry = dict(fixture_status()["saved"], id="omaglide-workspace-test", groupApps=False)
    saved_path = runtime.parent / "restart-settings.json"
    saved_path.write_text(json.dumps({"plugins": [saved_entry]}))
    marker = runtime.parent / "restart-settings-ready"
    write_private_settings = (
        "from pathlib import Path; "
        "p=Path.home()/'.config/omarchy/shell.json'; p.parent.mkdir(parents=True,exist_ok=True); "
        "p.write_text(Path(" + repr(str(saved_path)) + ").read_text()); "
        "Path(" + repr(str(marker)) + ").touch()"
    )
    dispatch("hl.dsp.exec_cmd(" + json.dumps("python3 -c " + shlex.quote(write_private_settings)) + ")")
    wait(lambda ready: ready, getter=marker.exists)
    ipc("fixture", "done")
    wait(lambda c: len(c) == 0, getter=clients)
    dispatch("hl.dsp.exec_cmd(" + json.dumps(command) + ")")
    wait(lambda f: f["synthetic"], getter=fixture_status)
    wait(lambda c: len(c) == 3, getter=clients)
    wait(lambda s: s["carouselMode"] == "workspaces")
    run([str(chord_keyboard), "super-ctrl-key:34"])
    restarted = wait(lambda s: s["open"] and s["mode"] == "workspaces" and not s["exposed"])
    check(restarted["preferredWidth"] == saved_entry["tileWidth"] and not restarted["groupApps"],
          "shell restart restores workspace carousel preference without losing size or grouping settings")
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
