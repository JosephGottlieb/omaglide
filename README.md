# OmaGlide

A window and workspace carousel for the Omarchy shell. Windows are grouped by
app by default, with an option to browse every window separately. The selected
preview is larger, neighboring previews remain visible, and navigation wraps
around the ring. It switches to existing windows and workspaces; it does not
launch apps.

Plugin ID: `josephgottlieb.omaglide` · IPC target: `omaglide` · License: MIT

This is a local plugin package, not a published marketplace listing. There is
no public OmaGlide installation URL yet.

## Requirements and local setup

OmaGlide needs Omarchy's Quickshell-based shell with `ShortcutInhibitor` support
(Quickshell 0.3 or newer), Hyprland with Lua configuration and window screencopy
support, and `hyprctl`. It is a shell service, not a bar widget.

Place this plugin folder at `~/.config/omarchy/plugins/josephgottlieb.omaglide/`, keeping
the original QuickSwitch folder separate. Do not overwrite an existing
OmaGlide installation without backing it up. Then validate and enable it:

```sh
omarchy plugin validate "$HOME/.config/omarchy/plugins/josephgottlieb.omaglide"
omarchy plugin enable josephgottlieb.omaglide
```

To use the example shortcuts, add this line once, after other overrides, in
`~/.config/hypr/bindings.lua`:

```lua
dofile(os.getenv("HOME") .. "/.config/omarchy/plugins/josephgottlieb.omaglide/bindings.lua")
```

The example replaces **Alt+Tab** and **Alt+Shift+Tab** with OmaGlide window
switching, assigns **Alt+Backtick** to Exposé and **Super+Ctrl+G** to the persistent
carousel, and removes the older **Alt+Shift+Backtick** assignment. Review
`bindings.lua` before loading it if these chords already have another purpose.

```sh
hyprctl reload
hyprctl configerrors
hyprctl globalshortcuts
```

The global shortcuts should include `josephgottlieb.omaglide:next`,
`josephgottlieb.omaglide:expose`, and `josephgottlieb.omaglide:toggle`. Enabling the plugin alone
does not install these Hyprland bindings.

## Settings and custom shortcuts

Click the gear next to the search field (or press **Ctrl+,**) to open
Settings. Exposé, App Exposé, the slider, and the two hold-to-switch directions
each have their own shortcut (App Exposé has none until you set one). Click one, then press the new chord; Esc cancels. Bare
letter keys are refused (they would steal typing); function keys may be used
alone. If the chord already belongs to something else, Settings names it and
asks before replacing it. **Clear** unbinds an action.

Changes take effect immediately through `hyprctl eval` and are stored as
`keybindings` on the `josephgottlieb.omaglide` entry in `~/.config/omarchy/shell.json`.
Hyprland reloads discard runtime binds, so OmaGlide re-applies its shortcuts
after every reload and when the shell starts. Actions you never change in
Settings are left exactly as your Hyprland config binds them. Hold-to-switch
confirms when Alt, Super, or Ctrl is released.

### Touchpad gestures

By default a **three-finger swipe up** opens Exposé and a **three-finger swipe
down** opens App Exposé, following Mission Control: swiping down in Exposé
glides the windows back to their desktop positions, and swiping down again
(even mid-glide) opens App Exposé; swiping up in App Exposé glides back to the
desktop. Repeating a view's own opening swipe leaves it open. Hyprland reports
a swipe only once it ends, so the animation plays after the swipe rather than
following your fingers.
Settings turns gestures off or switches them to four fingers
(`gesturesEnabled`, `gestureFingers`).

Hyprland cannot list gestures or safely remove one, so OmaGlide only ever adds
its two swipes. Turning them off or changing the finger count runs
`hyprctl reload config-only`, which clears runtime gestures (and other runtime
binds, which OmaGlide re-applies for itself) before the new swipes are added.
If your Hyprland config already uses the same fingers and direction, Hyprland
keeps that gesture and Settings says so. Settings also warns when libinput's
three-finger drag (`input:touchpad:drag_3fg`) is using the chosen finger count,
because those swipes then never reach Hyprland.

**Slider style** in Settings switches the slider between **App icons** (the
default): a Cmd+Tab-style glass panel with one large icon per app, the
selected window's title underneath, no screen dimming and no live captures,
and **Thumbnails** (live previews with the filmstrip) (`sliderStyle`).

Every OmaGlide surface (search bar, buttons, labels, caption strips, Settings,
the icon panel) is the same liquid glass: a smoked tint over the compositor's
blur of the desktop, with a soft sheen and hairline edges, and light text.
It does not depend on the theme's popup colors. The search bar appears
once you type; Ctrl+, opens Settings. Workspace mode always uses thumbnails.

Settings also toggles the frosted background (`blurBackground`), app grouping
in the slider (`groupApps`), and whether the
pointer moves to the center of the window you switch to (`pointerFollowsFocus`,
on by default; useful with Hyprland's `cursor:no_warps`).

## Controls

| Input | Action |
| --- | --- |
| Hold Alt, press Tab | Reopen the last carousel mode and select the next app, window, or workspace |
| Hold Alt+Shift, press Tab | Browse in the opposite direction |
| Backtick while the carousel is open | Toggle between windows and workspaces |
| Alt+Backtick from the desktop | Open persistent window Exposé |
| Exposé's shortcut while Exposé is open | Select the next window; add Shift to go backward |
| The slider's shortcut while the slider is open | Dismiss it |
| Super+Ctrl+G | Open or dismiss the persistent carousel |
| Left/Right or Tab/Shift+Tab | Browse apps, individual windows, or workspaces backward/forward |
| Up/Down in the grouped carousel | Browse windows belonging to the selected app |
| Up/Down in Exposé | Browse rows |
| Ctrl+G in the window carousel | Toggle app grouping and save the preference |
| 1–9 or Alt+1–9 while open | Immediately switch to that workspace number and close OmaGlide |
| Mouse wheel | Browse the carousel |
| Release Alt | Activate the selection when opened with Alt+Tab |
| Enter or click a tile | Activate the selected window or workspace |
| Escape or click the background | Cancel without switching |
| Type text or Ctrl+F | Search by app, window title, or workspace; 1–9 remain workspace shortcuts |
| Space in Exposé | Quick Look the selected window; Space/Esc closes it |
| Three-finger swipe up / down | Exposé / App Exposé; the opposite swipe glides back to the desktop |
| App Exposé's shortcut (set in Settings) | Exposé of the focused app's windows only |
| Ctrl+, or the gear icon | Open Settings (shortcuts, gestures, blur, grouping, pointer); shortcut hints show beneath it |
| + / - | Increase/decrease the center-tile width |
| Ctrl+mouse wheel | Resize the tiles |
| Drag the center tile's lower-right corner | Resize continuously |
| Ctrl+0 | Restore the 560px preferred width |
| Super+Q in window mode | Ask the selected window to close |

Alt+Tab and Alt+Shift+Tab reopen the last carousel mode. In app mode, Alt+Tab
starts on the next app in recent-use order, so a quick press and release switches
to the previous app. With grouping disabled it cycles individual windows. In
workspace mode it selects the next workspace. Persistent openings start on the
current window or workspace; Exposé starts on the current window.

Backtick remembers the chosen app/workspace mode for the next invocation,
including Super+Ctrl+G and IPC `show`. Opening Exposé preserves this preference.
Exposé and the slider each open from their own shortcut; there is no in-overlay
switch between the two. Number keys 1–9 switch immediately to the
matching workspace ID from any open view, including Exposé and the focused
search field. Empty workspaces are valid destinations. These jumps close the
overlay without changing the remembered carousel mode.

Opening uses a 50ms slide from the right, starting with the first presented
frame. The animation keeps opacity constant. Navigation and activation remain
available throughout, and closing does not wait for an exit animation.
The Alt-release bindings also confirm quick taps that end before the overlay
receives keyboard focus.

Closing Exposé (Esc, a background click, a swipe or activating a window)
plays the opening in reverse before the overlay disappears; number-key
workspace jumps stay instant.

Exposé shows every window separately, including when app grouping is enabled.
App Exposé is the same view limited to the focused app's windows (matched by
full class, across workspaces), with the app's name and window count at the
top. Pressing either Exposé's shortcut while the other is showing switches in
place.
It overlays the live desktop, dimmed and blurred, rather than a solid
background. Windows are packed into centered rows by their real shapes, like
Mission Control: a portrait window gets a tall tile, an ultrawide one a wide
tile, and the capture fills each rounded tile edge to edge without letterbox
bars. On opening, windows on the current workspace glide from their real
desktop positions into the layout (240ms); others fade in. Each tile carries
its app icon on the lower edge, and the selected one gets an accent outline,
zooms up to 18% (as far as the screen edges allow), and shows its title
underneath. **Space** opens Quick Look: the selected window, live, enlarged to
nearly full screen. Left/Right browse while previewing, Enter or a click
switches to it, and Space or Esc zooms it back into its tile. A lone window keeps a desktop margin.
Keyboard navigation (Up/Down picks the nearest tile in the next row) and
pointer movement change the highlighted preview; clicking activates it.
Repeating Exposé's shortcut advances the selection; add Shift to reverse.

Exposé, searching, and resizing keep the overlay open on modifier release.
Use Enter/click to activate afterward, a number key to jump to a workspace,
or Escape to cancel. Workspace mode does not close windows with Super+Q.

While the overlay is focused, a surface-scoped shortcut inhibitor prevents
Super+mouse from moving or resizing a window underneath. The switcher's own
keys are handled directly. Other ordinary desktop shortcuts, including media
keys, are temporarily suspended; closing/cancelling the overlay restores them
automatically. No global bindings or submaps are changed. If the compositor
revokes the inhibitor, the overlay cancels rather than continuing unprotected.

The preferred width is saved as `tileWidth` on the `josephgottlieb.omaglide` entry in
`~/.config/omarchy/shell.json`. It ranges from 240 to 1200 logical pixels, with
the displayed size additionally constrained to the current monitor.
The same settings entry stores the app-grouping preference as `groupApps`;
it defaults to `true`. Ctrl+G changes it while the window carousel is open.
Grouping uses the full app class, keeping separately identified web apps
distinct. Search includes titles and workspaces of every window in a group.
The selected app/workspace carousel mode is saved separately as `carouselMode`.

The filmstrip below the carousel shows miniature previews of every app group,
individual window, or occupied workspace in one row. A grouped tile previews
the selected window belonging to that app; Up/Down changes that window.
Workspace thumbnails have large workspace numbers, and small app icons sit
beneath each preview. The selected thumbnail
carries a bar with its app icon and window title (or workspace and window
count). Click a thumbnail to switch directly; thumbnails
shrink to fit on narrow screens. The corner resize area remains available without
a visible arrow.

The selected thumbnail updates live. The other filmstrip previews capture a
frame when opened, keeping the full overview lightweight.

## What workspace previews show

Workspace mode includes occupied regular workspaces. Empty workspaces and
special/scratchpad workspaces are omitted from the previews. Number shortcuts
can still switch directly to an empty workspace from 1 through 9.

Each workspace tile composes its windows at their relative positions using a
single uniform scale. The preview includes the full union of the monitor and
window rectangles, including windows currently offscreen in scrolling layouts.
Their geometry is not changed on the desktop.

Behind them the live desktop shows through, dimmed and blurred. These are window-layout previews,
not pixel-perfect screenshots of the whole desktop: the bar, wallpaper, and
other shell overlays are not reproduced. No current-desktop screenshot is
used, avoiding recursive captures of the switcher itself.

## Capture quality and resource use

Window previews draw native compositor buffers directly at their final display
geometry, preserving the source aspect ratio. There is no fixed-size thumbnail
or rasterized carousel layer that is enlarged afterward. Larger tiles can show
more source detail, but cannot create detail absent from the original buffer.

Only nearby carousel slots mount captures. The selected preview is live;
neighbors request updates every 450ms after their initial content is available.
Exposé mounts every window, so its unselected previews refresh every second,
staggered so the copies do not land on the same frame. Shadows are analytic
(`RectangularShadow`), not offscreen blur layers. Keybindings are read when
the overlay opens and after config reloads; nothing polls `hyprctl` while open.
Workspace mode applies this policy to each composed window. Moving a slot out
of range releases its captures. Closing unmaps the overlay and pauses captures
and refresh timers, retaining the last native frames in memory for faster
reopening. Each opening refreshes the cached frames; new windows and changes
between window/workspace modes may still need an initial capture. The cache is
released when the plugin unloads. Some applications stop repainting while
hidden, and unavailable captures show a placeholder.

See the [Quickshell ScreencopyView documentation](https://quickshell.org/docs/v0.2.1/types/Quickshell.Wayland/ScreencopyView/)
for the underlying capture API.

## IPC

```sh
omarchy-shell omaglide show             # remembered carousel mode, stays open
omarchy-shell omaglide windows          # window mode, remembers it and stays open
omarchy-shell omaglide workspaces       # workspace mode, remembers it and stays open
omarchy-shell omaglide expose           # window Exposé, stays open
omarchy-shell omaglide hide
omarchy-shell omaglide toggle
omarchy-shell omaglide next
omarchy-shell omaglide previous
omarchy-shell omaglide resize larger    # also: smaller, reset
omarchy-shell omaglide settings         # open the settings sheet
omarchy-shell omaglide quickLook        # toggle Quick Look in an open Exposé
omarchy-shell omaglide appExpose        # Exposé of the focused app's windows
omarchy-shell omaglide swipe up         # what the gestures call: up or down
omarchy-shell omaglide gestures on 4    # or: gestures off 3
omarchy-shell omaglide sliderStyle icons  # or: thumbnails
omarchy-shell omaglide bind expose "SUPER + E"   # actions: expose, appExpose, toggle, next, previous; "" unbinds
omarchy-shell omaglide status           # state, geometry, native-buffer metrics
```

`next` and `previous` browse an already-open carousel. IPC `show`, `windows`,
and `workspaces` do not depend on holding a modifier; activate with Enter/click,
jump to a workspace with a number key, or cancel with Escape.

## Tests

Run the pure JavaScript tests from the plugin checkout:

```sh
node --test test_*.js
```

The scripts and fixtures under `tests/` exercise keyboard/pointer interaction,
workspace composition, cached native frames, and reopening in a guarded
disposable Hyprland session. See [tests/README.md](tests/README.md) for dependencies
and setup. Do not point those fixtures at the production desktop session.

## Disable or remove

```sh
omarchy plugin disable josephgottlieb.omaglide
```

Remove the `dofile(...)` line and any OmaGlide-specific overrides from your
Hyprland configuration before deleting the plugin folder, then reload and
check `hyprctl configerrors`. If the original QuickSwitch remains installed,
its own shortcut configuration must be restored separately; disabling
OmaGlide does not rewrite user bindings.

## Credits

OmaGlide is derived from [QuickSwitch by Ewgeni Weber](https://github.com/ewweberlin/QuickSwitch).
It adds the carousel presentation, resizing, and workspace composition as a
separate local plugin. It is not an official QuickSwitch or Omarchy release.

The original MIT license and **Copyright (c) 2026 Ewgeni Weber** are retained in
[LICENSE](LICENSE).
