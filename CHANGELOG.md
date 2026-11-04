# Changelog

## Unreleased

- Fix: letting go mid-swipe could leave Exposé frozen part-way. Hyprland's
  gesture parser only reads a release callback named `finish` (a field named
  `end` is silently ignored), so the release never reached OmaGlide; it now
  registers `finish`, and sessions reload into the fixed swipes automatically.

- Swipes follow the fingers. Exposé opens as soon as Hyprland recognises the
  swipe and tracks it in real time, instead of waiting for the fingers to lift;
  releasing finishes or springs back from wherever they stopped. Sessions
  holding the older one-shot swipes reload into tracked ones automatically.
- Fix: choosing a window on another workspace in Exposé glided the old
  workspace's windows home and only showed the chosen one on the last frame.
  Its workspace now switches in as the glide starts, its windows land on
  themselves, the chosen window glides above the rest, and the others fade.
- The selection's zoom grows and shrinks with the glide instead of jumping.

- Liquid glass everywhere: the search bar, gear, header and title pills,
  slider caption strips, filmstrip, Quick Look labels, hints, Settings and
  workspace previews share one smoked-glass surface (GlassPanel) with light
  text. Nothing reads the theme's popup colors any more, which could resolve
  as undefined and fall back to Qt's default white.
- The accent color has a fallback for the same reason.
- App icons is now the default slider style.

- Fix: swipes did nothing while Exposé or App Exposé was open, because
  Hyprland suppresses gestures under OmaGlide's own shortcut inhibitor.
  The swipes now set `disable_inhibit`; sessions holding the older swipes
  reload into the new ones automatically.
- App icons slider: liquid-glass panel (clear tint over the compositor blur,
  top sheen, hairline edges, glassy selection) instead of the theme's opaque
  popup color.

- Mission Control swipe rules: down from Exposé glides back to the desktop and
  down again opens App Exposé (reversing mid-glide); up from App Exposé glides
  back. Repeating a view's own swipe leaves it open.
- Closing Exposé animates the fly-in in reverse before unmapping; number-key
  jumps stay instant.
- Slider style setting: Thumbnails or App icons (Cmd+Tab-style frosted icon
  panel, no captures). IPC `sliderStyle`.
- The selected filmstrip thumbnail's underline is now a bar with the app icon
  and window title (workspace and window count in workspace mode).

## 0.3.0

- The shortcut-hint pill appears only while Settings is open, giving the
  views more room; the `showHints` setting is gone.
- Quick Look now enlarges the selected tile itself (same element, same live
  capture) to the preview size and shrinks it back on close, blending its
  zoom, corners and shadow, with no crossfade; only the backdrop and labels
  fade. Reverses smoothly if interrupted.

- App Exposé: Exposé limited to the focused app's windows, with its own
  shortcut (`appExpose`, unset by default) and an app header. Each Exposé's
  shortcut switches to it in place from the other. IPC `appExpose`.
- Touchpad gestures, on by default: three-finger swipe up for Exposé, down for
  App Exposé; the opposite swipe dismisses. Settings turns them off or uses
  four fingers, and warns about conflicting gestures or three-finger drag.
  Gestures are only ever added; changes reload the config instead of unsetting.
  IPC `swipe` and `gestures`. The settings sheet scrolls on short screens.

- Exposé: the selected tile zooms up to 18%, limited by the screen edges.
  Space opens Quick Look, a live, nearly full-screen preview that zooms out
  of the tile; Left/Right browse, Enter/click switches, Space/Esc closes.
  New IPC `quickLook`.
- After switching, the pointer moves to the center of the newly focused
  window (`pointerFollowsFocus`, toggle in Settings).

- Settings sheet behind a gear icon (or Ctrl+,). Exposé, the slider, and both
  hold-to-switch directions get independent shortcuts captured from the
  keyboard, with conflict warnings. They apply live via `hyprctl eval`, are
  saved as `keybindings`, and are re-applied after every Hyprland reload.
  Also toggles `blurBackground`, `groupApps`, and `showHints`. New IPC
  `settings` and `bind <action> <chord>`.
- Removed the Ctrl+E shortcut and on-screen button that switched between
  Exposé and the carousel. Inside an open view, that view's own shortcut
  advances (Exposé) or dismisses (slider) it.
- Exposé now overlays the live desktop, dimmed and blurred (runtime layer
  rule), instead of an opaque background. Windows are row-packed by their real
  shapes, so tiles take each window's shape and the capture fills it with no
  letterboxing. Rounded, shadowed tiles; app icon badges; title pill under
  the selection; windows on the current workspace fly in from their desktop
  positions.
- The slider's previews and filmstrip thumbnails clip to rounded corners.
  Inactive tiles are dimmed with an overlay instead of transparency, so the
  desktop never bleeds through them.
- Performance: no more `hyprctl binds` every 2s while open; Exposé refreshes
  unselected previews every second, staggered; shadows use one SDF pass.
- Fix: recognize runtime-created Lua binds (`HL.Dispatcher(global)`) as well
  as config-file binds (`__lua`).

- Slide the overlay in from the right in 50ms with constant opacity, without
  delaying input or dismissal.
- Group the window carousel by app by default. Ctrl+G toggles grouping and
  persists `groupApps`; Up/Down browses the selected app's windows while Tab
  and Left/Right browse app groups. Search includes every member window.
- Remember the selected app/workspace carousel as `carouselMode`. Alt+Tab,
  Alt+Shift+Tab, the persistent toggle, and IPC `show` reopen that mode.
  Backtick changes and saves it; explicit IPC `windows` and `workspaces` also
  save their requested modes. Exposé preserves it.
- Number keys 1–9, with or without Alt, immediately close OmaGlide and switch
  to that workspace ID from any open view, including focused search. Empty
  workspaces are valid destinations; the remembered carousel mode is preserved.
- Alt+Backtick opens persistent window Exposé. Further taps with Alt held
  advance the selected window; add Shift to reverse direction.
- Persistent openings start on the current window/workspace. Exposé always
  shows individual windows with frames matching their native aspect ratios
  and captions outside. Selected previews grow to 140% of their normal grid
  fit and inactive previews shrink to 70%, doubling the selected window's
  width and height when room allows. Screen bounds limit expansion; a single
  window uses the largest available fit.
- Recognize the persistent toggle shortcut in the live shortcut hints.

- Retain paused native previews and stable fullscreen layout between openings
  to avoid rebuilding the carousel and filmstrip on every shortcut press.
- Cache app icon resolution and refresh retained frames when reopening.

- Bottom filmstrip shows native window/workspace thumbnails in one row, with
  large workspace numbers, small app icons, and a full-width selection underline.
- Hide the corner resize arrow while retaining drag resizing.

- Exposé fills the available screen space and stays open on modifier release.

- Search by app, window title, or workspace.
- Exposé grid with keyboard navigation and click-to-switch.
- Ctrl+E toggles the grid; Ctrl+F focuses search.

## 0.2.0

First release.

- Window and workspace previews with wraparound navigation.
- Resizable tiles with native-resolution previews.
- Alt+backtick switching and Alt+W workspace previews.
- Shortcut hints that follow your keybindings.
