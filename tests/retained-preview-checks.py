"""Shared native-frame retention checks for guarded compositor fixtures only."""
import json
import time

from PIL import Image, ImageChops, ImageStat


def check_mru_preview_identity(*, compositor, status, wait, ipc, run, check):
    """Prove that recycled integer delegates capture their new app addresses."""
    compositor.verify_peer()
    before = wait(lambda s: s["open"] and s["mode"] == "windows" and s["count"] > 3
                  and all(native_frames(i) for i in s["preview"]["overview"]["items"]))
    time.sleep(.35)
    before_path = compositor.runtime.parent / "mru-before.png"
    run(["grim", "-o", "TEST-1", str(before_path)])
    before_items = before["preview"]["overview"]["items"]
    original = {i["key"]: ImageStat.Stat(thumbnail_pixels(before, i["key"], before_path)).mean
                for i in before_items if not i["selected"]}
    # OmaGlide intentionally puts the currently focused app last. Focus a
    # middle entry so many integer delegates acquire a different app address.
    focus_address = before_items[len(before_items) // 2]["key"]
    ipc("omaglide", "hide")
    wait(lambda s: not s["open"] and not s["preview"]["shortcutsInhibited"])
    result = compositor.ctl("dispatch", "hl.dsp.focus({window="
        + json.dumps("address:" + focus_address) + "})")
    if result.strip() != "ok":
        raise RuntimeError(result)
    wait(lambda w: w.get("address") == focus_address,
         getter=lambda: json.loads(compositor.ctl("-j", "activewindow")))
    ipc("omaglide", "windows")
    after = wait(lambda s: s["open"] and s["mode"] == "windows"
                 and s["entries"][-1]["key"] == focus_address
                 and all(native_frames(i) for i in s["preview"]["overview"]["items"]))
    before_order = [i["key"] for i in before_items]
    after_order = [i["key"] for i in after["preview"]["overview"]["items"]]
    check(before_order != after_order and after_order[-1] == focus_address,
          "focusing another closed application actually changes carousel MRU order")
    changed_keys = {address for address in original
                    if before_order.index(address) != after_order.index(address)}
    after_path = compositor.runtime.parent / "mru-after.png"
    deadline = time.monotonic() + 5
    errors = {}
    while time.monotonic() < deadline:
        time.sleep(.15)
        current = status()
        run(["grim", "-o", "TEST-1", str(after_path)])
        compared = [i for i in current["preview"]["overview"]["items"]
                    if i["key"] in changed_keys and not i["selected"]]
        errors = {i["key"]: max(abs(a - b) for a, b in zip(original[i["key"]],
            ImageStat.Stat(thumbnail_pixels(current, i["key"], after_path)).mean)) for i in compared}
        if len(errors) >= 3 and max(errors.values()) < 10:
            break
    check(len(errors) >= 3 and max(errors.values()) < 10,
          "reordered native thumbnail colors still match the same application addresses",
          {"reassignedEntriesCompared": len(errors),
           "largestMeanChannelError": round(max(errors.values()), 2) if errors else None})


def check_retained_preview(*, compositor, status, wait, ipc, fixture_status,
                           key, run, check, namespace, open_method, mode):
    compositor.verify_peer()
    before = wait(lambda s: s["open"] and s["mode"] == mode and s["preview"]
                  and all(native_frames(i) for i in s["preview"]["overview"]["items"]))
    # A nonselected entry must be refreshed explicitly: it has no live stream.
    # Persistent reopening selects the focused app/workspace. Choose a frame
    # that remains nonselected even if browsing moved the current selection.
    real_clients = json.loads(compositor.ctl("-j", "clients"))
    focused = next((c for c in real_clients if c.get("focusHistoryID") == 0), {})
    focused_workspace = json.loads(compositor.ctl("-j", "activeworkspace")).get("id")
    target = next(i for n, i in enumerate(before["preview"]["overview"]["items"])
                  if not i["selected"] and (i["key"] != focused.get("address") if mode == "windows"
                      else i.get("capture", {}).get("workspaceId") != focused_workspace))
    cached = {i["key"]: native_frames(i) for i in before["preview"]["overview"]["items"]}
    time.sleep(.3)
    before_path = compositor.runtime.parent / (mode + "-retention-before.png")
    run(["grim", "-o", "TEST-1", str(before_path)])
    original = thumbnail_pixels(before, target["key"], before_path)

    ipc("omaglide", "hide")
    closed = wait(lambda s: not s["open"] and s["preview"]
                  and not s["preview"]["shortcutsInhibited"])
    check({i["key"]: native_frames(i) for i in closed["preview"]["overview"]["items"]} == cached,
          mode + " close retains every native filmstrip buffer at its original resolution")
    layers = json.loads(compositor.ctl("-j", "layers"))
    check(not contains_namespace(layers, namespace),
          mode + " closed overlay is absent from compositor layers and releases shortcut inhibition")
    old_keys = fixture_status()["appKeys"]
    key(30)
    delivered = wait(lambda f: f["appKeys"] > old_keys, getter=fixture_status)
    check(delivered["appKeys"] > old_keys,
          mode + " closed retained overlay releases keyboard focus to the application")

    ipc("fixture", "recolor")
    time.sleep(.2)
    if mode == "workspaces":
        # An off-workspace synthetic window can have frame callbacks paused.
        # Let every fixture repaint while the switcher stays closed, then
        # restore the original workspace before checking its cached thumbnail.
        for workspace_id in [entry["workspaceId"] for entry in before["entries"]] + [focused_workspace]:
            result = compositor.ctl("dispatch", "hl.dsp.focus({workspace="
                + json.dumps(str(workspace_id)) + "})")
            if result.strip() != "ok":
                raise RuntimeError(result)
            time.sleep(.2)
    unchanged = status()
    check({i["key"]: native_frames(i) for i in unchanged["preview"]["overview"]["items"]} == cached,
          mode + " native frames remain available while the closed applications repaint")
    ipc("omaglide", open_method)
    reopened = wait(lambda s: s["open"] and s["mode"] == mode
                    and len(s["preview"]["overview"]["items"]) == len(cached)
                    and all(native_frames(i) for i in s["preview"]["overview"]["items"]))
    check({i["key"]: native_frames(i) for i in reopened["preview"]["overview"]["items"]} == cached,
          mode + " reopen preserves native thumbnail dimensions")
    after_target = next(i for i in reopened["preview"]["overview"]["items"] if i["key"] == target["key"])
    check(not after_target["selected"], mode + " refresh target remains nonselected after reopening")
    after_path = compositor.runtime.parent / (mode + "-retention-after.png")
    deadline = time.monotonic() + 5
    changed_fraction, red_gain = 0, 0
    while time.monotonic() < deadline:
        time.sleep(.12)
        current = status()
        run(["grim", "-o", "TEST-1", str(after_path)])
        updated = thumbnail_pixels(current, target["key"], after_path)
        if updated.size != original.size:
            continue
        difference = ImageChops.difference(original, updated)
        changed_fraction = sum(max(p) > 20 for p in difference.getdata()) / (difference.width * difference.height)
        red_gain = ImageStat.Stat(updated).mean[0] - ImageStat.Stat(original).mean[0]
        if changed_fraction > .05 and red_gain > 5:
            break
    check(changed_fraction > .05 and red_gain > 5,
          mode + " reopening refreshes a nonselected native thumbnail after application repaint",
          {"changedFraction": round(changed_fraction, 3), "redGain": round(red_gain, 2)})


def native_frames(item):
    capture = item.get("capture") or {}
    records = capture.get("windows", [capture])
    if not records or not all(r.get("hasContent") for r in records):
        return None
    return {r["address"]: (r["nativeWidth"], r["nativeHeight"]) for r in records}


def contains_namespace(value, namespace):
    if isinstance(value, dict):
        return value.get("namespace") == namespace or any(contains_namespace(v, namespace) for v in value.values())
    return isinstance(value, list) and any(contains_namespace(v, namespace) for v in value)


def thumbnail_pixels(state, entry_key, image_path):
    strip = state["preview"]["overview"]
    item = next(i for i in strip["items"] if i["key"] == entry_key)
    left, top = round(strip["x"] + item["x"]), round(strip["y"] + item["y"])
    # Exclude icons and the selected underline below the actual thumbnail.
    return Image.open(image_path).convert("RGB").crop((left, top,
        left + round(item["width"]), top + round(item["height"] - 28)))
