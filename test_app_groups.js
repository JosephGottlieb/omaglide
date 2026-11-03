// Run: node --test test_app_groups.js. No compositor or QML runtime required.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const test = require("node:test");

const source = fs.readFileSync(path.join(__dirname, "logic.js"), "utf8")
    .replace(/^\s*\.pragma library\s*$/m, "");
const logic = vm.createContext({});
vm.runInContext(source, logic, { filename: "logic.js" });
const plain = value => JSON.parse(JSON.stringify(value));
const entry = (address, cls, extra = {}) => ({
    key: address, address, cls, title: address,
    workspaceId: 1, workspaceName: "Work", ...extra
});

test("app grouping preserves group and member MRU without mutating window records", () => {
    const windows = [
        entry("0xa", "org.browser.Browser", { title: "Recent browser window" }),
        entry("0xb", "com.mitchellh.ghostty"),
        entry("0xc", "org.browser.Browser", { title: "Older browser window" }),
        entry("0xd", "org.editor.Editor")
    ];
    const before = JSON.stringify(windows);
    const groups = plain(logic.groupAppEntries(windows));
    assert.deepEqual(groups.map(g => g.address), ["0xa", "0xb", "0xd"]);
    assert.deepEqual(groups.map(g => g.count), [2, 1, 1]);
    assert.deepEqual(groups[0].windows.map(w => w.address), ["0xa", "0xc"]);
    assert.equal(groups[0].title, "Recent browser window");
    assert.equal(groups[0].key, "app:org.browser.browser");
    assert.equal(groups[0].appKey, groups[0].key);
    assert.equal(groups[0].grouped, true);
    assert.equal(JSON.stringify(windows), before);
    assert.notEqual(logic.groupAppEntries(windows)[0], windows[0]);
});

test("the current app goes last and retains the active native capture representative", () => {
    const windows = [
        entry("0xa", "Editor", { title: "Other document" }),
        entry("0xb", "Browser"),
        entry("0xc", "Ghostty"),
        entry("0xd", "editor", { title: "Active document", width: 810, height: 550,
            workspaceId: 4, nativeHandle: "active-native-handle" })
    ];
    const groups = plain(logic.groupAppEntries(windows, "0xd"));
    assert.deepEqual(groups.map(g => g.address), ["0xb", "0xc", "0xd"]);
    const active = groups.at(-1);
    assert.deepEqual(active.windows.map(w => w.address), ["0xa", "0xd"]);
    assert.equal(active.title, "Active document");
    assert.equal(active.width, 810);
    assert.equal(active.height, 550);
    assert.equal(active.workspaceId, 4);
    assert.equal(active.nativeHandle, "active-native-handle");
    assert.equal(groups[logic.wrapIndex(groups.length, groups.length)].address, "0xb");
    assert.deepEqual(plain(logic.groupAppEntries(windows, "0xmissing"))
        .map(g => g.address), ["0xa", "0xb", "0xc"]);
});

test("normalization combines class case and whitespace without merging distinct web apps", () => {
    const windows = [
        entry("0xa", "  Org.Example.App  "),
        entry("0xb", "org.example.app"),
        entry("0xc", "chrome-mail__Default"),
        entry("0xd", "chrome-calendar__Default"),
        entry("0xe", "Chrome")
    ];
    const groups = plain(logic.groupAppEntries(windows));
    assert.equal(groups.length, 4);
    assert.equal(groups[0].count, 2);
    assert.deepEqual(groups.slice(1).map(g => g.count), [1, 1, 1]);
    assert.equal(logic.appClassKey(" Ｇhostty "), "ghostty");
    assert.equal(logic.appClassKey(undefined), "");
});

test("unknown classes stay separate and malformed inputs do not form app groups", () => {
    const windows = [
        entry("0xa", ""), entry("0xb", "   "), entry("0xc", undefined),
        { key: "no-address-a", title: "Unknown A" },
        { key: "no-address-b", title: "Unknown B" }, null, false, [], "window"
    ];
    const groups = plain(logic.groupAppEntries(windows, "0xa"));
    assert.equal(groups.length, 5);
    assert.equal(new Set(groups.map(g => g.key)).size, 5);
    assert.ok(groups.every(g => g.count === 1));
    assert.equal(groups.at(-1).address, "0xa");
    assert.equal(logic.groupAppEntries(undefined).length, 0);
    assert.equal(logic.groupAppEntries({}).length, 0);
    assert.equal(logic.groupAppEntries([]).length, 0);
});

test("group search reaches every member title, app and workspace", () => {
    const windows = [
        entry("0xa", "Editor", { title: "Front document" }),
        entry("0xb", "Ghostty", { title: "Shell" }),
        entry("0xc", "Editor", { title: "Café budget", workspaceId: 7, workspaceName: "Finance" })
    ];
    const groups = logic.groupAppEntries(windows);
    const before = JSON.stringify(groups);
    assert.deepEqual(plain(logic.filterEntries(groups, "cafe editor finance 7"))
        .map(g => g.key), ["app:editor"]);
    assert.equal(logic.filterEntries(groups, "not-in-any-window").length, 0);
    assert.equal(JSON.stringify(groups), before);
});

test("stable app keys survive representative changes and a one-app ring remains valid", () => {
    const first = entry("0xa", "Editor");
    const second = entry("0xb", "editor");
    const initial = plain(logic.groupAppEntries([first, second], "0xb"));
    const updated = plain(logic.groupAppEntries([second, first], "0xa"));
    assert.equal(initial[0].key, updated[0].key);
    assert.equal(initial[0].address, "0xb");
    assert.equal(updated[0].address, "0xa");
    assert.equal(logic.wrapIndex(1, initial.length), 0);
});
