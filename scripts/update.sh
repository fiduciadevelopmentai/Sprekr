#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage:
  scripts/update.sh --source [--destination <directory>] [--no-launch]

An ordinary update replaces Sprekr.app and safely migrates a legacy app bundle.
It never removes ~/Library/Application Support/Klim Talks, so the model, history,
and Dictionary remain in place. The same local certificate identity is required and reused;
there is no artifact-update mode. See scripts/install.sh --help for details.
EOF
  exit 0
fi

print "Sprekr updates preserve local app data and model files."
exec "$ROOT/scripts/install.sh" "$@"
