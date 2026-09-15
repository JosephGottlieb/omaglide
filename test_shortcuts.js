const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const test = require('node:test');
const shortcuts = vm.createContext({});
vm.runInContext(fs.readFileSync(require('node:path').join(__dirname, 'shortcuts.js'), 'utf8').replace(/^\.pragma library/m, ''), shortcuts);
const id = 'hjklcc.omaglide';
const bind = (action, extra = {}) => ({dispatcher: 'global', arg: id + ':' + action, key: 'TAB', modmask: 8, ...extra});
test('formats native global targets, modifiers and alternate bindings', () => {
    assert.equal(shortcuts.summarize([bind('next'), bind('previous', {modmask: 9}), bind('workspaces', {modmask: 68})], id),
        'Windows: Alt+Tab   ·   Previous: Alt+Shift+Tab   ·   Workspaces: Super+Ctrl+Tab');
});
test('recognizes opaque Lua callbacks by known descriptions, not numeric IDs', () => {
    const b = bind('next', {dispatcher: '__lua', arg: '76', description: 'OmaGlide: switch windows (W for workspaces)'});
    assert.equal(shortcuts.summarize([b], id), 'Windows: Alt+Tab');
    assert.equal(shortcuts.summarize([{...b, description: 'Something else'}], id), '');
    assert.equal(shortcuts.summarize([{...b, description: 'OmaGlide workspaces'}], id), 'Workspaces: Alt+Tab');
});
test('deduplicates and ignores unrelated targets and inactive submaps', () => {
    assert.equal(shortcuts.summarize([bind('next'), bind('next'), bind('hide'), bind('next', {arg: 'other:next'}),
        bind('next', {submap: 'resize'}), bind('next', {mouse: true}), bind('next', {catch_all: true}), null], id), 'Windows: Alt+Tab');
});
test('reflects rebinding/removal without retaining stale shortcuts', () => {
    assert.equal(shortcuts.summarize([bind('next', {key: 'space', modmask: 64})], id), 'Windows: Super+Space');
    assert.equal(shortcuts.summarize([], id), '');
    assert.throws(() => shortcuts.summarize({}, id));
});
test('shows keycode and release bindings explicitly', () => {
    assert.equal(shortcuts.chord({keycode: 23, modmask: 4, release: true}), 'Ctrl+Keycode 23 (release)');
});
