// Run: node --test test_logic.js. No compositor or QML runtime required.
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
const close = (actual, expected) => assert.ok(Math.abs(actual - expected) < 1e-8,
    `Expected ${actual} to be close to ${expected}`);
const client = (address, history, extra = {}) => ({
    address, focusHistoryID: history, mapped: true,
    workspace: { id: 1, name: "1" }, ...extra
});

test("search matches all words across title, app and workspace without mutation", () => {
    const entries = [
        {key: "a", title: "Café report", cls: "Chromium", workspaceName: "Work", workspaceId: 2},
        {key: "b", title: "Notes", cls: "Ghostty", workspaceName: "Home", workspaceId: 3},
        {key: "c", title: "Workspace 4", windows: [{title: "Quarterly report", cls: "LibreOffice"}]}
    ];
    const before = JSON.stringify(entries);
    assert.deepEqual(plain(logic.filterEntries(entries, " CHROM cafe ")).map(x => x.key), ["a"]);
    assert.deepEqual(plain(logic.filterEntries(entries, "report libre")).map(x => x.key), ["c"]);
    assert.deepEqual(plain(logic.filterEntries(entries, "3")).map(x => x.key), ["b"]);
    assert.equal(logic.filterEntries(entries, "[unmatched]").length, 0);
    assert.equal(logic.filterEntries(entries, " ").length, 3);
    assert.equal(JSON.stringify(entries), before);
});

test("clamp bounds values and falls back safely for corrupted settings", () => {
    for (const invalid of [undefined, null, NaN, Infinity, -Infinity, "", "oops", {}, true]) {
        assert.equal(logic.clamp(invalid, 240, 1200, 560), 560);
    }
    assert.equal(logic.clamp("720", 240, 1200, 560), 720);
    assert.equal(logic.clamp(1, 240, 1200, 560), 240);
    assert.equal(logic.clamp(10000, 240, 1200, 560), 1200);
    assert.equal(logic.clamp(720, 1200, 240, 560), 720);
    assert.equal(logic.clamp(NaN, 240, 1200, NaN), 240);
    assert.equal(logic.clamp(NaN, 240, 1200, 2000), 1200);
});

test("empty, invalid and single-window rings are defined", () => {
    for (const count of [0, -1, undefined, null, NaN, Infinity]) {
        assert.equal(logic.wrapIndex(18, count), 0);
        assert.equal(logic.signedDistance(1, -19, count), 0);
    }
    for (const value of [-1000, -1, 0, 1, 1000]) {
        assert.equal(logic.wrapIndex(value, 1), 0);
        assert.equal(logic.signedDistance(0, value, 1), 0);
    }
    assert.equal(logic.wrapIndex(NaN, 5), 0);
    assert.equal(logic.signedDistance(0, Infinity, 5), 0);
});

test("two-window rings cycle in either direction with deterministic opposite tiles", () => {
    assert.equal(logic.wrapIndex(-1, 2), 1);
    assert.equal(logic.wrapIndex(2, 2), 0);
    assert.equal(logic.signedDistance(1, 0, 2), 1);
    assert.equal(logic.signedDistance(0, 1, 2), 1);
    close(logic.signedDistance(1, 0.25, 2), 0.75);
    close(logic.signedDistance(0, 0.25, 2), -0.25);
});

test("negative, overflow and fractional ring positions wrap without endpoint jumps", () => {
    assert.equal(logic.wrapIndex(-11, 5), 4);
    assert.equal(logic.wrapIndex(16, 5), 1);
    close(logic.wrapIndex(-0.25, 5), 4.75);
    close(logic.wrapIndex(10.25, 5), 0.25);
    close(logic.signedDistance(0, 4.75, 5), 0.25);
    close(logic.signedDistance(4, -0.25, 5), -0.75);
    close(logic.signedDistance(0, 5.25, 5), -0.25);
    close(logic.signedDistance(0, -5.25, 5), 0.25);
});

test("every window survives many forward/backward cycles and stays in the closest ring", () => {
    for (const count of [2, 3, 4, 7, 20, 100]) {
        for (let position = -count * 3; position <= count * 3; position += 0.25) {
            const seen = new Set();
            for (let index = 0; index < count; index++) {
                const distance = logic.signedDistance(index, position, count);
                assert.ok(distance > -count / 2 && distance <= count / 2);
                close(logic.wrapIndex(position + distance, count), index);
                close(logic.signedDistance(index, position + count, count), distance);
                seen.add(distance);
            }
            assert.equal(seen.size, count);
        }
    }
});

test("tile width honors preference, defaults, sane bounds and screen dimensions", () => {
    assert.equal(logic.effectiveTileWidth(undefined, 1920, 1080), 560);
    assert.equal(logic.effectiveTileWidth("640", 1920, 1080), 640);
    assert.equal(logic.effectiveTileWidth(1, 1920, 1080), 240);
    assert.equal(logic.effectiveTileWidth(5000, 3840, 2160), 1200);
    assert.equal(logic.effectiveTileWidth(1200, 1920, 1080), 1200);
    assert.equal(logic.effectiveTileWidth(1200, 800, 1280), 736);
    assert.equal(logic.effectiveTileWidth(1200, 1920, 600), 672);
    assert.equal(logic.effectiveTileWidth(1200, 1920, 300), 192);
    assert.equal(logic.effectiveTileWidth(1200, 200, 500), 136);
    assert.equal(logic.effectiveTileWidth(null, undefined, undefined), 560);
    for (const width of [320, 800, 1366, 1920, 3840, 7680]) {
        for (const height of [240, 600, 768, 1080, 2160]) {
            const rendered = logic.effectiveTileWidth(1200, width, height);
            assert.ok(rendered > 0 && rendered <= width - 64);
            assert.ok(rendered * 10 / 16 + 180 <= height);
        }
    }
    assert.ok(logic.effectiveTileWidth(NaN, 1, 1) > 0);
});

test("center is full resolution size, adjacent tiles smaller and aspect ratio fixed", () => {
    const center = plain(logic.cardGeometry(0, 560));
    assert.deepEqual(center, { width: 560, height: 350, offset: 0, emphasis: 1 });
    for (const distance of [-10, -2, -1, 1, 2, 10]) {
        const card = logic.cardGeometry(distance, 560);
        close(card.width, 403.2);
        close(card.height, 252);
        close(card.offset, distance * 505.6);
        assert.equal(card.emphasis, 0);
    }
    const neighbour = logic.cardGeometry(1, 560);
    close(neighbour.offset - neighbour.width / 2 - center.width / 2, 24);
});

test("fractional animation smoothly interpolates size and is symmetric", () => {
    for (const distance of [0.01, 0.25, 0.5, 0.75, 0.99]) {
        const left = logic.cardGeometry(-distance, 900);
        const right = logic.cardGeometry(distance, 900);
        close(left.width, right.width);
        close(left.height, right.height);
        close(left.offset, -right.offset);
        close(right.width, 900 * (1 - 0.28 * distance));
        close(right.height / right.width, 10 / 16);
        close(right.emphasis, 1 - distance);
    }
    assert.equal(logic.cardGeometry(NaN, NaN).width, 560);
});

test("virtualized radius covers each viewport with an additional offscreen slot", () => {
    for (const screen of [320, 800, 1366, 1920, 3840, 7680]) {
        for (const width of [136, 240, 560, 1200]) {
            const radius = logic.visibleRadius(screen, width);
            assert.ok(Number.isInteger(radius) && radius > 0);
            const edge = logic.cardGeometry(radius - 1, width);
            assert.ok(edge.offset - width / 2 >= screen / 2);
            assert.ok((radius - 2) * (0.86 * width + 24) - width / 2 < screen / 2);
            const count = 101;
            const center = 100;
            const slots = new Set();
            for (let slot = -radius; slot <= radius; slot++) {
                slots.add(logic.wrapIndex(center + slot, count));
            }
            assert.equal(slots.size, 2 * radius + 1);
            assert.ok(slots.has(0), "right edge wraps to the beginning");
        }
    }
});

test("carousel span leaves empty and single-window carousels unrepeated", () => {
    for (const count of [0, -1, undefined, null, NaN, Infinity]) {
        assert.equal(logic.carouselSpan(count, 1920, 560), 0);
    }
    assert.equal(logic.carouselSpan(1, 1920, 560), 1);
    assert.equal(logic.carouselSpan(1, 7680, 240), 1);
    assert.equal(logic.carouselSpan(2, 1920, 560), 8);
    assert.equal(logic.carouselSpan(3, 1920, 560), 9);
    assert.equal(logic.carouselSpan(100, 1920, 560), 100);
});

test("short carousel rings repeat exactly and wrap only beyond prewarmed screen edges", () => {
    for (const count of [2, 3, 4, 5, 7, 20, 100]) {
        for (const screen of [320, 800, 1366, 1920, 3840, 7680]) {
            for (const width of [136, 240, 560, 1200]) {
                const span = logic.carouselSpan(count, screen, width);
                const step = 0.86 * width + 24;
                const prewarmEdge = screen / 2 + width;
                assert.equal(span % count, 0);
                assert.ok(span >= count);
                assert.ok(span / 2 * step > prewarmEdge,
                    `${count} windows/${screen}px/${width}px: seam must stay outside loaded viewport`);
                if (span > count) {
                    assert.ok((span - count) / 2 * step <= prewarmEdge,
                        "Do not repeat more copies than necessary");
                }
                // The reset may jump between positive and negative distances,
                // but both sides of that instant are beyond the prewarm edge.
                const epsilon = Math.min(1e-7, (span / 2 * step - prewarmEdge) / step / 2);
                const before = logic.signedDistance(0, span / 2 - epsilon, span);
                const after = logic.signedDistance(0, span / 2 + epsilon, span);
                assert.ok(before < 0 && after > 0);
                assert.ok(Math.abs(before * step) > prewarmEdge);
                assert.ok(Math.abs(after * step) > prewarmEdge);
                for (let position = -span; position <= span; position++) {
                    const selectedSlot = logic.wrapIndex(position, span);
                    assert.equal(selectedSlot % count, logic.wrapIndex(position, count));
                }
            }
        }
    }
});

test("carousel span handles an exact prewarm-boundary ratio strictly", () => {
    const width = 560;
    const screen = 6 * (0.86 * width + 24) - 2 * width;
    assert.equal(logic.carouselSpan(2, screen, width), 8);
});

test("MRU sorting is stable, preserves active records and does not mutate inputs", () => {
    const windows = [client("active", 0), client("third", 3), client("previous", 1),
        client("tie-one", 2), client("tie-two", 2), client("unknown", undefined),
        client("negative", -1), client("also-active", 0)];
    const before = JSON.stringify(windows);
    windows.forEach(Object.freeze);
    Object.freeze(windows);
    const ordered = logic.orderClients(windows);
    assert.deepEqual(Array.from(ordered, window => window.address),
        ["previous", "tie-one", "tie-two", "third", "unknown", "negative", "active", "also-active"]);
    assert.equal(JSON.stringify(windows), before);
    assert.notEqual(ordered, windows);
    assert.equal(ordered[0], windows[2]);
});

test("MRU includes pinned windows but omits unavailable and special-workspace clients", () => {
    const windows = [null, false, client("normal", 1), client("pinned", 2, { pinned: true }),
        client("unmapped", 3, { mapped: false }), client("hidden", 4, { hidden: true }),
        client("special-id", 5, { workspace: { id: -99, name: "parked" } }),
        client("special-name", 6, { workspace: { id: 10, name: "special:scratchpad" } }),
        client("legacy", undefined, { mapped: undefined })];
    assert.deepEqual(Array.from(logic.orderClients(windows), window => window.address),
        ["normal", "pinned", "legacy"]);
    for (const empty of [[], undefined, null, {}, "[]"]) {
        assert.equal(logic.orderClients(empty).length, 0);
    }
});

test("workspace grouping preserves MRU within numerically ordered workspaces", () => {
    const grouped = logic.groupByWorkspace([
        client("ten", 1, { workspace: { id: 10, name: "Ten" } }),
        client("two-first", 2, { workspace: { id: 2, name: "Two" } }),
        client("two-second", 3, { workspace: { id: 2, name: "Two" } })
    ]);
    assert.deepEqual(Array.from(grouped, group => group.id), [2, 10]);
    assert.deepEqual(Array.from(grouped[0].entries, window => window.address), ["two-first", "two-second"]);
});

test("icon cascade tolerates absent classes and preserves desktop-entry preference", () => {
    const desktop = { byId: id => id === "known" ? { icon: "known-icon" } : null,
        applications: { values: [{ name: "Mail", startupClass: "MAIL", icon: "mail-icon" }] } };
    const quickshell = { iconPath: (name, check) => {
        assert.equal(check, true, "Only checked lookups can detect missing theme icons");
        return ["known-icon", "mail-icon", "application-x-executable"].includes(name) ? `icon:${name}` : "";
    } };
    assert.equal(logic.iconPathFor(desktop, quickshell, null, null), "icon:application-x-executable");
    assert.equal(logic.iconPathFor(desktop, quickshell, "known", "Mail"), "icon:known-icon");
    assert.equal(logic.iconPathFor(desktop, quickshell, "mail", ""), "icon:mail-icon");
    assert.equal(logic.iconPathFor(desktop, quickshell, undefined, "Mail inbox"), "icon:mail-icon");
});

test("missing desktop icons continue the cascade and never use unchecked checkerboards", () => {
    const desktop = { byId: id => id === "missing" ? { icon: "not-installed" } : null,
        applications: { values: [{ startupClass: "missing", icon: "valid-alternate" }] } };
    const quickshell = { iconPath: (name, check) => {
        assert.equal(check, true);
        return name === "valid-alternate" ? "icon:alternate" : "";
    } };
    assert.equal(logic.iconPathFor(desktop, quickshell, "missing", ""), "icon:alternate");
    assert.equal(logic.iconPathFor(desktop, quickshell, "totally-missing", ""), "");
});
