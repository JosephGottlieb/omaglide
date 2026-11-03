// Run: node --test test_expose_geometry.js.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const test = require("node:test");

const source = fs.readFileSync(path.join(__dirname, "logic.js"), "utf8")
    .replace(/^\s*\.pragma library\s*$/m, "");
const logic = vm.createContext({});
vm.runInContext(source, logic, { filename: "logic.js" });
const close = (actual, expected) => assert.ok(Math.abs(actual - expected) < 1e-6,
    `Expected ${actual} to be close to ${expected}`);
const overlaps = (a, b) => !(a.x + a.width <= b.x + 1e-6 || b.x + b.width <= a.x + 1e-6
    || a.y + a.cardHeight <= b.y + 1e-6 || b.y + b.cardHeight <= a.y + 1e-6);

test("every Exposé tile takes its window's exact shape, with no letterbox cell", () => {
    const aspects = [0.25, 9 / 16, 1, 16 / 10, 16 / 9, 32 / 9, 6];
    for (const [width, height] of [[36, 24], [300, 200], [736, 360], [836, 1480], [1376, 660], [3776, 1920]]) {
        for (const count of [1, 2, 3, 5, 12, 30, 100]) {
            const ratios = Array.from({ length: count }, (_, i) => aspects[i % aspects.length]);
            const layout = logic.exposeLayout(ratios, width, height, { caption: 30 });
            assert.equal(layout.cards.length, count);
            layout.cards.forEach((card, index) => {
                close(card.width / card.height, ratios[index]);
                close(card.height + card.caption, card.cardHeight);
                assert.ok(card.width > 0 && card.height > 0);
                assert.ok(card.x >= -1e-6 && card.y >= -1e-6);
                assert.ok(card.x + card.width <= width + 1e-6);
                assert.ok(card.y + card.cardHeight <= height + 1e-6);
            });
            for (let a = 0; a < count; a++) for (let b = a + 1; b < count; b++)
                assert.ok(!overlaps(layout.cards[a], layout.cards[b]), `tiles ${a} and ${b} overlap`);
            // Rows keep MRU order and cover every index exactly once.
            assert.deepEqual(Array.from(layout.rows.flat()), Array.from({ length: count }, (_, i) => i));
        }
    }
});

test("portrait and ultrawide windows are not shrunk into 16:10 cells", () => {
    const layout = logic.exposeLayout([9 / 16, 32 / 9], 1600, 900, { caption: 30 });
    const [portrait, wide] = layout.cards;
    close(portrait.height, wide.height);
    assert.ok(wide.width > 4 * portrait.width);
});

test("a lone window keeps a desktop margin and stays centered", () => {
    const layout = logic.exposeLayout([16 / 9], 1600, 900, { caption: 30 });
    const card = layout.cards[0];
    assert.ok(card.height <= 900 * 0.82 + 1e-6);
    close(card.x + card.width / 2, 800);
    close(card.y + card.cardHeight / 2, 450);
});

test("invalid source dimensions fall back to 16:10", () => {
    for (const ratio of [undefined, null, NaN, Infinity, -Infinity, "", "invalid", {}, true, 0, -1]) {
        const card = logic.exposeLayout([ratio, 1], 1376, 660).cards[0];
        close(card.width / card.height, 1.6);
        for (const value of Object.values(card)) assert.ok(Number.isFinite(value));
    }
    close(logic.exposeLayout(["0.75"], 1376, 660).cards[0].width / logic.exposeLayout(["0.75"], 1376, 660).cards[0].height, 0.75);
    assert.equal(logic.exposeLayout([], 100, 100).cards.length, 0);
});

test("Up/Down picks the horizontally nearest tile in the adjacent row and wraps", () => {
    const layout = logic.exposeLayout(Array(7).fill(1.6), 1400, 900);
    assert.ok(layout.rows.length >= 2);
    const first = layout.rows[0], second = layout.rows[1];
    const down = logic.exposeMove(layout, first[0], 1);
    assert.ok(second.indexOf(down) >= 0);
    const up = logic.exposeMove(layout, first[0], -1);
    assert.ok(layout.rows[layout.rows.length - 1].indexOf(up) >= 0);
    assert.equal(logic.exposeMove({ rows: [], cards: [] }, 3, 1), 0);
});

test("mixRect interpolates and clamps progress", () => {
    const from = { x: 0, y: 0, width: 100, height: 50 }, to = { x: 100, y: 50, width: 200, height: 150 };
    assert.deepEqual({ ...logic.mixRect(from, to, 0.5) }, { x: 50, y: 25, width: 150, height: 100 });
    assert.deepEqual({ ...logic.mixRect(from, to, 2) }, { ...to });
    assert.deepEqual({ ...logic.mixRect(from, to, -1) }, { ...from });
});
