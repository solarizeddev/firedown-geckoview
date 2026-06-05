#!/usr/bin/env bash
# 03 — Apply the Firedown modifications to the source tree (idempotent).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/config/build.env"

bash "$ROOT/firedown/apply-firedown-patches.sh" "$GECKO_SRC"
