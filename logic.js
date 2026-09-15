// Pure logic for the task switcher — no Quickshell imports so it stays testable.
.pragma library

// Numeric settings may arrive from JSON or IPC as strings. Treat absent and
// non-finite values as missing instead of allowing NaN into QML geometry.
function finiteNumber(value) {
    if (typeof value !== "number" && typeof value !== "string") return NaN;
    if (typeof value === "string" && !value.trim()) return NaN;
    const number = Number(value);
    return Number.isFinite(number) ? number : NaN;
}

function clamp(value, min, max, fallback) {
    let lower = finiteNumber(min);
    let upper = finiteNumber(max);
    if (!Number.isFinite(lower)) lower = 0;
    if (!Number.isFinite(upper)) upper = lower;
    if (lower > upper) {
        const previous = lower;
        lower = upper;
        upper = previous;
    }
    let result = finiteNumber(value);
    if (!Number.isFinite(result)) result = finiteNumber(fallback);
    if (!Number.isFinite(result)) result = lower;
    return Math.max(lower, Math.min(upper, result));
}

// Preserve fractional positions: the same ring arithmetic drives animation
// between tiles as well as keyboard selection. Empty rings always resolve to 0.
function wrapIndex(value, count) {
    const size = Math.floor(finiteNumber(count));
    const position = finiteNumber(value);
    if (!(size > 0) || !Number.isFinite(position)) return 0;
    return ((position % size) + size) % size;
}

// Shortest signed distance from the animated center to a window in the ring.
// Exactly opposite tiles use the positive/right side deterministically.
function signedDistance(index, position, count) {
    const size = Math.floor(finiteNumber(count));
    if (!(size > 1)) return 0;
    const origin = finiteNumber(position);
    const destination = finiteNumber(index);
    if (!Number.isFinite(origin) || !Number.isFinite(destination)) return 0;
    const distance = wrapIndex(destination - origin, size);
    return distance > size / 2 ? distance - size : distance;
}

// The preferred width is persistent; only its effective rendered size is
// constrained by the current screen. A 16:10 preview leaves 180 px for the
// footer, title, hints and margins. Very small displays may go below 240 px.
function effectiveTileWidth(preferred, screenWidth, screenHeight) {
    const width = clamp(preferred, 240, 1200, 560);
    const viewportWidth = clamp(screenWidth, 1, 100000, 1920);
    const viewportHeight = clamp(screenHeight, 1, 100000, 1080);
    const availableWidth = Math.max(1, viewportWidth - 64);
    const availableHeight = Math.max(1, viewportHeight - 180);
    return Math.min(width, availableWidth, availableHeight * 16 / 10);
}

// Height is PREVIEW height, not the card's caption/footer. QML adds its footer.
// Adjacent full/small cards are separated by 24 px at integer positions; the
// center smoothly grows while its neighbour smoothly shrinks during a cycle.
function cardGeometry(distance, tileWidth) {
    const safeDistance = Number.isFinite(finiteNumber(distance)) ? Number(distance) : 0;
    const baseWidth = clamp(tileWidth, 1, 1200, 560);
    const emphasis = Math.max(0, 1 - Math.abs(safeDistance));
    const width = baseWidth * (0.72 + 0.28 * emphasis);
    return {
        width: width,
        height: width * 10 / 16,
        offset: safeDistance * (0.86 * baseWidth + 24),
        emphasis: emphasis
    };
}

// Only mount the visible slots plus one prewarmed slot outside each edge.
// Independent of total window count, so large rings do not capture every app.
function visibleRadius(screenWidth, tileWidth) {
    const viewportWidth = clamp(screenWidth, 1, 100000, 1920);
    const width = clamp(tileWidth, 1, 1200, 560);
    const step = 0.86 * width + 24;
    return Math.ceil((viewportWidth / 2 + width / 2) / step) + 1;
}

// Repeat short window lists into a longer ring so the shortest-distance seam
// always recycles fully offscreen, beyond even the one-card prewarm margin.
// QML maps each logical slot back to windows[slot % windows.length]. A single
// window deliberately remains one centered tile, never repeated wallpaper.
function carouselSpan(count, screenWidth, tileWidth) {
    const size = Math.floor(finiteNumber(count));
    if (!(size > 0)) return 0;
    if (size === 1) return 1;
    const viewportWidth = clamp(screenWidth, 1, 100000, 1920);
    const width = clamp(tileWidth, 1, 1200, 560);
    const step = 0.86 * width + 24;
    // Strictly greater, including exact boundary matches at integer ratios.
    const minimum = Math.floor((viewportWidth + 2 * width) / step) + 1;
    return size * Math.ceil(minimum / size);
}

// MRU order of newly fetched clients: the currently focused window (fhid 0)
// goes to the end so the first selection is the previously focused window.
// Unknown history goes after valid history but before the active window.
// Pinned windows are real windows and stay available; explicitly hidden,
// unmapped and special-workspace clients do not. Never mutate the IPC result.
function orderClients(clients) {
    if (!Array.isArray(clients)) return [];
    const rest = [];
    const active = [];

    for (let index = 0; index < clients.length; index++) {
        const c = clients[index];
        if (!c || typeof c !== "object" || c.mapped === false || c.hidden === true) continue;
        const workspace = c.workspace || {};
        if (Number(workspace.id) < 0 || /^special(?::|$)/.test(String(workspace.name || ""))) continue;
        const fhid = finiteNumber(c.focusHistoryID);
        if (fhid === 0) {
            active.push(c);
            continue;
        }
        rest.push({ client: c, history: fhid > 0 ? fhid : Infinity, index: index });
    }

    rest.sort((a, b) => {
        if (a.history !== b.history) return a.history < b.history ? -1 : 1;
        return a.index - b.index;
    });
    return rest.map(entry => entry.client).concat(active);
}

// Group the cycle-ordered windows by workspace (ascending id), preserving the
// global MRU order within each workspace. Returns [{ id, name, entries }].
function groupByWorkspace(ordered) {
    const groups = [];
    const map = Object.create(null);

    for (const c of (ordered || [])) {
        if (!c || !c.workspace) continue;
        const wsId = c.workspace.id;
        if (!(wsId in map)) {
            map[wsId] = { id: wsId, name: c.workspace.name, entries: [] };
            groups.push(map[wsId]);
        }
        map[wsId].entries.push(c);
    }

    groups.sort((a, b) => a.id - b.id);
    return groups;
}

// Icon cascade: desktop entry by id variants -> StartupWMClass scan ->
// app Name-substring-of-title scan (Chrome PWAs) -> icon theme variants ->
// generic. Mirrors the icon resolution pattern used elsewhere in Omarchy.
function iconPathFor(DesktopEntries, Quickshell, cls, title) {
    cls = String(cls || "");
    const clsLower = cls.toLowerCase();
    for (const v of [cls, clsLower, cls.replace(/-/g, ""), cls.split(".")[0]]) {
        if (!v) continue;
        const e = DesktopEntries.byId(v);
        if (e && e.icon) {
            const path = Quickshell.iconPath(e.icon, true);
            if (path) return path;
        }
    }

    const all = DesktopEntries.applications.values;
    for (const e of all) {
        if (e.startupClass && e.startupClass.toLowerCase() === clsLower && e.icon) {
            const path = Quickshell.iconPath(e.icon, true);
            if (path) return path;
        }
    }

    const titleLower = String(title || "").toLowerCase();
    if (titleLower) {
        for (const e of all) {
            const n = String(e.name || "").toLowerCase();
            if (n && titleLower.includes(n) && e.icon) {
                const path = Quickshell.iconPath(e.icon, true);
                if (path) return path;
            }
        }
    }

    for (const v of [cls, clsLower, cls.split("-")[0], cls.split(".").pop()]) {
        if (!v) continue;
        const p = Quickshell.iconPath(v, true);
        if (p) return p;
    }

    // Unchecked lookups return a valid magenta checkerboard pixmap on failure,
    // so Image.status cannot detect them. Empty source enables our text fallback.
    return Quickshell.iconPath("application-x-executable", true);
}
