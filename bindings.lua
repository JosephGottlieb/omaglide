-- Optional OmaGlide bindings. Load once, after other user overrides:
-- dofile(os.getenv("HOME") .. "/.config/omarchy/plugins/hjklcc.omaglide/bindings.lua")
--
-- Explicitly replaces Alt+Tab and Alt+Shift+Tab. Installing/enabling the
-- plugin alone never changes bindings. Hold Alt and press W for workspaces.

hl.unbind("ALT + TAB")
hl.unbind("ALT + SHIFT + TAB")
o.bind("ALT + TAB", "OmaGlide: switch windows (W for workspaces)",
    hl.dsp.global("hjklcc.omaglide:next"), { repeating = true })

o.bind("ALT + SHIFT + TAB", "OmaGlide: previous window",
    hl.dsp.global("hjklcc.omaglide:previous"), { repeating = true })
