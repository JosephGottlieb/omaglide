#!/usr/bin/env python3
"""Run the plugin manager lifecycle inside a fresh guarded nested compositor."""
import argparse
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import shlex
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("runtime")
args = parser.parse_args()
test_dir = Path(__file__).resolve().parent
loader = importlib.machinery.SourceFileLoader("lifecycle_guard", str(test_dir / "setup-nested-output"))
spec = importlib.util.spec_from_loader(loader.name, loader)
guard = importlib.util.module_from_spec(spec)
loader.exec_module(guard)
compositor = guard.NestedCompositor(args.runtime)
compositor.apply()
log = compositor.runtime.parent / "lifecycle.log"
if log.exists():
    raise RuntimeError("Use a fresh runner; lifecycle.log already exists")
command = "bash " + shlex.quote(str(test_dir / "clean-lifecycle.sh")) + " > " + shlex.quote(str(log)) + " 2>&1"
compositor.ctl("dispatch", "hl.dsp.exec_cmd(" + json.dumps(command) + ")")
deadline = time.monotonic() + 70
while time.monotonic() < deadline:
    compositor.verify_peer()
    output = log.read_text() if log.exists() else ""
    if "PASS: clean add" in output:
        print(output)
        break
    time.sleep(.25)
else:
    raise RuntimeError("Lifecycle did not pass:\n" + output)
