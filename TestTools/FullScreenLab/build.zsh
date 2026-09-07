#!/bin/zsh
# Build only the disposable full-screen fixtures; never package or launch Zonogy.
set -eu
lab_source_dir=${0:A:h}
lab_project_dir=${lab_source_dir:h:h}
cd "$lab_project_dir"
swift build --product FullScreenLab
lab_binary_dir=$(swift build --show-bin-path)
lab_output_dir="$lab_project_dir/.build/TestApps"

for lab_name in 'Full Screen Lab' 'Full Screen Lab 2' 'Full Screen Guest'; do
    lab_bundle="$lab_output_dir/$lab_name.app"
    mkdir -p "$lab_bundle/Contents/MacOS"
    cp "$lab_binary_dir/FullScreenLab" "$lab_bundle/Contents/MacOS/FullScreenLab"
    cp "$lab_source_dir/Info.plist" "$lab_bundle/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $lab_name" "$lab_bundle/Contents/Info.plist"
    if [[ "$lab_name" == 'Full Screen Guest' ]]; then
        /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.dsemeas.zonogy.fullscreenlab.guest' "$lab_bundle/Contents/Info.plist"
        /usr/libexec/PlistBuddy -c 'Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 zonogy-fullscreen-guest' "$lab_bundle/Contents/Info.plist"
    elif [[ "$lab_name" == 'Full Screen Lab 2' ]]; then
        /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.dsemeas.zonogy.fullscreenlab.second' "$lab_bundle/Contents/Info.plist"
        /usr/libexec/PlistBuddy -c 'Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 zonogy-fullscreen-lab-2' "$lab_bundle/Contents/Info.plist"
    fi
    codesign --force --sign - "$lab_bundle"
done
print -r -- "$lab_output_dir/Full Screen Lab.app"
