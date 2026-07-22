#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# Copy repo docs into assets/repo/ for Hugo resources.Get
mkdir -p assets/repo/crates/godopty-core
mkdir -p assets/repo/crates/godopty-gdext
mkdir -p assets/repo/godot

cp ../README.md assets/repo/
cp ../CHANGELOG.md assets/repo/
cp ../ROADMAP.md assets/repo/
cp ../AGENTS.md assets/repo/
cp ../crates/godopty-core/README.md assets/repo/crates/godopty-core/
cp ../crates/godopty-gdext/README.md assets/repo/crates/godopty-gdext/
cp ../godot/README.md assets/repo/godot/
