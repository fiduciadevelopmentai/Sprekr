#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage:
  scripts/update.sh --source [--destination <directory>] [--no-launch]
                    [--no-cleanup-stale-apps] [--remove-other-installs]

An ordinary update replaces Sprekr.app and safely migrates a legacy app bundle.
It never removes ~/Library/Application Support/Klim Talks, so the model, history,
and Dictionary remain in place. The same local certificate identity is required and reused;
there is no artifact-update mode.

By default the update also removes repo build/debug and build/release Sprekr.app
bundles (and other ad-hoc/.development copies) so Accessibility does not keep a
second Sprekr row. Pass --remove-other-installs to delete a second certificate-
bound Sprekr.app outside the install destination. See scripts/install.sh --help.
EOF
  exit 0
fi

print "Sprekr updates preserve local app data and model files."
exec "$ROOT/scripts/install.sh" "$@"
