#!/usr/bin/env bash
#
# grodex uninstaller. Removes the grodex command, its config home, and stops the
# shim. Leaves your official grok (~/.grok) and codex (~/.codex) completely alone.
#
set -euo pipefail

GRODEX_HOME="${GRODEX_HOME:-$HOME/.grodex}"
BIN_DIR="${GRODEX_BIN_DIR:-$HOME/.local/bin}"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

say "Stopping the shim (if running)…"
pkill -f "$GRODEX_HOME/codex-proxy.py" 2>/dev/null || true

say "Removing launcher $BIN_DIR/grodex"
rm -f "$BIN_DIR/grodex"

if [ -d "$GRODEX_HOME" ]; then
  printf 'Remove config home %s ? [y/N] ' "$GRODEX_HOME"
  read -r ans
  case "$ans" in
    y|Y) rm -rf "$GRODEX_HOME"; say "removed $GRODEX_HOME" ;;
    *)   say "kept $GRODEX_HOME" ;;
  esac
fi

say "Done. Your official 'grok' and 'codex' are unchanged."
