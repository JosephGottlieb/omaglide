.pragma library

// hyprctl reports Lua dispatchers as opaque callback IDs. For those only,
// recognize the descriptions shipped by OmaGlide rather than guessing the ID.
function actionFor(binding, appId) {
    const arg = String(binding.arg || "").trim();
    if (binding.dispatcher === "global" && arg.indexOf(appId + ":") === 0) {
        const action = arg.slice(appId.length + 1);
        return ["next", "previous", "workspaces", "toggle"].indexOf(action) >= 0 ? action : "";
    }
    if (binding.dispatcher !== "__lua") return "";
    const description = String(binding.description || "").trim().toLowerCase();
    if (/^omaglide(?::)? (switch windows(?: \(w for workspaces\))?|windows)$/.test(description)) return "next";
    if (/^omaglide(?::)? previous window$/.test(description)) return "previous";
    if (/^omaglide(?::)? (workspaces|switch workspaces)$/.test(description)) return "workspaces";
    if (/^omaglide(?::)? toggle$/.test(description)) return "toggle";
    return "";
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
        left: "←", right: "→", up: "↑", down: "↓" };
    parts.push(binding.keycode ? "Keycode " + binding.keycode : (aliases[key.toLowerCase()] || key.toUpperCase()));
    return parts.join("+") + (binding.release ? " (release)" : "");
}

function summarize(bindings, appId) {
    const found = { next: [], previous: [], workspaces: [], toggle: [] };
    if (!Array.isArray(bindings)) throw new Error("Expected a keybinding array");
    bindings.forEach(binding => {
        if (!binding || binding.mouse || binding.catch_all || binding.submap || (!binding.key && !binding.keycode)) return;
        const action = actionFor(binding, appId);
        if (!action) return;
        const label = chord(binding);
        if (found[action].indexOf(label) < 0) found[action].push(label);
    });
    const labels = { next: "Windows", previous: "Previous", workspaces: "Workspaces", toggle: "Toggle" };
    return Object.keys(found).filter(action => found[action].length)
        .map(action => labels[action] + ": " + found[action].join(" / ")).join("   ·   ");
}
