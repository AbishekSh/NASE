#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h}
version=${NASE_VERSION:-0.1.0}
build_number=${NASE_BUILD_NUMBER:-1}
bundle_id=${NASE_BUNDLE_ID:-com.nase.launcher}
sign_identity=${NASE_SIGN_IDENTITY:--}
update_url=${NASE_UPDATE_MANIFEST_URL:-}
update_key=${NASE_UPDATE_PUBLIC_KEY:-}
configuration=${NASE_CONFIGURATION:-release}
output_root=${NASE_OUTPUT_DIR:-$repo_root/dist}
app_path="$output_root/NASE.app"

cd "$repo_root"
swift build -c "$configuration"
bin_dir=$(swift build -c "$configuration" --show-bin-path)

if [[ -e "$app_path" ]]; then
    rm -rf -- "$app_path"
fi
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources/Backend" "$app_path/Contents/Frameworks"
cp "$bin_dir/SteamWineApp" "$app_path/Contents/MacOS/SteamWineApp"
cp release/Info.plist "$app_path/Contents/Info.plist"
cp "assets/NASE App Logo.icns" "$app_path/Contents/Resources/NASE App Logo.icns"
cp nase.py "$app_path/Contents/Resources/Backend/nase.py"
cp -R nase "$app_path/Contents/Resources/Backend/nase"
cp -R Tools "$app_path/Contents/Resources/Backend/Tools"
python_runtime=$(scripts/prepare-python-runtime.sh)
python_framework="$app_path/Contents/Frameworks/Python.framework"
cp -R "$python_runtime" "$python_framework"
mkdir -p "$python_framework/Resources"
cp release/PythonRuntime-Info.plist "$python_framework/Resources/Info.plist"
cp "$python_framework/lib/libpython3.13.dylib" "$python_framework/Python"
find "$python_framework/bin" -type f ! -name python3.13 -delete
find "$python_framework/bin" -type l ! -name python ! -name python3 -delete
rm -rf -- \
    "$python_framework/lib/tcl9" \
    "$python_framework/lib/tcl9.0" \
    "$python_framework/lib/tk9.0" \
    "$python_framework/lib/thread3.0.4" \
    "$python_framework/lib/itcl4.3.5" \
    "$python_framework/lib/python3.13/tkinter"
rm -f -- \
    "$python_framework/lib/libtcl9.0.dylib" \
    "$python_framework/lib/libtcl9tk9.0.dylib" \
    "$python_framework/lib/python3.13/lib-dynload/_tkinter.cpython-313-darwin.so"

resource_bundle=$(find "$bin_dir" -maxdepth 1 -type d -name 'SteamWineApp_*.bundle' -print -quit)
if [[ -z "$resource_bundle" ]]; then
    print -u2 "SwiftPM resource bundle was not produced."
    exit 1
fi
# NASE resolves this bundle explicitly from the standard signed-app resource
# location instead of relying on SwiftPM's developer-machine build-path fallback.
cp -R "$resource_bundle" "$app_path/Contents/Resources/"

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :NASEUpdateManifestURL $update_url" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :NASEUpdatePublicKey $update_key" "$app_path/Contents/Info.plist"

find "$app_path/Contents/Resources/Backend" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$python_framework" -type d -name __pycache__ -prune -exec rm -rf {} +
while IFS= read -r executable; do
    if /usr/bin/file "$executable" | /usr/bin/grep -q 'Mach-O'; then
        codesign --force --timestamp --options runtime --sign "$sign_identity" "$executable"
    elif [[ -x "$executable" ]]; then
        chmod a-x "$executable"
    fi
done < <(find "$python_framework" -type f)
codesign --force --timestamp --options runtime --sign "$sign_identity" "$python_framework"
codesign --force --timestamp --options runtime --entitlements release/NASE.entitlements --sign "$sign_identity" "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"

mkdir -p "$output_root"
archive="$output_root/NASE-$version.dmg"
staging=$(mktemp -d /tmp/nase-dmg.XXXXXX)
cp -R "$app_path" "$staging/NASE.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "NASE $version" -srcfolder "$staging" -ov -format UDZO "$archive"
if [[ "$sign_identity" != "-" ]]; then
    codesign --force --timestamp --sign "$sign_identity" "$archive"
fi

print "Built $app_path"
print "Built $archive"
