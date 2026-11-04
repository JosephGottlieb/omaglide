.pragma library

// Actions OmaGlide can own. Descriptions double as the recognition key:
// hyprctl reports Lua dispatchers opaquely, so a binding made with
// hl.dsp.global() is only identifiable by its description.
const ACTIONS = [
    { id: "expose", label: "Exposé", hint: "Show every window at once",
        description: "OmaGlide: Exposé", repeating: false },
    { id: "appExpose", label: "App Exposé", hint: "Every window of the current app",
        description: "OmaGlide: App Exposé", repeating: false },
    { id: "toggle", label: "Slider", hint: "Open or dismiss the carousel",
        description: "OmaGlide: slider", repeating: false },
    { id: "next", label: "Hold to switch", hint: "Hold the modifier, release to switch",
        description: "OmaGlide: switch windows", repeating: true },
    { id: "previous", label: "Hold to switch back", hint: "Same, in the opposite direction",
        description: "OmaGlide: previous window", repeating: true }
];
const ACTION_IDS = ["next", "previous", "workspaces", "toggle", "expose", "appExpose"];

function actionFor(binding, appId) {
    const arg = String(binding.arg || "").trim();
    if (binding.dispatcher === "global" && arg.indexOf(appId + ":") === 0) {
        const action = arg.slice(appId.length + 1);
        return ACTION_IDS.indexOf(action) >= 0 ? action : "";
    }
    // Config-file Lua binds report "__lua"; binds made at runtime through
    // `hyprctl eval` (including OmaGlide's own) report "HL.Dispatcher(global)".
    const dispatcher = String(binding.dispatcher || "");
    if (dispatcher !== "__lua" && !/^HL\.Dispatcher\(/.test(dispatcher)) return "";
    const description = String(binding.description || "").trim().toLowerCase();
    if (/^omaglide(?::)? (switch windows(?: \((?:w|backtick) for workspaces\))?|windows)$/.test(description)) return "next";
    if (/^omaglide(?::)? previous window$/.test(description)) return "previous";
    if (/^omaglide(?::)? (workspaces|switch workspaces)$/.test(description)) return "workspaces";
    if (/^omaglide(?::)? (toggle(?: switcher)?|slider|carousel)$/.test(description)) return "toggle";
    if (/^omaglide(?::)? expos[eé]$/.test(description)) return "expose";
    if (/^omaglide(?::)? app expos[eé]$/.test(description)) return "appExpose";
    return "";
}

const MODIFIERS = [[64, "SUPER"], [4, "CTRL"], [8, "ALT"], [1, "SHIFT"]];
const KEY_ALIASES = { tab: "Tab", space: "Space", return: "Enter", escape: "Esc",
    left: "←", right: "→", up: "↑", down: "↓", grave: "`", asciitilde: "`",
    minus: "-", equal: "=", bracketleft: "[", bracketright: "]", backslash: "\\",
    semicolon: ";", apostrophe: "'", comma: ",", period: ".", slash: "/",
    backspace: "Backspace", delete: "Delete", prior: "PgUp", next: "PgDn" };

// Hyprland's own chord syntax ("SUPER + CTRL + G"), canonically ordered so two
// spellings of the same chord compare equal. Returns "" for anything invalid.
function normalizeChord(text) {
    const parts = String(text || "").split("+").map(p => p.trim());
    if (parts.some(p => !p)) return "";
    const key = parts.pop();
    if (!/^(?:[A-Za-z0-9_]+|code:\d+)$/.test(key) || MODIFIERS.some(m => m[1] === key.toUpperCase())) return "";
    const mods = [];
    for (const part of parts) {
        const upper = part.toUpperCase().replace(/^(?:CONTROL)$/, "CTRL").replace(/^(?:META|WIN|LOGO|MOD4)$/, "SUPER")
            .replace(/^MOD1$/, "ALT");
        if (!MODIFIERS.some(m => m[1] === upper)) return "";
        if (mods.indexOf(upper) < 0) mods.push(upper);
    }
    const ordered = MODIFIERS.map(m => m[1]).filter(m => mods.indexOf(m) >= 0);
    const canonicalKey = /^code:/.test(key) ? key : key.length === 1 ? key.toUpperCase() : key;
    return ordered.concat([canonicalKey]).join(" + ");
}

function chordFromBinding(binding) {
    if (!binding) return "";
    const mask = Number(binding.modmask) || 0;
    const mods = MODIFIERS.filter(m => mask & m[0]).map(m => m[1]);
    const key = binding.keycode ? "code:" + binding.keycode : String(binding.key || "");
    return key ? normalizeChord(mods.concat([key]).join(" + ")) : "";
}

// Human label for a canonical chord: "SUPER + CTRL + G" -> "Super+Ctrl+G".
function displayChord(chordText) {
    const chordValue = normalizeChord(chordText);
    if (!chordValue) return "";
    const parts = chordValue.split(" + ");
    const key = parts.pop();
    const label = /^code:/.test(key) ? "Keycode " + key.slice(5)
        : KEY_ALIASES[key.toLowerCase()] || (key.length === 1 ? key.toUpperCase() : key);
    return parts.map(m => m.charAt(0) + m.slice(1).toLowerCase()).concat([label]).join("+");
}

function chord(binding) {
    const mask = Number(binding.modmask) || 0;
    const parts = [];
    [[64, "Super"], [4, "Ctrl"], [8, "Alt"], [1, "Shift"],
        [2, "Caps"], [16, "Mod2"], [32, "Mod3"], [128, "Mod5"]].forEach(pair => {
        if (mask & pair[0]) parts.push(pair[1]);
    });
    const key = String(binding.key || "");
    const aliases = { tab: "Tab", space: "Space", return: "Enter", escape: "Esc",
        left: "←", right: "→", up: "↑", down: "↓", grave: "Backtick", asciitilde: "Backtick" };
    parts.push(binding.keycode ? "Keycode " + binding.keycode : (aliases[key.toLowerCase()] || key.toUpperCase()));
    return parts.join("+") + (binding.release ? " (release)" : "");
}

function summarize(bindings, appId) {
    const found = { next: [], previous: [], workspaces: [], toggle: [], expose: [], appExpose: [] };
    if (!Array.isArray(bindings)) throw new Error("Expected a keybinding array");
    bindings.forEach(binding => {
        if (!usable(binding)) return;
        const action = actionFor(binding, appId);
        if (!action) return;
        const label = chord(binding);
        if (found[action].indexOf(label) < 0) found[action].push(label);
    });
    const labels = { next: "Switch", previous: "Previous", workspaces: "Workspaces", toggle: "Slider",
        expose: "Exposé", appExpose: "App Exposé" };
    return Object.keys(found).filter(action => found[action].length)
        .map(action => labels[action] + ": " + found[action].join(" / ")).join("   ·   ");
}

function usable(binding) {
    return !!binding && !binding.mouse && !binding.catch_all && !binding.submap && !binding.release
        && !!(binding.key || binding.keycode);
}

// Canonical chords currently bound to each action, from `hyprctl -j binds`.
function currentChords(bindings, appId) {
    const found = {};
    for (const action of ACTION_IDS) found[action] = [];
    (Array.isArray(bindings) ? bindings : []).forEach(binding => {
        if (!usable(binding)) return;
        const action = actionFor(binding, appId);
        const value = action ? chordFromBinding(binding) : "";
        if (value && found[action].indexOf(value) < 0) found[action].push(value);
    });
    return found;
}

// What else already uses this chord, so the settings panel can warn before
// replacing it. OmaGlide's own binding for the same action is not a conflict.
function conflictFor(chordText, bindings, appId, action) {
    const wanted = normalizeChord(chordText);
    if (!wanted) return "";
    for (const binding of Array.isArray(bindings) ? bindings : []) {
        if (!usable(binding) || chordFromBinding(binding) !== wanted) continue;
        const owner = actionFor(binding, appId);
        if (owner === action) continue;
        if (owner) return "OmaGlide " + (ACTIONS.find(a => a.id === owner) || { label: owner }).label;
        return String(binding.description || "").trim()
            || (String(binding.dispatcher || "") + " " + String(binding.arg || "")).trim() || "another shortcut";
    }
    return "";
}

// Qt key codes and modifier flags (Qt::Key, Qt::KeyboardModifier). Kept here
// so capture stays testable outside QML.
const QT = { Shift: 0x02000000, Control: 0x04000000, Alt: 0x08000000, Meta: 0x10000000 };
const QT_MODIFIER_KEYS = [0x01000020, 0x01000021, 0x01000022, 0x01000023, 0x01001103,
    0x01000053, 0x01000054, 0x01000024, 0x01000025, 0x01000026, 0x01000055, 0x01000056];
const QT_NAMED = { 0x01000001: "Tab", 0x01000002: "Tab", 0x01000003: "BackSpace", 0x01000004: "Return",
    0x01000005: "Return", 0x01000006: "Insert", 0x01000007: "Delete", 0x01000008: "Pause",
    0x01000009: "Print", 0x01000010: "Home", 0x01000011: "End", 0x01000012: "Left",
    0x01000013: "Up", 0x01000014: "Right", 0x01000015: "Down", 0x01000016: "Prior",
    0x01000017: "Next", 0x20: "space" };
// US-layout punctuation, with shifted symbols folded back to their base key:
// Hyprland matches the unshifted keysym plus SHIFT.
const QT_PUNCTUATION = { "`": "grave", "~": "grave", "-": "minus", "_": "minus", "=": "equal", "+": "equal",
    "[": "bracketleft", "{": "bracketleft", "]": "bracketright", "}": "bracketright",
    "\\": "backslash", "|": "backslash", ";": "semicolon", ":": "semicolon",
    "'": "apostrophe", "\"": "apostrophe", ",": "comma", "<": "comma", ".": "period", ">": "period",
    "/": "slash", "?": "slash", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6",
    "&": "7", "*": "8", "(": "9", ")": "0" };

// Returns { chord, pending } — pending while only modifiers are held.
function chordFromKey(key, modifiers, nativeScanCode) {
    const mods = [];
    if (modifiers & QT.Meta) mods.push("SUPER");
    if (modifiers & QT.Control) mods.push("CTRL");
    if (modifiers & QT.Alt) mods.push("ALT");
    if (modifiers & QT.Shift || key === 0x01000002) mods.push("SHIFT");
    if (QT_MODIFIER_KEYS.indexOf(key) >= 0) return { chord: "", pending: true };
    let name = "";
    if (key >= 0x41 && key <= 0x5a) name = String.fromCharCode(key);
    else if (key >= 0x30 && key <= 0x39) name = String.fromCharCode(key);
    else if (key >= 0x01000030 && key <= 0x01000052) name = "F" + (key - 0x01000030 + 1);
    else if (QT_NAMED[key]) name = QT_NAMED[key];
    else if (key > 0x20 && key < 0x7f) name = QT_PUNCTUATION[String.fromCharCode(key)] || "";
    if (!name && nativeScanCode > 0) name = "code:" + nativeScanCode;
    return { chord: name ? normalizeChord(mods.concat([name]).join(" + ")) : "", pending: false };
}

function luaString(value) {
    // Chords are validated ASCII; JSON string escapes are valid Lua for them.
    return JSON.stringify(String(value));
}

// Lua for `hyprctl eval`: drop whatever chords each managed action uses now,
// free the requested chord, then bind it. Unmanaged actions are untouched.
function bindingLua(appId, desired, bindings) {
    const current = currentChords(bindings, appId);
    const lines = [];
    const guard = statement => lines.push("pcall(function() " + statement + " end)");
    for (const action of ACTIONS) {
        if (!Object.prototype.hasOwnProperty.call(desired || {}, action.id)) continue;
        const target = normalizeChord(desired[action.id]);
        for (const existing of current[action.id] || [])
            if (existing !== target) guard("hl.unbind(" + luaString(existing) + ")");
        if (!target || (current[action.id] || []).indexOf(target) >= 0) continue;
        guard("hl.unbind(" + luaString(target) + ")");
        guard("hl.bind(" + luaString(target) + ", hl.dsp.global(" + luaString(appId + ":" + action.id) + "), { description = "
            + luaString(action.description) + (action.repeating ? ", repeating = true" : "") + " })");
    }
    return lines.join("\n");
}

// Runtime layer rule for the overlay's frosted background. A config reload
// may discard runtime rules, so `fresh` retires any earlier handle (disabling
// it in case it survived) and creates a new rule.
function blurLua(appId, enabled, fresh) {
    const namespace = "^" + String(appId).replace(/[.]/g, "[.]") + "$";
    return "pcall(function()\n"
        + (fresh ? "  if _G.omaglide_blur_rule ~= nil then pcall(function() _G.omaglide_blur_rule:set_enabled(false) end); _G.omaglide_blur_rule = nil end\n" : "")
        + "  if _G.omaglide_blur_rule == nil then _G.omaglide_blur_rule = hl.layer_rule({ match = { namespace = "
        + luaString(namespace) + " }, blur = true, ignore_alpha = 0.01 }) end\n"
        + "  _G.omaglide_blur_rule:set_enabled(" + (enabled ? "true" : "false") + ")\n"
        + "end)";
}

// Touchpad swipes: up for Exposé, down for App Exposé. Hyprland can neither
// list gestures nor remove one safely (unset matches by fingers/direction,
// so it could remove someone else's). OmaGlide therefore only ever adds its
// gestures, once per config generation; a reload clears them, and Hyprland's
// Lua state with them. This returns, via `hyprctl repl`:
//   "same"       already registered as wanted
//   "registered" just added (check configerrors for a shadowing conflict)
//   "reload"     a different set is registered; reload, then apply again
// OmaGlide's own overlay inhibits compositor shortcuts while it is open,
// and Hyprland suppresses gestures under that inhibitor too, so the
// swipes that leave Exposé need disable_inhibit. The "+ni" revision marker
// makes sessions still holding the older swipes reload into these.
// The swipes are tracked: Hyprland calls start, update and finish while the
// fingers move and when they lift (its parser reads "finish" and silently
// ignores a field named "end"). Each call is forwarded as a custom socket event,
// "<appId>:swipe:<direction>:<phase>:<progress>", where progress is the
// distance travelled in the swipe's direction over Hyprland's own
// workspace_swipe_distance. The "+f" marker on the registration makes older
// ones (one-shot, or tracked without a working release) reload into this one.
function gestureLua(appId, enabled, fingers) {
    const count = Number(fingers) === 4 ? 4 : 3;
    const want = enabled ? count + "+ni+f" : "off";
    const lines = [
        "local want = " + luaString(want),
        "local have = _G.omaglide_gestures or \"off\"",
        "if have == want then return \"same\" end",
        "if have ~= \"off\" then return \"reload\" end",
        "_G.omaglide_gestures = want"
    ];
    if (enabled) {
        lines.push(
            "local function omaglide_swipe(direction, sign)",
            "  local travelled = 0",
            "  local function distance()",
            "    local ok, value = pcall(hl.get_config, \"gestures.workspace_swipe_distance\")",
            "    value = ok and tonumber(value) or nil",
            "    return value and value > 0 and value or 300",
            "  end",
            "  local function emit(phase)",
            "    hl.dispatch(hl.dsp.event(" + luaString(appId + ":swipe:") + " .. direction .. \":\" .. phase .. \":\"",
            "      .. string.format(\"%.4f\", travelled / distance())))",
            "  end",
            "  local function moved(event)",
            "    local delta = type(event) == \"table\" and event.delta or nil",
            "    local y = type(delta) == \"table\" and tonumber(delta.y or delta[2]) or 0",
            "    travelled = travelled + sign * (y or 0)",
            "  end",
            "  return {",
            "    start = function(event) travelled = 0; moved(event); emit(\"start\") end,",
            "    update = function(event) moved(event); emit(\"update\") end,",
            "    finish = function() emit(\"end\") end,",
            "  }",
            "end");
        // libinput reports upward motion as negative y.
        for (const [direction, sign] of [["up", -1], ["down", 1]])
            lines.push("hl.gesture({ fingers = " + count + ", direction = " + luaString(direction)
                + ", disable_inhibit = true, action = omaglide_swipe(" + luaString(direction) + ", " + sign + ") })");
    }
    lines.push("return \"registered\"");
    return lines.join("\n");
}

// Parses a tracked swipe event's data (see gestureLua); null for other events.
function parseSwipeEvent(appId, data) {
    const prefix = appId + ":swipe:";
    const text = String(data || "");
    if (text.indexOf(prefix) !== 0) return null;
    const parts = text.slice(prefix.length).split(":");
    const progress = Number(parts[2]);
    if (parts.length !== 3 || ["up", "down"].indexOf(parts[0]) < 0
        || ["start", "update", "end"].indexOf(parts[1]) < 0 || !isFinite(progress)) return null;
    return { direction: parts[0], phase: parts[1], progress: progress };
}

// Hyprland reports a gesture that an earlier one shadows only as a config
// error from that same evaluation, e.g. "Previous UP shadows new UP".
function gestureConflicts(configErrors) {
    const found = [];
    const text = String(configErrors || "");
    if (/shadows new UP/i.test(text)) found.push("up");
    if (/shadows new DOWN/i.test(text)) found.push("down");
    return found;
}
