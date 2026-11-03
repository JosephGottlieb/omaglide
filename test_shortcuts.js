const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const test = require('node:test');
const shortcuts = vm.createContext({});
vm.runInContext(fs.readFileSync(require('node:path').join(__dirname, 'shortcuts.js'), 'utf8').replace(/^\.pragma library/m, ''), shortcuts);
const id = 'hjklcc.omaglide';
test('labels backtick bindings clearly, including the shifted keysym', () => {
    assert.equal(shortcuts.chord({key: 'grave', modmask: 8}), 'Alt+Backtick');
    assert.equal(shortcuts.chord({key: 'grave', modmask: 9}), 'Alt+Shift+Backtick');
    assert.equal(shortcuts.chord({key: 'asciitilde', modmask: 9}), 'Alt+Shift+Backtick');
});
const bind = (action, extra = {}) => ({dispatcher: 'global', arg: id + ':' + action, key: 'TAB', modmask: 8, ...extra});
test('formats native global targets, modifiers and alternate bindings', () => {
    assert.equal(shortcuts.summarize([bind('next'), bind('previous', {modmask: 9}), bind('workspaces', {modmask: 68})], id),
        'Switch: Alt+Tab   ·   Previous: Alt+Shift+Tab   ·   Workspaces: Super+Ctrl+Tab');
});
test('recognizes opaque Lua callbacks by known descriptions, not numeric IDs', () => {
    const b = bind('next', {dispatcher: '__lua', arg: '76', description: 'OmaGlide: switch windows (W for workspaces)'});
    assert.equal(shortcuts.summarize([b], id), 'Switch: Alt+Tab');
    assert.equal(shortcuts.summarize([{...b, description: 'Something else'}], id), '');
    assert.equal(shortcuts.summarize([{...b, description: 'OmaGlide workspaces'}], id), 'Workspaces: Alt+Tab');
    // Runtime `hyprctl eval` binds report their dispatcher differently.
    assert.equal(shortcuts.summarize([{...b, dispatcher: 'HL.Dispatcher(global)', description: 'OmaGlide: slider'}], id), 'Slider: Alt+Tab');
    assert.equal(shortcuts.summarize([{...b, dispatcher: 'exec', description: 'OmaGlide: slider'}], id), '');
});
test('describes the Alt+Tab, Exposé and persistent toggle bindings', () => {
    const b = bind('next', {dispatcher: '__lua', arg: '76'});
    assert.equal(shortcuts.summarize([
        {...b, description: 'OmaGlide: switch windows (Backtick for workspaces)'},
        {...b, key: 'grave', description: 'OmaGlide: Exposé'},
        {...b, key: 'G', modmask: 68, description: 'OmaGlide: toggle switcher'},
    ], id), 'Switch: Alt+Tab   ·   Slider: Super+Ctrl+G   ·   Exposé: Alt+Backtick');
    assert.equal(shortcuts.summarize([bind('expose', {key: 'grave'})], id), 'Exposé: Alt+Backtick');
});
test('deduplicates and ignores unrelated targets and inactive submaps', () => {
    assert.equal(shortcuts.summarize([bind('next'), bind('next'), bind('hide'), bind('next', {arg: 'other:next'}),
        bind('next', {submap: 'resize'}), bind('next', {mouse: true}), bind('next', {catch_all: true}), null], id), 'Switch: Alt+Tab');
});
test('reflects rebinding/removal without retaining stale shortcuts', () => {
    assert.equal(shortcuts.summarize([bind('next', {key: 'space', modmask: 64})], id), 'Switch: Super+Space');
    assert.equal(shortcuts.summarize([], id), '');
    assert.throws(() => shortcuts.summarize({}, id));
});
test('shows keycode and release bindings explicitly', () => {
    assert.equal(shortcuts.chord({keycode: 23, modmask: 4, release: true}), 'Ctrl+Keycode 23 (release)');
});

const Qt = {Shift: 0x02000000, Control: 0x04000000, Alt: 0x08000000, Meta: 0x10000000};
test('normalizes Hyprland chords into one canonical spelling', () => {
    assert.equal(shortcuts.normalizeChord('ctrl+super + g'), 'SUPER + CTRL + G');
    assert.equal(shortcuts.normalizeChord('ALT + grave'), 'ALT + grave');
    assert.equal(shortcuts.normalizeChord('SUPER + code:49'), 'SUPER + code:49');
    for (const bad of ['', 'ALT +', 'HYPER + X', 'ALT + a b', 'ALT + "x"', null]) assert.equal(shortcuts.normalizeChord(bad), '');
    assert.equal(shortcuts.chordFromBinding({key: 'G', modmask: 68}), 'SUPER + CTRL + G');
    assert.equal(shortcuts.chordFromBinding({key: 'x', keycode: 23, modmask: 8}), 'ALT + code:23');
    assert.equal(shortcuts.displayChord('SUPER + CTRL + G'), 'Super+Ctrl+G');
    assert.equal(shortcuts.displayChord('ALT + grave'), 'Alt+`');
});
test('captures chords from Qt key events, folding shifted symbols to base keys', () => {
    assert.deepEqual({...shortcuts.chordFromKey(0x47, Qt.Meta | Qt.Control, 42)}, {chord: 'SUPER + CTRL + G', pending: false});
    assert.equal(shortcuts.chordFromKey(0x7e, Qt.Alt | Qt.Shift, 49).chord, 'ALT + SHIFT + grave');
    assert.equal(shortcuts.chordFromKey(0x60, Qt.Alt, 49).chord, 'ALT + grave');
    assert.equal(shortcuts.chordFromKey(0x01000002, Qt.Alt | Qt.Shift, 23).chord, 'ALT + SHIFT + Tab');
    assert.equal(shortcuts.chordFromKey(0x01000031, Qt.Meta, 0).chord, 'SUPER + F2');
    assert.equal(shortcuts.chordFromKey(0x20, Qt.Meta, 65).chord, 'SUPER + space');
    assert.equal(shortcuts.chordFromKey(0x01000023, Qt.Alt, 64).pending, true);
    assert.equal(shortcuts.chordFromKey(0x00e9, Qt.Alt, 26).chord, 'ALT + code:26');
});
test('reports conflicts with other shortcuts but not the action itself', () => {
    const live = [bind('expose', {key: 'grave'}),
        {dispatcher: '__lua', arg: '9', key: 'TAB', modmask: 8, description: 'OmaSwitch'},
        {dispatcher: '__lua', arg: '9', key: 'ALT_L', modmask: 0, release: true, description: 'OmaGlide: confirm selection'}];
    assert.equal(shortcuts.conflictFor('ALT + TAB', live, id, 'next'), 'OmaSwitch');
    assert.equal(shortcuts.conflictFor('ALT + grave', live, id, 'expose'), '');
    assert.equal(shortcuts.conflictFor('ALT + grave', live, id, 'toggle'), 'OmaGlide Exposé');
    assert.equal(shortcuts.conflictFor('SUPER + F9', live, id, 'toggle'), '');
});
test('generates Lua that moves only managed actions and keeps the rest', () => {
    const live = [bind('expose', {key: 'grave'}), bind('toggle', {key: 'G', modmask: 68})];
    const lua = shortcuts.bindingLua(id, {expose: 'SUPER + E', next: ''}, live);
    assert.match(lua, /hl\.unbind\("ALT \+ grave"\)/);
    assert.match(lua, /hl\.bind\("SUPER \+ E", hl\.dsp\.global\("hjklcc\.omaglide:expose"\), \{ description = "OmaGlide: Exposé" \}\)/);
    assert.doesNotMatch(lua, /SUPER \+ CTRL \+ G/);
    assert.equal(shortcuts.bindingLua(id, {expose: 'ALT + grave'}, live), '');
    assert.match(shortcuts.bindingLua(id, {next: 'ALT + TAB'}, []), /repeating = true/);
    assert.match(shortcuts.blurLua(id, true, true), /namespace = "\^hjklcc\[\.\]omaglide\$"/);
});

test('recognizes App Exposé bindings separately from Exposé', () => {
    const b = bind('next', {dispatcher: '__lua', arg: '7', key: 'grave', modmask: 72});
    assert.equal(shortcuts.summarize([{...b, description: 'OmaGlide: App Exposé'}, {...b, modmask: 8, description: 'OmaGlide: Exposé'}], id),
        'Exposé: Alt+Backtick   ·   App Exposé: Super+Alt+Backtick');
    assert.match(shortcuts.bindingLua(id, {appExpose: 'SUPER + A'}, []), /hjklcc\.omaglide:appExpose/);
});
test('gesture Lua adds swipes once and asks for a reload to change them', () => {
    const lua = shortcuts.gestureLua(id, true, 3);
    assert.match(lua, /fingers = 3, direction = "up", disable_inhibit = true, action = function\(\) hl\.dispatch\(hl\.dsp\.global\("hjklcc\.omaglide:gesture-up"\)\)/);
    assert.match(lua, /direction = "down"/);
    // Exit swipes must still fire while OmaGlide's shortcut inhibitor is active.
    assert.equal((lua.match(/disable_inhibit = true/g) || []).length, 2);
    assert.match(lua, /local want = "3\+ni"/);
    assert.match(lua, /if have ~= "off" then return "reload" end/);
    assert.doesNotMatch(lua, /unset/);
    assert.match(shortcuts.gestureLua(id, true, 4), /fingers = 4/);
    assert.match(shortcuts.gestureLua(id, true, 7), /fingers = 3/);
    const off = shortcuts.gestureLua(id, false, 4);
    assert.match(off, /local want = "off"/);
    assert.doesNotMatch(off, /hl\.gesture/);
    assert.deepEqual(Array.from(shortcuts.gestureConflicts('x: Previous UP shadows new UP')), ['up']);
    assert.deepEqual(Array.from(shortcuts.gestureConflicts('')), []);
});
