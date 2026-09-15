# Security

OmaGlide runs inside the user's Omarchy shell, without a sandbox. Its runtime
uses local Hyprland IPC and compositor screencopy, and persists tile width via
the shell's plugin-scoped settings API. It has no network service, telemetry,
credential reader, root helper, or automatic installer.

Do not publish private window titles, screenshots, tokens or core dumps in a
bug report. Use GitHub's private vulnerability reporting if available; otherwise
open an issue requesting a private contact without including exploit details.

The `tests/` programs are opt-in developer tools, not plugin entry points.
They reject production compositor sockets and use disposable private runtimes.
Marketplace listing or automated validation is not a security audit.
