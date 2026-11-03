// Pure logic for the task switcher — no Quickshell imports so it stays testable.
.pragma library

function filterEntries(entries, query) {
    const words = String(query || "").normalize("NFKD").replace(/[\u0300-\u036f]/g, "").toLowerCase().trim().split(/\s+/).filter(Boolean);
    if (!Array.isArray(entries)) return [];
    if (!words.length) return entries.slice();
    return entries.filter(entry => {
        const fields = [entry.title, entry.cls, entry.workspaceName, entry.workspaceId];
        for (const window of entry.windows || []) fields.push(window.title, window.cls,
            window.workspaceName, window.workspaceId);
        const haystack = fields.join(" ").normalize("NFKD").replace(/[\u0300-\u036f]/g, "").toLowerCase();
        return words.every(word => haystack.includes(word));
    });
}

// Exposé packs windows into centered rows by their real aspect ratios, like
// macOS Mission Control: every tile takes its window's shape (no letterbox
// cells), rows share one height, and MRU order reads left to right.
// Returns { rows: [[index]], cards: [{x, y, width, height, caption, cardHeight}], scale }
// where height is the PREVIEW height and the caption space sits below it.
function exposeAspect(value) {
    const ratio = finiteNumber(value);
    return Number.isFinite(ratio) && ratio > 0 ? clamp(ratio, 0.2, 6, 1.6) : 1.6;
}

function splitRows(ratios, rowCount) {
    const total = ratios.reduce((sum, ratio) => sum + ratio, 0);
    const rows = Array.from({ length: rowCount }, () => []);
    let accumulated = 0;
    ratios.forEach((ratio, index) => {
        const row = Math.min(rowCount - 1, Math.floor((accumulated + ratio / 2) / total * rowCount));
        rows[row].push(index);
        accumulated += ratio;
    });
    return rows.filter(row => row.length);
}

function exposeLayout(aspects, width, height, options) {
    const opts = options || {};
    const w = clamp(width, 1, 100000, 1440), h = clamp(height, 1, 100000, 800);
    const ratios = (Array.isArray(aspects) ? aspects : []).map(exposeAspect);
    const count = ratios.length;
    if (!count) return { rows: [], cards: [], rowHeight: 0 };
    const gap = clamp(opts.gap, 0, 200, Math.min(32, w / (count * 3), h / (count * 3)));
    // Captions never take more than a slice of tiny screens.
    const caption = Math.min(clamp(opts.caption, 0, 200, 0), h * 0.12);
    // A lone window should still read as a window on a desktop, not fill it.
    const maxHeight = clamp(opts.maxHeight, 1, 100000, h * 0.82);
    let best = null;
    for (let rowCount = 1; rowCount <= count; rowCount++) {
        const rows = splitRows(ratios, rowCount);
        const sums = rows.map(row => row.reduce((sum, index) => sum + ratios[index], 0));
        const widthLimit = Math.min.apply(null, rows.map((row, r) => (w - gap * (row.length - 1)) / sums[r]));
        const heightLimit = (h - gap * (rows.length - 1)) / rows.length - caption;
        const rowHeight = Math.min(widthLimit, heightLimit, maxHeight);
        if (!(rowHeight > 0)) continue;
        const area = rowHeight * rowHeight * sums.reduce((a, b) => a + b, 0);
        // Prefer fewer rows on ties: they keep the MRU reading order clearer.
        if (!best || area > best.area * 1.0001) best = { rows: rows, sums: sums, rowHeight: rowHeight, area: area };
    }
    if (!best) return { rows: [], cards: ratios.map(() => ({ x: 0, y: 0, width: 0, height: 0, caption: 0, cardHeight: 0 })), rowHeight: 0 };
    const cards = new Array(count);
    const blockHeight = best.rows.length * (best.rowHeight + caption) + (best.rows.length - 1) * gap;
    let y = (h - blockHeight) / 2;
    best.rows.forEach((row, r) => {
        let x = (w - best.sums[r] * best.rowHeight - (row.length - 1) * gap) / 2;
        for (const index of row) {
            const cardWidth = ratios[index] * best.rowHeight;
            cards[index] = { x: x, y: y, width: cardWidth, height: best.rowHeight,
                caption: caption, cardHeight: best.rowHeight + caption };
            x += cardWidth + gap;
        }
        y += best.rowHeight + caption + gap;
    });
    return { rows: best.rows, cards: cards, rowHeight: best.rowHeight };
}

// Up/Down in Exposé: the tile in the adjacent row whose center is nearest
// horizontally. Rows wrap, matching the carousel's ring navigation.
function exposeMove(layout, index, deltaRows) {
    const rows = layout && layout.rows || [];
    if (!rows.length) return 0;
    const current = rows.findIndex(row => row.indexOf(index) >= 0);
    if (current < 0) return rows[0][0];
    const target = rows[wrapIndex(current + deltaRows, rows.length)];
    const card = layout.cards[index];
    const center = card.x + card.width / 2;
    let best = target[0], distance = Infinity;
    for (const candidate of target) {
        const other = layout.cards[candidate];
        const d = Math.abs(other.x + other.width / 2 - center);
        if (d < distance) { distance = d; best = candidate; }
    }
    return best;
}

// Linear blend between two rectangles, used for the Exposé fly-in from each
// window's real desktop position into its tile.
function mixRect(from, to, progress) {
    const t = clamp(progress, 0, 1, 1);
    const mix = (a, b) => a + (b - a) * t;
    return { x: mix(from.x, to.x), y: mix(from.y, to.y),
        width: mix(from.width, to.width), height: mix(from.height, to.height) };
}

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

// App grouping is deliberately based on the complete class, not a prefix:
// browsers can give independently launched web apps their own distinct classes.
function appClassKey(cls) {
    return String(cls || "").normalize("NFKC").trim().toLowerCase();
}

// Accept the same MRU-ordered records used by the window carousel. Keep every
// native capture/activation field on the representative, while exposing all
// member windows for search and the window count. The current app goes last,
// just like the active window in orderClients(), so one forward step chooses
// the previous app rather than another window belonging to the current app.
function groupAppEntries(entries, activeAddress) {
    if (!Array.isArray(entries)) return [];
    const groups = [];
    const byClass = Object.create(null);
    let activeGroup = null;
    for (let index = 0; index < entries.length; index++) {
        const entry = entries[index];
        if (!entry || typeof entry !== "object" || Array.isArray(entry)) continue;
        const cls = appClassKey(entry.cls);
        // An absent class is not evidence that two windows belong to one app.
        const appKey = cls ? "app:" + cls
            : "window:" + (entry.address || entry.key || index);
        let group = cls ? byClass[appKey] : null;
        if (!group) {
            group = { appKey: appKey, representative: entry, windows: [] };
            if (cls) byClass[appKey] = group;
            groups.push(group);
        }
        group.windows.push(entry);
        if (activeAddress && entry.address === activeAddress) {
            group.representative = entry;
            activeGroup = group;
        }
    }
    if (activeGroup) {
        groups.splice(groups.indexOf(activeGroup), 1);
        groups.push(activeGroup);
    }
    return groups.map(group => Object.assign({}, group.representative, {
        key: group.appKey,
        appKey: group.appKey,
        grouped: true,
        count: group.windows.length,
        windows: group.windows
    }));
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
