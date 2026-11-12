#!/bin/bash

# Regenerates the scenes of the Welcome and WinShot tours, the SVG animations in Resources/Tour that
# build.sh bundles.
# Usage: ./scripts/build-tour-animations.sh

set -e

cd "$(dirname "${BASH_SOURCE[0]}")/.."
mkdir -p Resources/Tour

python3 scripts/hero-animation.py Resources/Tour/welcome.svg --fluid
python3 scripts/activefit-winshot-animation.py Resources/Tour/winshot-switching.svg --tour
for scene in zones destination finding moving winshot-display; do
    python3 "scripts/tour-$scene-animation.py" "Resources/Tour/$scene.svg"
done
