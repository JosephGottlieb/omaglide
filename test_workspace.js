const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const test = require("node:test");
const api = vm.createContext({});
vm.runInContext(fs.readFileSync(path.join(__dirname, "workspace.js"), "utf8")
    .replace(/^\s*\.pragma library\s*$/m, ""), api, { filename: "workspace.js" });
const plain = value => JSON.parse(JSON.stringify(value));
const screen = (id = 0, name = "eDP-1", extra = {}) => ({ id, name, width: 2880, height: 1800,
    scale: 2, transform: 0, x: -595, y: 1308, activeWorkspace: { id: 1, name: "1" }, ...extra });
const ws = (id, extra = {}) => ({ id, name: String(id), monitor: "eDP-1", monitorID: 0, ...extra });
const win = (address, workspace = 1, extra = {}) => ({ address, workspace: { id: workspace, name: String(workspace) },
    at: [-595, 1338], size: [720, 870], monitor: 0, mapped: true, hidden: false,
    class: "org.example.Editor", title: address, focusHistoryID: 1, ...extra });

test("empty/missing inputs and all-empty reported workspaces produce no entries", () => {
    assert.deepEqual(plain(api.buildWorkspaces()), []);
    const entries = api.buildWorkspaces([], [ws(1), ws(2, { ispersistent: true }),
        ws(3, { windows: 7 })], [screen()]);
    assert.deepEqual(plain(entries), []);
});

test("client-only occupied workspaces survive partial snapshots but empty active workspaces do not", () => {
    const entries = api.buildWorkspaces([win("client", 3)], [], [screen()]);
    assert.deepEqual(Array.from(entries, entry => entry.workspaceId), [3]);
    assert.equal(entries[0].count, 1);
    assert.equal(entries[0].active, false);
});

test("occupancy ignores hidden-only, unmapped-only and invalid-geometry-only workspaces", () => {
    const entries = api.buildWorkspaces([win("hidden", 1, { hidden: true }),
        win("unmapped", 2, { mapped: false }), win("malformed", 3, { size: [0, 400] }),
        win("visible", 4)], [ws(1), ws(2), ws(3), ws(4)], [screen()]);
    assert.deepEqual(Array.from(entries, entry => entry.workspaceId), [4]);
    assert.equal(entries[0].count, 1);
});

test("pinned-only workspaces remain occupied after expansion, including the active workspace", () => {
    const screens = [screen(0, "eDP-1", { activeWorkspace: { id: 3, name: "3" } }),
        screen(1, "DP-1", { activeWorkspace: { id: 4, name: "4" } })];
    const entries = api.buildWorkspaces([win("pin", 1, { pinned: true })],
        [ws(1), ws(2), ws(3), ws(4, { monitor: "DP-1", monitorID: 1 })], screens);
    assert.deepEqual(Array.from(entries, entry => entry.workspaceId), [1, 2, 3]);
    assert.deepEqual(Array.from(entries, entry => entry.count), [1, 1, 1]);
    assert.deepEqual(Array.from(entries, entry => entry.active), [false, false, true]);
    assert.ok(entries.every(entry => entry.windows[0].pinned));
    assert.deepEqual(plain(entries[2].viewport), { x: 0, y: 0, width: 1440, height: 900 });
});

test("numeric workspace order and stable keys do not depend on names or discovery order", () => {
    const entries = api.buildWorkspaces([win("ten", 10), win("two", 2), win("one", 1)],
        [ws(10), ws(2), ws(1, { name: "Personal" }), ws(2)], [screen()]);
    assert.deepEqual(Array.from(entries, entry => entry.key), ["workspace:1", "workspace:2", "workspace:10"]);
    assert.equal(entries[0].title, "Workspace Personal");
    assert.equal(entries[0].workspaceName, "Personal");
});

test("regular named negative IDs remain available, unlike special and invalid IDs", () => {
    for (const id of [1, 2, 99, -1337, -1338]) assert.equal(api.isRegularWorkspace(ws(id)), true);
    for (const id of [0, -1, -2, -99, -100, -101, -1336, NaN, Infinity, 1.5]) {
        assert.equal(api.isRegularWorkspace(ws(id)), false);
    }
    assert.equal(api.isRegularWorkspace(ws(5, { name: "special:scratch" })), false);
    const entries = api.buildWorkspaces([win("named", -1337), win("special", -99)],
        [ws(-1337, { name: "Work" }), ws(-99, { name: "special" }), ws(2)], []);
    assert.deepEqual(Array.from(entries, entry => entry.workspaceId), [-1337]);
    assert.equal(entries[0].title, "Workspace Work");
    assert.equal(entries[0].count, 1);
});

test("two windows preserve positions, dimensions and gaps within one workspace", () => {
    const entries = api.buildWorkspaces([win("left", 1, { size: [690, 870] }),
        win("right", 1, { at: [135, 1338], size: [710, 870] })], [ws(1)], [screen()]);
    assert.equal(entries.length, 1);
    assert.equal(entries[0].count, 2);
    assert.deepEqual(Array.from(entries[0].windows, w => [w.x, w.y, w.width, w.height]),
        [[0, 30, 690, 870], [730, 30, 710, 870]]);
    assert.deepEqual(plain(entries[0].viewport), { x: 0, y: 0, width: 1440, height: 900 });
});

test("mixed monitor scales do not divide already-logical client coordinates twice", () => {
    const screens = [screen(), screen(1, "DP-1", { x: 845, y: 0, width: 3840, height: 2160,
        scale: 1.5, activeWorkspace: { id: 2 } })];
    const entries = api.buildWorkspaces([win("laptop"), win("external", 2,
        { monitor: 1, at: [1045, 100], size: [1200, 800] })],
        [ws(1), ws(2, { monitor: "DP-1", monitorID: 1 })], screens);
    assert.deepEqual(plain(entries[0].monitorViewport), { x: 0, y: 0, width: 1440, height: 900 });
    assert.deepEqual(plain(entries[1].monitorViewport), { x: 0, y: 0, width: 2560, height: 1440 });
    assert.deepEqual(Array.from(entries[1].windows, w => [w.x, w.y, w.width, w.height]), [[200, 100, 1200, 800]]);
});

test("rotated/flipped monitor mode axes are handled before fractional scale", () => {
    for (const transform of [0, 2, 4, 6]) {
        assert.deepEqual(plain(api.monitorViewport(screen(0, "x", { transform }))),
            { x: 0, y: 0, width: 1440, height: 900 });
    }
    for (const transform of [1, 3, 5, 7]) {
        assert.deepEqual(plain(api.monitorViewport(screen(0, "x", { transform }))),
            { x: 0, y: 0, width: 900, height: 1440 });
    }
});

test("scrolling/offscreen windows expand viewport without rearranging monitor-relative geometry", () => {
    const entry = api.buildWorkspaces([win("left-offscreen", 1, { at: [-995, 1208], size: [300, 400] }),
        win("right-offscreen", 1, { at: [1505, 1338], size: [720, 900] })], [ws(1)], [screen()])[0];
    assert.deepEqual(plain(entry.monitorViewport), { x: 0, y: 0, width: 1440, height: 900 });
    assert.deepEqual(plain(entry.viewport), { x: -400, y: -100, width: 3220, height: 1030 });
    assert.deepEqual(Array.from(entry.windows, w => [w.x, w.y]), [[-400, -100], [2100, 30]]);
    for (const w of entry.windows) {
        assert.ok(w.x >= entry.viewport.x && w.y >= entry.viewport.y);
        assert.ok(w.x + w.width <= entry.viewport.x + entry.viewport.width);
        assert.ok(w.y + w.height <= entry.viewport.y + entry.viewport.height);
    }
});

test("pinned windows repeat on same-monitor workspaces, not other monitors or special spaces", () => {
    const screens = [screen(), screen(1, "DP-1", { x: 845, y: 0, activeWorkspace: { id: 3 } })];
    const entries = api.buildWorkspaces([win("pin", 1, { pinned: true }), win("other", 3, { monitor: 1, at: [845, 0] }),
        win("hidden-pin", 1, { pinned: true, hidden: true }), win("special-pin", -99, { pinned: true })],
        [ws(1), ws(2), ws(3, { monitor: "DP-1", monitorID: 1 })], screens);
    assert.deepEqual(Array.from(entries, entry => Array.from(entry.windows, w => w.address)), [["pin"], ["pin"], ["other"]]);
    assert.equal(entries[1].windows[0].pinned, true);
});

test("unmapped, hidden, malformed and duplicate clients cannot corrupt workspace bounds", () => {
    const entry = api.buildWorkspaces([win("good"), win("good"), null,
        win("hidden", 1, { hidden: true }), win("unmapped", 1, { mapped: false }),
        win("broken", 1, { at: [NaN, 0] }), win("zero", 1, { size: [0, 200] }),
        win("negative", 1, { size: [-200, 200] })], [ws(1)], [screen()])[0];
    assert.equal(entry.count, 1);
    assert.equal(entry.windows[0].address, "good");
    assert.equal(entry.viewport.width, 1440);
});

test("captures attach by address without copying or serializing live handles", () => {
    const handle = { opaque: "Wayland handle" };
    const entries = api.buildWorkspaces([win("first"), win("second", 1, { handle: "legacy" })],
        [ws(1)], [screen()], { first: handle });
    assert.equal(entries[0].windows[0].handle, handle);
    assert.equal(entries[0].windows[1].handle, "legacy");
});

test("stack order places floating/pinned above tiled and preserves raw order instead of MRU", () => {
    const entries = api.buildWorkspaces([win("current", 1, { focusHistoryID: 0 }),
        win("old", 1, { focusHistoryID: 9 }), win("floating", 1, { floating: true }),
        win("pin", 1, { pinned: true })], [ws(1)], [screen()]);
    assert.deepEqual(Array.from(entries[0].windows, w => w.address), ["current", "old", "floating", "pin"]);
    assert.deepEqual(Array.from(entries[0].windows, w => w.z), [0, 1, 2, 3]);
});

test("missing/disconnected monitor data still produces finite drawable geometry", () => {
    const entries = api.buildWorkspaces([win("window", 4)], [ws(4, { monitor: "removed" })], []);
    assert.equal(entries[0].monitorName, "removed");
    assert.equal(entries[0].active, false);
    for (const value of Object.values(entries[0].viewport)) assert.ok(Number.isFinite(value));
    assert.deepEqual(plain(api.monitorViewport(screen(0, "x", { scale: 0 }))),
        { x: 0, y: 0, width: 2880, height: 1800 });
});

test("all input records, nested arrays and ordering remain untouched", () => {
    const clients = [win("one"), win("two", 2)];
    const workspaces = [ws(2), ws(1)];
    const monitors = [screen()];
    const original = JSON.stringify([clients, workspaces, monitors]);
    function freeze(value) { if (value && typeof value === "object") { Object.values(value).forEach(freeze); Object.freeze(value); } }
    freeze(clients); freeze(workspaces); freeze(monitors);
    api.buildWorkspaces(clients, workspaces, monitors);
    assert.equal(JSON.stringify([clients, workspaces, monitors]), original);
});
