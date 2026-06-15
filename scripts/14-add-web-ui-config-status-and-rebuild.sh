#!/usr/bin/env bash
set -Eeuo pipefail

# Explicit alias for the authoritative Hall config-status web build. Stage 13
# now uses these defaults as well; this filename remains for clarity and
# compatibility with revision 8 instructions.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export WEB_BUILDER_REF="${WEB_BUILDER_REF:-config-status}"
export WEB_BUILDER_SOURCE_DIR="${WEB_BUILDER_SOURCE_DIR:-${PROJECT_ROOT:-$HOME/meraki-ms42p-build}/sources/hall-meraki-builder-config-status}"
export UI_REF="${UI_REF:-main}"
exec "$SCRIPT_DIR/13-add-web-ui-and-rebuild.sh" "$@"
