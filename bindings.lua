-- Optional OmaGlide bindings. Load once, after other user overrides:
-- dofile(os.getenv("HOME") .. "/.config/omarchy/plugins/josephgottlieb.omaglide/bindings.lua")
--
-- Alt+Tab selects the next recent window; add Shift to go backward.
-- While held open, Backtick toggles between apps and workspaces.
-- Alt+Backtick opens persistent Exposé; Super+Ctrl+G opens the slider.
--
-- These are defaults. Any shortcut changed in OmaGlide's Settings (the gear
-- icon) is applied live and re-applied after every reload, replacing these.

hl.unbind("ALT + TAB")
hl.unbind("ALT + SHIFT + TAB")
hl.unbind("SHIFT + ALT + TAB")
hl.unbind("ALT + grave")
hl.unbind("ALT + SHIFT + grave")
hl.unbind("SUPER + CTRL + G")

o.bind("ALT + TAB", "OmaGlide: switch windows (Backtick for workspaces)",
    hl.dsp.global("josephgottlieb.omaglide:next"), { repeating = true })

o.bind("ALT + SHIFT + TAB", "OmaGlide: previous window",
    hl.dsp.global("josephgottlieb.omaglide:previous"), { repeating = true })

o.bind("ALT + grave", "OmaGlide: Exposé",
    hl.dsp.global("josephgottlieb.omaglide:expose"))

o.bind("SUPER + CTRL + G", "OmaGlide: slider",
    hl.dsp.global("josephgottlieb.omaglide:toggle"))

-- Catch quick taps before overlay focus, including Alt+Shift+Tab.
-- Transparency prevents Tab from shadowing the modifier-release callback.
hl.unbind("ALT + ALT_L")
hl.unbind("ALT + ALT_R")
hl.unbind("ALT_L")
hl.unbind("ALT_R")
o.bind("ALT_L", "OmaGlide: confirm selection", hl.dsp.global("josephgottlieb.omaglide:release"), { release = true, transparent = true, ignore_mods = true, dont_inhibit = true, non_consuming = true })
o.bind("ALT_R", "OmaGlide: confirm selection", hl.dsp.global("josephgottlieb.omaglide:release"), { release = true, transparent = true, ignore_mods = true, dont_inhibit = true, non_consuming = true })

-- OmaGlide owns its 50 ms entrance; do not add a compositor animation.
hl.layer_rule({ match = { namespace = "^josephgottlieb[.]omaglide$" }, no_anim = true })
