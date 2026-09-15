# Tests

Unit tests need Node.js 18+ and no compositor: `node --test test_*.js` from
the repository root. No npm packages or network access are required.

Integration tests need a running Wayland session, the installed Omarchy shell,
Hyprland with Lua and window screencopy, Quickshell 0.3+, Python 3, bubblewrap,
D-Bus, a C compiler, pkg-config, wayland-scanner, libwayland-client and
libxkbcommon development files. The sandbox currently requires a render-only
`/dev/dri/renderD128` node. It never receives physical input or DRM card devices.

From the repository root:

```sh
bash tests/build-helpers
bash tests/run-nested-hyprland 180
```

Leave that runner open. In another terminal, use its exact printed runtime:

```sh
python3 tests/run-workspace-checks.py /tmp/od.XXXXXX/r
```

Stop that runner with Ctrl+C. Start a **fresh** runner for:

```sh
python3 tests/run-super-drag-checks.py /tmp/od.YYYYYY/r
```

Each suite creates synthetic windows and uses guarded virtual input. It checks
the IPC socket's owner, actual peer PID/executable/config and sandbox namespaces
before dispatching anything. Never substitute your normal XDG runtime.
The runner has a hard timeout and retains its private directory for diagnosis.

After committing the checkout (the plugin manager clones committed files),
start another fresh runner and run:

```sh
python3 tests/run-lifecycle-checks.py /tmp/od.ZZZZZZ/r
```

This starts the actual Omarchy shell in the runner's private HOME mount and
tests install, enable, show/hide, disable, re-enable, shell restart and removal.
It checks that a preexisting bindings file is unchanged. HOME keeps its normal
value, but personal files are hidden by a temporary mount; only this checkout
is mounted back read-only. No personal plugins, settings or sockets are used.

`run-interaction-checks.py` can additionally reuse an already-prepared
InteractionHarness fixture, with its input keepers running. The two suites
above handle their own fixture setup and teardown.

The helper sources were adapted from MIT-licensed OmaDesktop test tools.
The bundled protocol XML retains each upstream copyright and MIT
notice; generated code/binaries stay in ignored `.test-build/`.
