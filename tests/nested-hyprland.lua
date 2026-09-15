-- Isolated integration-test compositor. Never source the user's Omarchy config.
-- Run only through run-nested-hyprland so physical seats/devices are unavailable.
hl.monitor({ output = "", mode = "1280x800@60", position = "0x0", scale = 1 })
hl.config({
    animations = { enabled = false },
    xwayland = { enabled = false },
    misc = {
        disable_hyprland_logo = true,
        disable_splash_rendering = true,
    },
})
for workspace = 1, 3 do
    hl.bind("SUPER + " .. workspace, hl.dsp.focus({ workspace = tostring(workspace) }))
end
