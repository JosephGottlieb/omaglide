// Pure workspace composition; no IPC, screenshot capture, or QML dependencies.
.pragma library

function finite(value, fallback) {
    if (typeof value !== "number" && typeof value !== "string") return fallback;
    if (typeof value === "string" && !value.trim()) return fallback;
    const number = Number(value);
    return Number.isFinite(number) ? number : fallback;
}

// Hyprland regular numbered workspaces are positive; named regular workspaces
// use IDs <= -1337. Special workspaces occupy the reserved negative range
// beginning at -99, and are additionally recognizable by their name.
function isRegularWorkspace(workspace) {
    if (!workspace || typeof workspace !== "object") return false;
    const id = finite(workspace.id, NaN);
    return Number.isInteger(id) && (id > 0 || id <= -1337)
        && !/^special(?::|$)/.test(String(workspace.name || ""));
}

// hyprctl monitor width/height are physical mode pixels. at/size client data
// and monitor x/y already use compositor logical coordinates: never scale the
// clients again. Odd Wayland transforms swap the mode axes before scaling.
function monitorViewport(monitor) {
    const scaleValue = finite(monitor && monitor.scale, 1);
    const scale = scaleValue > 0 ? scaleValue : 1;
    const physicalWidth = finite(monitor && monitor.width, 1920);
    const physicalHeight = finite(monitor && monitor.height, 1080);
    const transform = finite(monitor && monitor.transform, 0);
    const rotated = Math.abs(transform % 2) === 1;
    return {
        x: 0, y: 0,
        width: Math.max(1, (rotated ? physicalHeight : physicalWidth) / scale),
        height: Math.max(1, (rotated ? physicalWidth : physicalHeight) / scale)
    };
}

// buildWorkspaces(clients, workspaces, monitors, handles = {}) -> entries[]
//
// Entries are sorted numerically by stable workspace ID. Workspaces without
// eligible windows are omitted, including active/persistent empty workspaces.
// Occupancy is evaluated after filtering clients and expanding pinned windows
// onto the existing workspaces of their monitor. Each entry contains:
//   key, workspaceId, workspaceName, title, cls, monitorName, active, count,
//   monitorViewport {x:0,y:0,width,height},
//   viewport {x,y,width,height}, windows[].
//
// Windows contain address, cls, title, x/y/width/height (logical coordinates
// relative to their workspace monitor), z, pinned, and handle (or null).
// `viewport` is the union of the monitor rectangle and all client rectangles:
// scrolling-layout clients can remain offscreen without being rearranged or
// cropped. Render each at (window.x - viewport.x, window.y - viewport.y) using
// one uniform scale. Background/wallpaper uses the monitorViewport rectangle.
//
// Keep hyprctl's bottom-to-top client ordering within tiled/floating/pinned
// layers. Focus history is not a stacking order and must not rearrange it.
function buildWorkspaces(clients, workspaces, monitors, handles) {
    const screens = (Array.isArray(monitors) ? monitors : []).filter(m => m && !m.disabled);
    const byId = Object.create(null);
    const records = [];
    const eligible = [];
    const seenClients = Object.create(null);

    function findMonitor(reference) {
        if (reference === undefined || reference === null || reference === "") return null;
        return screens.find(m => String(m.name) === String(reference))
            || screens.find(m => finite(m.id, NaN) === finite(reference, NaN)) || null;
    }
    function addWorkspace(workspace, monitor) {
        if (!isRegularWorkspace(workspace)) return null;
        const id = Number(workspace.id);
        if (byId[id]) {
            if (!byId[id].monitor && monitor) byId[id].monitor = monitor;
            return byId[id];
        }
        const record = { id: id, name: String(workspace.name || id), monitor: monitor || null,
            monitorName: typeof workspace.monitor === "string" ? workspace.monitor : "", clients: [] };
        byId[id] = record;
        records.push(record);
        return record;
    }

    for (const workspace of (Array.isArray(workspaces) ? workspaces : [])) {
        if (!workspace) continue;
        addWorkspace(workspace, findMonitor(workspace.monitor) || findMonitor(workspace.monitorID));
    }
    for (const monitor of screens) addWorkspace(monitor.activeWorkspace, monitor);

    for (let index = 0; index < (Array.isArray(clients) ? clients.length : 0); index++) {
        const client = clients[index];
        if (!client || client.mapped === false || client.hidden === true || !isRegularWorkspace(client.workspace)) continue;
        const address = String(client.address || "");
        if (!address || seenClients[address]) continue;
        const at = client.at || [];
        const size = client.size || [];
        const x = finite(at[0], NaN), y = finite(at[1], NaN);
        const width = finite(size[0], NaN), height = finite(size[1], NaN);
        if (![x, y, width, height].every(Number.isFinite) || width <= 0 || height <= 0) continue;
        seenClients[address] = true;
        const monitor = findMonitor(client.monitor);
        const record = addWorkspace(client.workspace, monitor);
        eligible.push({ client: client, record: record, monitor: monitor, index: index,
            address: address, x: x, y: y, width: width, height: height });
    }

    for (const record of records) {
        if (!record.monitor) record.monitor = screens.find(m => m.focused) || screens[0] || null;
    }
    for (const entry of eligible) {
        if (entry.client.pinned) {
            const monitor = entry.monitor || entry.record.monitor;
            for (const record of records) {
                // No known physical monitor: do not spread an uncertain pin
                // across every workspace; retain only its reported workspace.
                if (monitor ? record.monitor === monitor : record === entry.record) record.clients.push(entry);
            }
        } else entry.record.clients.push(entry);
    }

    return records.filter(record => record.clients.length > 0).sort((a, b) => a.id - b.id).map(record => {
        const monitor = record.monitor;
        const base = monitorViewport(monitor);
        const originX = finite(monitor && monitor.x, 0);
        const originY = finite(monitor && monitor.y, 0);
        const sorted = record.clients.slice().sort((a, b) => {
            const layerA = a.client.pinned ? 2 : a.client.floating ? 1 : 0;
            const layerB = b.client.pinned ? 2 : b.client.floating ? 1 : 0;
            if (layerA !== layerB) return layerA - layerB;
            return a.index - b.index;
        });
        let minX = 0, minY = 0, maxX = base.width, maxY = base.height;
        const windows = sorted.map((entry, index) => {
            const x = entry.x - originX, y = entry.y - originY;
            minX = Math.min(minX, x); minY = Math.min(minY, y);
            maxX = Math.max(maxX, x + entry.width); maxY = Math.max(maxY, y + entry.height);
            const hasHandle = handles && Object.prototype.hasOwnProperty.call(handles, entry.address);
            return {
                address: entry.address, cls: String(entry.client.class || entry.client.initialClass || ""),
                title: String(entry.client.title || "Untitled window"), x: x, y: y,
                width: entry.width, height: entry.height, z: index,
                pinned: !!entry.client.pinned,
                handle: hasHandle ? handles[entry.address] : entry.client.handle || null
            };
        });
        return {
            key: "workspace:" + record.id, workspaceId: record.id, workspaceName: record.name,
            title: "Workspace " + record.name, cls: "workspace", monitorName: monitor ? String(monitor.name || "") : record.monitorName,
            active: !!(monitor && monitor.activeWorkspace && Number(monitor.activeWorkspace.id) === record.id),
            monitorViewport: base, viewport: { x: minX, y: minY, width: maxX - minX, height: maxY - minY },
            windows: windows, count: windows.length
        };
    });
}
