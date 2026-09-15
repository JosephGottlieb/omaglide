#!/usr/bin/env bash
# Only dispatch from the guarded nested compositor, whose HOME mount is tmpfs.
set -euo pipefail
[[ ${LIBSEAT_BACKEND:-} == omadesktop-test-disabled ]]
[[ ${XDG_RUNTIME_DIR:-} =~ ^/tmp/od\.[A-Za-z0-9]{6}/r$ ]]
[[ $(findmnt -n -o FSTYPE -T "$HOME") == tmpfs ]]
test_source=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export WAYLAND_DISPLAY=wayland-1 OMARCHY_PATH=/usr/share/omarchy
mkdir -p "$HOME/.config/omarchy" "$HOME/.config/hypr"
cp "$test_source/tests/clean-shell.json" "$HOME/.config/omarchy/shell.json"
cp "$test_source/bindings.lua" "$HOME/.config/hypr/bindings.lua"
before=$(sha256sum "$HOME/.config/hypr/bindings.lua")
shell_pid=""
trap '[[ -z $shell_pid ]] || kill "$shell_pid" 2>/dev/null || true' EXIT
start_shell() {
  quickshell -n -p /usr/share/omarchy/shell >> "$XDG_RUNTIME_DIR/../clean-shell.log" 2>&1 &
  shell_pid=$!
  for attempt in {1..30}; do
    if omarchy-shell shell ping >/dev/null 2>&1; then return; fi
    sleep 0.2
  done
  return 1
}
enabled() {
  omarchy plugin list --json | jq -e 'any(.[]; .id == "hjklcc.omaglide" and .enabled == true)' >/dev/null
}
start_shell
omarchy plugin add "file://$test_source" --enable --yes
enabled
omarchy-shell omaglide show
omarchy-shell omaglide hide
omarchy plugin disable hjklcc.omaglide
if enabled; then exit 1; fi
omarchy plugin enable hjklcc.omaglide
enabled
kill "$shell_pid"
wait "$shell_pid" || true
shell_pid=""
start_shell
enabled
omarchy-shell omaglide show
omarchy-shell omaglide hide
omarchy plugin remove hjklcc.omaglide --yes
[[ ! -e $HOME/.config/omarchy/plugins/hjklcc.omaglide ]]
[[ $(sha256sum "$HOME/.config/hypr/bindings.lua") == "$before" ]]
echo 'PASS: clean add, enable, show/hide, disable, re-enable, restart, remove; bindings unchanged'
