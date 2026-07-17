#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
FIXTURE="$(mktemp -t sprekr-dutch).aiff"
trap 'rm -f "$FIXTURE"' EXIT

say -v Xander -o "$FIXTURE" 'Sprekr houdt deze Nederlandse dicteeropname privé en snel op mijn Mac.'
cd "$ROOT"
swift build --product sprekr-spike >&2
"$(swift build --show-bin-path)/sprekr-spike" --offline --expect-nonempty nl "$FIXTURE"
