#!/bin/bash

# Regenerates the Welcome tour's scenes, the SVG animations in Resources/Tour that build.sh bundles.
# Usage: ./scripts/build-tour-animations.sh

set -e

cd "$(dirname "${BASH_SOURCE[0]}")/.."
mkdir -p Resources/Tour

python3 scripts/hero-animation.py Resources/Tour/welcome.svg --fluid
for scene in zones destination finding moving; do
    python3 "scripts/tour-$scene-animation.py" "Resources/Tour/$scene.svg"
done
