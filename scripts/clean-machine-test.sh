#!/bin/zsh
set -euo pipefail

if [[ $# -ne 1 ]]; then
    print -u2 "usage: scripts/clean-machine-test.sh path/to/NASE.app"
    exit 64
fi

app=${1:A}
backend="$app/Contents/Resources/Backend"
bundled_python="$app/Contents/Frameworks/Python.framework/bin/python3"
test_home=$(mktemp -d /tmp/nase-clean-home.XXXXXX)

test -x "$app/Contents/MacOS/NASE"
test -f "$app/Contents/Info.plist"
test -f "$backend/nase.py"
test -f "$backend/Tools/DXVKProbe/nase_graphics_probe.exe"
test -x "$bundled_python"
resource_bundle="$app/Contents/Resources/NASE_NASE.bundle"
test -d "$resource_bundle"
test -f "$resource_bundle/NASE Logo.png"
test -f "$resource_bundle/NASE App Logo.png"
plutil -lint "$app/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$app"

HOME="$test_home" PYTHONPYCACHEPREFIX="$test_home/pycache" "$bundled_python" -m compileall -q "$backend/nase" "$backend/nase.py"
HOME="$test_home" PATH="/usr/bin:/bin:/usr/sbin:/sbin" PYTHONDONTWRITEBYTECODE=1 "$bundled_python" "$backend/nase.py" --json list-jobs --limit 1 > "$test_home/jobs.json"
PYTHONDONTWRITEBYTECODE=1 "$bundled_python" -c 'import json,sys; payload=json.load(open(sys.argv[1])); assert payload["ok"] is True' "$test_home/jobs.json"

if [[ ${NASE_SKIP_LAUNCH_SMOKE:-0} != 1 ]]; then
    HOME="$test_home" "$app/Contents/MacOS/NASE" > "$test_home/app.log" 2>&1 &
    app_pid=$!
    sleep 5
    if ! kill -0 "$app_pid" 2>/dev/null; then
        print -u2 "Packaged app exited during launch smoke test."
        tail -80 "$test_home/app.log"
        exit 1
    fi
    kill "$app_pid"
    wait "$app_pid" 2>/dev/null || true
fi

if codesign -dv --verbose=4 "$app" 2>&1 | grep -q 'Authority=Developer ID Application'; then
    spctl --assess --type execute --verbose=2 "$app"
fi

print "Clean-machine smoke test passed with isolated HOME: $test_home"
