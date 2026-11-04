#!/usr/bin/env python3
"""Search and Exposé integration checks in the guarded disposable compositor."""
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
parser.add_argument("--preview", type=Path, help="Save a screenshot of synthetic windows only (requires grim)")
parser.add_argument("--settings-preview", type=Path, help="Save the settings sheet")
parser.add_argument("--carousel-preview", type=Path, help="Save the carousel and bottom strip (synthetic windows only)")
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
for name in ("Carousel.qml", "SettingsPanel.qml", "GlassPanel.qml", "WorkspacePreview.qml", "logic.js", "workspace.js", "shortcuts.js"):
    shutil.copy2(source / name, runtime.parent / name)
shutil.copy2(source / "tests/InteractionHarness.qml", fixture)
fixture.write_text(fixture.read_text().replace('["Alpha", "Beta", "Gamma"]',
    '["Alpha", "Beta", "Gamma", "Delta", "Echo", "Foxtrot", "Golf", "Hotel", "India", "Juliet", "Kilo", "Lima"]'))
# Reproduce a blue-accent theme with transparent menu selection borders.
fixture.write_text(fixture.read_text().replace('import QtQuick', 'import QtQuick\nimport qs.Commons')
    .replace('Component.onCompleted: if (!armed) Qt.quit()', '''Component.onCompleted: {
        if (!armed) { Qt.quit(); return }
        Color.accent = "#268bd2"
        Color.foreground = "#cdd6f4"
        Color.shellValues = ({"menu.selected-border-alpha": "0", "popups.border": "#268bd2"})
    }'''))
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

def grid_packed(state):
    """Exposé tiles take each window's exact shape, inside the packed area, without overlap."""
    tiles = state["preview"]["tiles"]
    grid = state["preview"]["grid"]
    if not tiles or not grid or sum(tile["selected"] for tile in tiles) != 1 or state["entranceProgress"] != 1:
        return False
    for tile in tiles:
        if abs(tile["previewWidth"] / tile["previewHeight"] - tile["sourceAspectRatio"]) > .001:
            return False
        if abs(tile["height"] - grid["rowHeight"]) > .1:
            return False
        if tile["x"] < grid["left"] - .01 or tile["x"] + tile["width"] > grid["left"] + grid["width"] + .01:
            return False
        if tile["y"] < grid["top"] - .01 or tile["y"] + tile["height"] > grid["top"] + grid["height"] + .01:
            return False
    for i, a in enumerate(tiles):
        for b in tiles[i + 1:]:
            if not (a["x"] + a["width"] <= b["x"] + .01 or b["x"] + b["width"] <= a["x"] + .01
                    or a["y"] + a["height"] <= b["y"] + .01 or b["y"] + b["height"] <= a["y"] + .01):
                return False
    return True

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
    compositor.ctl("eval", 'hl.bind("ALT_L", hl.dsp.global("omaglide-isolated-test:release"), {release=true,dont_inhibit=true,non_consuming=true,ignore_mods=true,transparent=true}); hl.bind("ALT_R", hl.dsp.global("omaglide-isolated-test:release"), {release=true,dont_inhibit=true,non_consuming=true,ignore_mods=true,transparent=true})')
    wait(lambda c: len(c) == 12, getter=clients)
    # Give every fixture a realistic buffer size rather than twelve tiny tiles.
    for index, c in enumerate(clients()):
        selector = json.dumps("address:" + c["address"])
        dispatch("hl.dsp.window.float({window=" + selector + "})")
        width, height = (420, 700) if c["title"].endswith("Alpha") else (
            (1000, 360) if c["title"].endswith("Beta") else (640, 400))
        dispatch("hl.dsp.window.resize({x=" + str(width) + ",y=" + str(height) + ",window=" + selector + "})")
        dispatch("hl.dsp.window.move({x=" + str(80 + index * 28) + ",y=" + str(90 + index * 18) + ",window=" + selector + "})")
    time.sleep(.5)

    compositor.ctl("eval", 'hl.bind("ALT + grave", hl.dsp.global("omaglide-isolated-test:next"))')
    chord = subprocess.Popen([str(chord_keyboard), "alt-search"], env=environment,
                             text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        wait(lambda s: s["open"] and s["holdMode"])
        wait(lambda s: s["searchQuery"] == "a" and not s["holdMode"])
    finally:
        output, error = chord.communicate(timeout=5)
        if chord.returncode: raise RuntimeError(error or output)
    check(status()["open"], "typing while Alt held prevents release from dismissing search")
    # Escape clears first, then closes on the next press.
    key(1)
    wait(lambda s: s["open"] and s["searchQuery"] == "" and s["count"] == 12)
    overview = status()["preview"]["overview"]
    check(overview["visible"] and len(overview["items"]) == 12
          and [i["key"] for i in overview["items"]] == [e["key"] for e in status()["entries"]]
          and sum(i["selected"] for i in overview["items"]) == 1,
          "bottom filmstrip shows every window once with one selected entry")
    captured = wait(lambda s: len(s["preview"]["overview"]["items"]) == 12 and all(
        i.get("capture", {}).get("hasContent")
        and i["capture"]["nativeWidth"] > i["capture"]["renderedWidth"] > 0
        and i["capture"]["nativeHeight"] > i["capture"]["renderedHeight"] > 0
        for i in s["preview"]["overview"]["items"]), timeout=10)
    check(True, "bottom filmstrip captures every window from its native buffer",
          [i["capture"] for i in captured["preview"]["overview"]["items"]])
    key(15)
    moved = wait(lambda s: s["selected"] == 1)
    check([i["selected"] for i in moved["preview"]["overview"]["items"]]
          == [i == moved["selected"] for i in range(12)], "bottom underline follows keyboard selection")
    for _ in range(12): ipc("omaglide", "next")
    check(status()["preview"]["overview"]["items"][1]["selected"],
          "bottom selection stays aligned after wrapping the carousel")
    retention.check_mru_preview_identity(compositor=compositor, status=status, wait=wait,
        ipc=ipc, run=run, check=check)
    retention.check_retained_preview(compositor=compositor, status=status, wait=wait, ipc=ipc,
        fixture_status=fixture_status, key=key, run=run, check=check,
        namespace="omaglide-isolated-test", open_method="windows", mode="windows")
    before_tab = status()
    key(15)
    moved = wait(lambda s: s["selected"] == (before_tab["selected"] + 1) % before_tab["count"])
    check(not moved["searchQuery"], "reopened carousel gives Tab to navigation instead of stale search focus")
    if args.carousel_preview:
        if args.carousel_preview.exists(): raise RuntimeError("Refusing to overwrite carousel preview")
        wait(lambda s: s["preview"]["capture"] and s["preview"]["capture"]["hasContent"]
             and all(i.get("capture", {}).get("hasContent") for i in s["preview"]["overview"]["items"]))
        time.sleep(.3)
        run(["grim", "-o", "TEST-1", str(args.carousel_preview.resolve())])
    compositor.ctl("eval", 'hl.monitor({output="TEST-1",mode="720x600@60",position="0x0",scale=1})')
    compact = wait(lambda s: s["preview"]["width"] == 720)
    strip = compact["preview"]["overview"]
    check(len(strip["items"]) == 12 and len({round(i["y"], 2) for i in strip["items"]}) == 1 and all(
        i["width"] > 0 and i["height"] > 0
        and strip["x"] + i["x"] >= -.01 and strip["x"] + i["x"] + i["width"] <= 720.01
        and strip["y"] + i["y"] >= -.01 and strip["y"] + i["y"] + i["height"] <= 600.01
        for i in strip["items"])
        and all(a["x"] + a["width"] <= b["x"] + .01
                for a, b in zip(strip["items"], strip["items"][1:]))
        and compact["preview"]["carouselY"] + compact["preview"]["cardHeight"] <= strip["y"] - 23.99,
          "narrow screen fits every thumbnail in one row below the carousel", strip)
    compositor.ctl("eval", 'hl.monitor({output="TEST-1",mode="1440x900@60",position="0x0",scale=1})')
    wait(lambda s: s["preview"]["width"] == 1440)
    for code in [30, 38, 25, 35, 30]: key(code)  # alpha
    match = wait(lambda s: s["searchQuery"] == "alpha" and s["count"] == 1)
    check(True, "real text input filters window titles", match["count"])
    run([str(chord_keyboard), "ctrl-key:30", "key:48"])  # Ctrl+A, b
    wait(lambda s: s["searchQuery"] == "b" and s["count"] == 1)
    key(14)  # Backspace
    wait(lambda s: s["searchQuery"] == "" and s["count"] == 12)
    check(True, "search supports selection replacement and Backspace")
    for code in [44, 44, 44]: key(code)
    wait(lambda s: s["searchQuery"] == "zzz" and s["count"] == 0)
    check(not status()["preview"]["overview"]["visible"], "empty search hides the bottom strip")
    key(28)  # Empty selection cannot activate a window or dismiss the search.
    check(status()["open"] and status()["count"] == 0, "Enter on no matches keeps search open")
    key(1)
    wait(lambda s: s["open"] and s["count"] == 12 and not s["searchQuery"])
    run([str(chord_keyboard), "ctrl-key:18"])  # Ctrl+E no longer switches views
    time.sleep(.4)
    check(status()["open"] and not status()["exposed"], "Ctrl+E no longer toggles the carousel into Exposé")
    ipc("omaglide", "expose")
    grid = wait(lambda s: s["exposed"] and s["preview"]["loadedPreviews"] == 12 and grid_packed(s))
    check(not grid["preview"]["overview"]["visible"], "Exposé keeps its full-screen layout")
    check(not grid["preview"]["hintsVisible"], "shortcut hints stay hidden outside Settings")
    tiles = grid["preview"]["tiles"]
    # The sandbox's theme singleton can fail to resolve; OmaGlide then uses its
    # fallback accent, which status reports.
    accent = grid["accentColor"]
    check(sum(t["selected"] for t in tiles) == 1 and all(
        (t["frameWidth"] == 3 and t["frameColor"] == accent) if t["selected"]
        else (t["frameWidth"] == 1 and t["frameColor"] != accent) for t in tiles),
        "only the selected tile has a solid accent outline",
        [(t["selected"], t["frameWidth"], t["frameColor"]) for t in tiles])
    check(len(tiles) == 12 and grid_packed(grid), "Exposé packs every window on screen without overlap", grid["preview"]["grid"])
    native_ratios = {round(c["size"][0] / c["size"][1], 5) for c in clients()}
    check(any(ratio < 1 for ratio in native_ratios) and any(ratio > 2 for ratio in native_ratios)
          and all(round(t["sourceAspectRatio"], 5) in native_ratios for t in tiles),
          "Exposé frames take portrait and wide window shapes without letterboxed cells")
    key(108)  # Down
    moved = wait(lambda s: s["selected"] != grid["selected"] and grid_packed(s))
    check(all((t["frameColor"] == accent) == t["selected"] for t in moved["preview"]["tiles"]),
          "accent outline follows keyboard selection")
    rows = grid["preview"]["grid"]["rows"]
    row_of = lambda index: next(r for r, row in enumerate(rows) if index in row)
    check(len(rows) > 1 and row_of(moved["selected"]) == (row_of(grid["selected"]) + 1) % len(rows),
          "Down moves to the adjacent row", rows)
    check(all(abs(a[k] - b[k]) < .1 for a, b in zip(tiles, moved["preview"]["tiles"]) for k in ("x", "y", "width", "height")),
          "selection does not re-layout the other windows")
    settled = wait(lambda s: any(t["selected"] and t["scale"] > 1.1 for t in s["preview"]["tiles"])
                   and all(t["scale"] == 1 for t in s["preview"]["tiles"] if not t["selected"]))
    zoomed = [t for t in settled["preview"]["tiles"] if t["selected"]][0]
    check(True, "the selected Exposé tile zooms well beyond its neighbours", zoomed["scale"])
    key(57)  # Space opens Quick Look on the selection
    looked = wait(lambda s: s["quickLook"] and s["preview"]["quickLook"]["progress"] == 1
                  and s["preview"]["quickLook"]["hasContent"])
    ql = looked["preview"]["quickLook"]
    ratio = zoomed["sourceAspectRatio"]
    check(abs(ql["width"] / ql["height"] - ratio) < .01 and (ql["width"] >= 1440 * .92 - 1 or ql["height"] >= 900 - 181)
          and looked["open"] and looked["exposed"], "Quick Look enlarges the selected window to nearly full screen", ql)
    key(106)  # Right browses while previewing
    wait(lambda s: s["quickLook"] and s["selected"] != moved["selected"])
    key(105)  # Left
    wait(lambda s: s["quickLook"] and s["selected"] == moved["selected"])
    key(1)  # Escape closes only Quick Look, zooming back into the tile
    samples = []
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        q = status()["preview"]["quickLook"]
        samples.append((q["open"], q["shown"], round(q["progress"], 2)))
        if not q["shown"]: break
    check(any(not o and sh and 0 < p < 1 for o, sh, p in samples) and samples[-1] == (False, False, 0),
          "closing Quick Look animates a zoom-out before hiding", samples)
    wait(lambda s: s["open"] and s["exposed"] and not s["quickLook"])
    key(57); wait(lambda s: s["quickLook"]); key(57)
    wait(lambda s: s["open"] and not s["quickLook"])
    check(True, "Space and Escape dismiss Quick Look without leaving Exposé")
    key(103)  # Up
    wait(lambda s: s["selected"] == 0)
    for target_index in (len(tiles) - 1, 0):
        tile = status()["preview"]["tiles"][target_index]
        x, y = int(tile["x"] + tile["width"] / 2), int(tile["y"] + tile["height"] / 2)
        run([str(pointer), "--width", "1440", "--height", "900",
             f"move:{x-10}:{y}", "pause:100", f"move:{x+10}:{y}"])
        wait(lambda s: s["selected"] == target_index and grid_packed(s))
    check(True, "moving the pointer over an Exposé tile selects it")
    run([str(chord_keyboard), "ctrl-key:33"])  # Ctrl+F
    for code in [30, 38, 25, 35, 30]: key(code)
    narrowed = wait(lambda s: s["count"] == 1)
    check(narrowed["preview"]["grid"]["rowHeight"] > grid["preview"]["grid"]["rowHeight"],
          "filtered grid increases preview resolution/geometry")
    fit = narrowed["preview"]["grid"]
    check(abs(fit["rowHeight"] - fit["height"] * .82) < .01,
          "a lone window fills most of the screen instead of using carousel size", fit)
    saved_width = narrowed["preferredWidth"]
    ipc("omaglide", "resize", "smaller")
    check(status()["preview"]["grid"] == fit and status()["preferredWidth"] == saved_width,
          "grid auto-fit is independent of saved carousel width")
    compositor.ctl("eval", 'hl.monitor({output="TEST-1",mode="1920x1080@60",position="0x0",scale=1})')
    larger = wait(lambda s: s["preview"]["width"] == 1920 and s["preview"]["grid"]["rowHeight"] > fit["rowHeight"])
    check(abs(larger["preview"]["grid"]["height"] - (1080 - 96 - 36)) < .01,
          "Exposé automatically refits after screen-size changes")
    compositor.ctl("eval", 'hl.monitor({output="TEST-1",mode="1440x900@60",position="0x0",scale=1})')
    wait(lambda s: s["preview"]["width"] == 1440)
    key(1)
    wait(lambda s: s["count"] == 12 and s["open"])
    wait(lambda s: s["preview"]["capture"] and s["preview"]["capture"]["hasContent"])
    time.sleep(.6)
    if args.preview:
        if args.preview.exists(): raise RuntimeError("Refusing to overwrite preview")
        run(["grim", "-o", "TEST-1", str(args.preview.resolve())])
    if args.settings_preview:
        ipc("omaglide", "settings")
        wait(lambda s: s["settingsOpen"] and s["preview"]["hintsVisible"])
        time.sleep(.4)
        run(["grim", "-o", "TEST-1", str(args.settings_preview.resolve())])
        key(1)  # Escape closes only the settings sheet
        wait(lambda s: s["open"] and not s["settingsOpen"])
    check(ipc("omaglide", "bind", "toggle", "SUPER + F9").strip() == "ok", "IPC accepts a new slider chord")
    bound = wait(lambda b: any(x.get("key") == "F9" and x.get("modmask") == 64
                               and x.get("description") == "OmaGlide: slider" for x in b),
                 getter=lambda: json.loads(compositor.ctl("-j", "binds")))
    check(True, "custom slider chord is bound live in Hyprland")
    ipc("omaglide", "bind", "toggle", "SUPER + F10")
    moved_bind = wait(lambda b: any(x.get("key") == "F10" and x.get("description") == "OmaGlide: slider" for x in b)
                      and not any(x.get("key") == "F9" and x.get("modmask") == 64 for x in b),
                      getter=lambda: json.loads(compositor.ctl("-j", "binds")))
    check(True, "rebinding an action releases its previous chord")
    check(status()["gestures"]["status"] == "active" and not status()["gestures"]["conflicts"],
          "3-finger swipe gestures register without conflicts", status()["gestures"])
    ipc("omaglide", "hide"); wait(lambda s: not s["open"])
    ipc("omaglide", "swipe", "down")
    app_view = wait(lambda s: s["open"] and s["exposed"] and s["appExposed"] and s["entranceProgress"] == 1)
    check(app_view["appExposeClass"] and app_view["count"] == 12,
          "swipe down opens App Exposé for the focused app's class", app_view["appExposeClass"])
    ipc("omaglide", "swipe", "down")  # repeating App Exposé's own swipe keeps it open
    time.sleep(.3)
    check(status()["open"] and status()["appExposed"], "a second swipe down leaves App Exposé open")
    ipc("omaglide", "swipe", "up")  # up from App Exposé glides back to the desktop
    glide = []
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        g = status()
        glide.append((g["open"], g["closing"], round(g["entranceProgress"], 2)))
        if not g["open"]: break
    check(any(o and c and 0 < p < 1 for o, c, p in glide) and not glide[-1][0],
          "leaving App Exposé animates back to the desktop before closing", glide)
    ipc("omaglide", "swipe", "up")
    wait(lambda s: s["open"] and s["exposed"] and not s["appExposed"] and s["entranceProgress"] == 1)
    ipc("omaglide", "swipe", "up")  # repeating Exposé's swipe keeps it open
    time.sleep(.3)
    check(status()["open"] and status()["exposed"] and not status()["closing"], "a second swipe up leaves Exposé open")
    ipc("omaglide", "swipe", "down")  # down from Exposé glides home...
    wait(lambda s: s["closing"])
    ipc("omaglide", "swipe", "down")  # ...and down again, even mid-glide, opens App Exposé
    reversed_view = wait(lambda s: s["open"] and s["appExposed"] and not s["closing"] and s["entranceProgress"] == 1)
    check(True, "down, down goes Exposé → desktop → App Exposé without snapping shut")
    ipc("omaglide", "swipe", "up"); wait(lambda s: not s["open"])
    ipc("omaglide", "expose"); wait(lambda s: s["exposed"] and s["entranceProgress"] == 1)
    ipc("omaglide", "appExpose")
    wait(lambda s: s["open"] and s["exposed"] and s["appExposed"])
    ipc("omaglide", "swipe", "up"); wait(lambda s: not s["open"])
    check(True, "swipes follow Mission Control rules; App Exposé switches in place")
    # Tracked swipes: Hyprland's callbacks arrive as custom socket events, and
    # Exposé follows the fingers instead of waiting for them to lift.
    def swipe_event(direction, phase, progress):
        result = compositor.ctl("eval", 'hl.dispatch(hl.dsp.event("omaglide-isolated-test:swipe:%s:%s:%.4f"))'
                                % (direction, phase, progress))
        if "error" in result.lower():
            raise RuntimeError(result)
    swipe_event("up", "start", 0)
    wait(lambda s: s["open"] and s["exposed"] and s["tracking"] == "open")
    swipe_event("up", "update", .4)
    held = wait(lambda s: abs(s["entranceProgress"] - .4) < .01)
    time.sleep(.25)
    check(abs(status()["entranceProgress"] - .4) < .01 and status()["tracking"] == "open",
          "a swipe up holds Exposé exactly where the fingers are", held["entranceProgress"])
    swipe_event("up", "update", .2)
    wait(lambda s: abs(s["entranceProgress"] - .2) < .01)
    check(True, "moving the fingers back pulls Exposé back with them")
    time.sleep(.2)
    swipe_event("up", "update", .5)
    swipe_event("up", "end", .5)
    wait(lambda s: s["open"] and not s["closing"] and s["entranceProgress"] == 1 and not s["tracking"])
    check(True, "releasing past the threshold finishes opening from where the fingers stopped")
    swipe_event("down", "start", 0)
    swipe_event("down", "update", .5)
    halfway = wait(lambda s: s["closing"] and abs(s["entranceProgress"] - .5) < .01)
    check(halfway["open"] and halfway["tracking"] == "close", "swiping down drags Exposé back toward the desktop")
    time.sleep(.3)
    swipe_event("down", "update", .1)
    time.sleep(.3)
    swipe_event("down", "end", .1)
    wait(lambda s: s["open"] and not s["closing"] and s["entranceProgress"] == 1)
    check(True, "a short, slow swipe down springs Exposé back open")
    swipe_event("down", "start", 0)
    swipe_event("down", "update", .6)
    swipe_event("down", "end", .6)
    wait(lambda s: not s["open"])
    check(True, "a long swipe down finishes the trip to the desktop")
    swipe_event("up", "start", 0)
    wait(lambda s: s["open"] and s["tracking"] == "open")
    time.sleep(.3)
    swipe_event("up", "update", .08)
    time.sleep(.3)
    swipe_event("up", "end", .08)
    wait(lambda s: not s["open"])
    check(True, "a short, slow swipe up lets Exposé fall back closed")
    # Leaving to a window on another workspace glides onto that workspace.
    away = sorted(clients(), key=lambda c: c["title"])[-1]
    dispatch("hl.dsp.window.move({workspace=\"4\",window=" + json.dumps("address:" + away["address"]) + ",follow=false})")
    wait(lambda c: any(x["address"] == away["address"] and x["workspace"]["id"] == 4 for x in c), getter=clients)
    ipc("omaglide", "expose")
    shown = wait(lambda s: s["exposed"] and s["entranceProgress"] == 1 and s["preview"]["shortcutsInhibited"])
    index = next(i for i, t in enumerate(shown["preview"]["tiles"]) if t["address"] == away["address"])
    tile = shown["preview"]["tiles"][index]
    x, y = int(tile["x"] + tile["width"] / 2), int(tile["y"] + tile["height"] / 2)
    run([str(pointer), "--width", "1440", "--height", "900", f"move:{x-10}:{y}", "pause:100", f"move:{x+10}:{y}"])
    wait(lambda s: s["selected"] == index and not s["closing"])
    key(28)  # Enter
    leaving = wait(lambda s: s["closing"], timeout=2)
    workspace_mid_glide = json.loads(compositor.ctl("-j", "activeworkspace"))["id"]
    chosen = leaving["preview"]["tiles"][index]
    check(leaving["desktopWorkspaceId"] == 4 and workspace_mid_glide == 4
          and chosen["z"] > max(t["z"] for i, t in enumerate(leaving["preview"]["tiles"]) if i != index),
          "leaving to another workspace's window switches there as the glide starts, chosen window on top",
          {"desktop": leaving["desktopWorkspaceId"], "active": workspace_mid_glide, "z": chosen["z"]})
    others = [t for i, t in enumerate(wait(lambda s: s["closing"] and s["entranceProgress"] < .5)["preview"]["tiles"]) if i != index]
    check(all(t["opacity"] < 1 for t in others), "windows left behind fade instead of gliding to the old workspace")
    wait(lambda s: not s["open"])
    wait(lambda c: any(x["address"] == away["address"] and x.get("focusHistoryID") == 0 for x in c), getter=clients)
    check(True, "the chosen window is focused once Exposé unmaps")
    # Swipes only ever leave for the workspace Exposé opened over.
    home = next(c for c in clients() if c["address"] != away["address"])
    home_ws = home["workspace"]["id"]
    def active_workspace():
        return json.loads(compositor.ctl("-j", "activeworkspace"))["id"]
    def focus_home():
        time.sleep(.4)  # Let a previous exit's deferred focus land first.
        dispatch("hl.dsp.focus({window=" + json.dumps("address:" + home["address"]) + "})")
        wait(lambda c: any(x["address"] == home["address"] and x.get("focusHistoryID") == 0 for x in c), getter=clients)
        wait(lambda w: w == home_ws, getter=active_workspace)
    def landed_home():
        trail = []
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            st = status()
            trail.append((st["open"], st["closing"], st["tracking"], round(st["entranceProgress"], 2), active_workspace()))
            if not st["open"]: break
            time.sleep(.05)
        time.sleep(.4)
        focused = next(c for c in clients() if c.get("focusHistoryID") == 0)
        global landing
        landing = {"trail": trail[-8:], "workspace": active_workspace(), "home": home_ws,
                   "focused": focused["address"], "want": home["address"]}
        # Hyprland then focuses whatever is under the pointer (follow_mouse),
        # so only the workspace is OmaGlide's to keep.
        return not trail[-1][0] and active_workspace() == home_ws and all(w == home_ws for *_, w in trail)
    def open_on_away():
        ipc("omaglide", "expose")
        state = wait(lambda s: s["exposed"] and s["entranceProgress"] == 1 and s["preview"]["shortcutsInhibited"])
        i = next(n for n, t in enumerate(state["preview"]["tiles"]) if t["address"] == away["address"])
        t = state["preview"]["tiles"][i]
        cx, cy = int(t["x"] + t["width"] / 2), int(t["y"] + t["height"] / 2)
        run([str(pointer), "--width", "1440", "--height", "900", f"move:{cx-10}:{cy}", "pause:100", f"move:{cx+10}:{cy}"])
        wait(lambda s: s["selected"] == i and not s["closing"])
        return cx + 10, cy
    def swipe_out():
        swipe_event("down", "start", 0)
        swipe_event("down", "update", .6)
        swipe_event("down", "end", .6)
    focus_home()
    open_on_away()
    swipe_out()
    check(landed_home(), "with another workspace's window highlighted, the first swipe down exits to the original workspace", landing)
    focus_home()
    cx, cy = open_on_away()
    run([str(pointer), "--width", "1440", "--height", "900", f"move:{cx}:{cy}", "down", "up"])
    wait(lambda s: s["closing"], timeout=2)
    swipe_out()  # the click was the fingers landing
    check(landed_home(), "a click just before a swipe is undone; the swipe still exits to the original workspace", landing)
    focus_home()
    swipe_event("up", "start", 0)
    swipe_event("up", "update", .5)
    tracked = wait(lambda s: s["open"] and s["tracking"] == "open" and s["preview"]["tiles"])
    t = tracked["preview"]["tiles"][0]
    run([str(pointer), "--width", "1440", "--height", "900",
         f"move:{int(t['x'] + t['width'] / 2)}:{int(t['y'] + t['height'] / 2)}", "down", "up"])
    time.sleep(.3)
    check(status()["open"] and not status()["closing"] and status()["tracking"] == "open",
          "clicks while a swipe is moving do not activate a window")
    swipe_event("up", "end", .5)
    wait(lambda s: s["open"] and s["entranceProgress"] == 1 and not s["tracking"])
    dispatch('hl.dsp.focus({workspace="4"})')
    wait(lambda w: w == 4, getter=active_workspace)
    swipe_out()
    check(landed_home(), "a swipe exit returns to the original workspace even if it changed underneath", landing)
    dispatch("hl.dsp.window.move({workspace=" + json.dumps(str(home_ws)) + ",window=" + json.dumps("address:" + away["address"]) + ",follow=true})")
    wait(lambda w: w.get("id") == home_ws, getter=lambda: json.loads(compositor.ctl("-j", "activeworkspace")))
    ipc("omaglide", "sliderStyle", "icons")
    ipc("omaglide", "windows")
    icons = wait(lambda s: s["open"] and s["iconStyle"] and s["preview"]["iconSwitcher"]["visible"]
                 and s["preview"]["iconSwitcher"]["count"] == s["count"] and s["preview"]["shortcutsInhibited"])
    sw = icons["preview"]["iconSwitcher"]
    check(sw["selected"] == icons["selected"] and not icons["preview"]["overview"]["visible"]
          and icons["preview"]["loadedPreviews"] == 0 and sw["x"] >= 0 and sw["x"] + sw["width"] <= 1440.01,
          "App icons style shows a Cmd+Tab row with no live captures", sw)
    key(15)  # Tab
    moved_icon = wait(lambda s: s["preview"]["iconSwitcher"]["selected"] == (icons["selected"] + 1) % icons["count"])
    check(True, "Tab moves the highlighted icon")
    key(1); wait(lambda s: not s["open"])
    ipc("omaglide", "sliderStyle", "thumbnails")
    ipc("omaglide", "windows")
    # Keys go to the overlay only once it holds focus (the inhibitor follows it).
    wait(lambda s: s["open"] and not s["iconStyle"] and s["preview"]["overview"]["visible"]
         and s["preview"]["shortcutsInhibited"] and s["entranceProgress"] == 1)
    key(1); wait(lambda s: not s["open"])
    check(True, "switching back restores the thumbnail slider")
    ipc("omaglide", "gestures", "on", "4")
    four = wait(lambda s: s["gestures"]["fingers"] == 4 and s["gestures"]["status"] == "active", timeout=8)
    errors = compositor.ctl("configerrors").strip()
    check(not errors, "changing to 4 fingers reloads cleanly instead of unsetting gestures", errors)
    ipc("omaglide", "gestures", "off", "4")
    wait(lambda s: not s["gestures"]["enabled"] and s["gestures"]["status"] in ("off", "active"), timeout=8)
    ipc("omaglide", "gestures", "on", "3")
    wait(lambda s: s["gestures"]["fingers"] == 3 and s["gestures"]["status"] == "active", timeout=8)
    check(not compositor.ctl("configerrors").strip(), "gestures can be turned off and back on without config errors")
    ipc("omaglide", "windows")
    wait(lambda s: not s["exposed"] and s["count"] == 12)
    check(True, "IPC windows replaces Exposé with the carousel")
    state = status()
    strip = state["preview"]["overview"]
    item = strip["items"][-1]
    run([str(pointer), "--width", "1440", "--height", "900",
         "move:" + str(int(strip["x"] + item["x"] + item["width"] / 2)) + ":"
         + str(int(strip["y"] + item["y"] + item["height"] / 2)), "down", "up"])
    wait(lambda s: not s["open"])
    wait(lambda c: any(x["address"] == item["key"] and x.get("focusHistoryID") == 0 for x in c), getter=clients)
    check(True, "clicking a bottom strip entry activates that window")
    ipc("omaglide", "windows")
    wait(lambda s: s["open"] and not s["exposed"])
    ipc("omaglide", "expose")
    wait(lambda s: s["exposed"] and s["entranceProgress"] == 1)
    selected = status()["entries"][0]["key"]
    tile = status()["preview"]["tiles"][0]
    run([str(pointer), "--width", "1440", "--height", "900",
         "move:" + str(int(tile["x"] + tile["width"]/2)) + ":" + str(int(tile["y"] + tile["height"]/2)), "down", "up"])
    wait(lambda s: not s["open"])
    wait(lambda c: any(x["address"] == selected and x.get("focusHistoryID") == 0 for x in c), getter=clients)
    check(True, "clicking a grid tile activates that window")
    ipc("omaglide", "workspaces")
    wait(lambda s: s["open"] and s["mode"] == "workspaces")
    ipc("omaglide", "search", "alpha")
    wait(lambda s: s["count"] == 1)
    check(True, "workspace search matches contained window titles")
    key(1)
    wait(lambda s: s["open"] and not s["searchQuery"])
    key(1)
    wait(lambda s: not s["open"])
    # Exposé has a dedicated persistent shortcut. Fresh held switcher
    # shortcuts deliberately return to the carousel rather than remembering
    # Exposé, so a quick chord continues to switch applications.
    compositor.ctl("eval", 'hl.unbind("ALT + grave"); hl.bind("ALT + grave", hl.dsp.global("omaglide-isolated-test:expose")); hl.bind("ALT + TAB", hl.dsp.global("omaglide-isolated-test:next"))')
    held = subprocess.Popen([str(chord_keyboard), "alt-key:41"], env=environment,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        wait(lambda s: s["open"] and s["exposed"] and not s["holdMode"] and s["mode"] == "windows")
    finally:
        output, error = held.communicate(timeout=5)
        if held.returncode: raise RuntimeError(error or output)
    check(status()["open"] and not status()["holdMode"],
          "dedicated Alt+backtick Exposé stays open after modifier release")
    before_repeat = status()
    run([str(chord_keyboard), "alt-key:41"])
    repeated = wait(lambda s: s["open"] and s["exposed"]
                    and s["selected"] == (before_repeat["selected"] + 1) % before_repeat["count"])
    check(not repeated["searchQuery"], "a second Alt+backtick advances Exposé without adding a search character")
    run([str(chord_keyboard), "ctrl-key:33", "key:3"])
    wait(lambda s: not s["open"])
    wait(lambda w: w.get("id") == 2, getter=lambda: json.loads(compositor.ctl("-j", "activeworkspace")))
    check(not status()["searchQuery"], "number keys jump workspaces from focused Exposé search without becoming search text")
    dispatch('hl.dsp.focus({workspace="1"})')
    ipc("omaglide", "expose")
    wait(lambda s: s["open"] and s["exposed"] and s["preview"]["shortcutsInhibited"] and s["entranceProgress"] == 1)
    run([str(pointer), "--width", "1440", "--height", "900", "move:10:10", "down", "up"])
    wait(lambda s: not s["open"])
    check(True, "background click dismisses persistent Exposé")
    held = subprocess.Popen([str(chord_keyboard), "alt-key:15"], env=environment,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        wait(lambda s: s["open"] and s["mode"] == "workspaces" and not s["exposed"] and s["holdMode"])
    finally:
        output, error = held.communicate(timeout=5)
        if held.returncode: raise RuntimeError(error or output)
    wait(lambda s: not s["open"])
    check(True, "fresh Alt+Tab after temporary Exposé returns to the remembered workspace carousel")
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
