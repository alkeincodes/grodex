#!/usr/bin/env bash
#
# grodex installer — run gpt-5.6-sol on your ChatGPT/Codex subscription through
# the official grok CLI, in a config home isolated from your normal `grok`.
#
# Usage:  ./install.sh
# Env:    GRODEX_HOME       (default ~/.grodex)
#         GRODEX_PROXY_PORT (default 8765)
#         GRODEX_BIN_DIR    (default ~/.local/bin)
#
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
GRODEX_HOME="${GRODEX_HOME:-$HOME/.grodex}"
PORT="${GRODEX_PROXY_PORT:-8765}"
BIN_DIR="${GRODEX_BIN_DIR:-$HOME/.local/bin}"
CODEX_AUTH="${CODEX_AUTH_FILE:-$HOME/.codex/auth.json}"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

# ---- preconditions --------------------------------------------------------
command -v grok    >/dev/null 2>&1 || die "The official 'grok' CLI is not on PATH. Install it first: https://x.ai/cli"
command -v python3 >/dev/null 2>&1 || die "python3 is required (used by the auth bridge and the shim)."
command -v codex   >/dev/null 2>&1 || say "note: 'codex' CLI not found — you need it (and a ChatGPT/Codex subscription) to sign in and refresh."
[ -f "$CODEX_AUTH" ] || die "No Codex credentials at $CODEX_AUTH. Run 'codex login' with your ChatGPT/Codex subscription first."

ACCOUNT_ID="$(python3 -c "import json;d=json.load(open('$CODEX_AUTH'));print((d.get('tokens') or {}).get('account_id') or '')")"
[ -n "$ACCOUNT_ID" ] || die "Couldn't read chatgpt account_id from $CODEX_AUTH. Try 'codex login' again."
GROK_BIN="$(command -v grok)"

# ---- files ----------------------------------------------------------------
say "Installing grodex config home at $GRODEX_HOME"
mkdir -p "$GRODEX_HOME"
install -m 700 "$SELF_DIR/lib/codex-auth.sh"  "$GRODEX_HOME/codex-auth.sh"
install -m 755 "$SELF_DIR/lib/codex-proxy.py" "$GRODEX_HOME/codex-proxy.py"
sed -e "s|__GRODEX_HOME__|$GRODEX_HOME|g" \
    -e "s|__PORT__|$PORT|g" \
    -e "s|__ACCOUNT_ID__|$ACCOUNT_ID|g" \
    "$SELF_DIR/lib/config.toml.template" > "$GRODEX_HOME/config.toml"
chmod 600 "$GRODEX_HOME/config.toml"

# ---- the `grodex` command -------------------------------------------------
mkdir -p "$BIN_DIR"
WRAPPER="$BIN_DIR/grodex"
say "Writing launcher: $WRAPPER"
cat > "$WRAPPER" <<WRAP
#!/usr/bin/env bash
# grodex — official grok CLI, isolated config home, gpt-5.6-sol via the Codex bridge.
set -euo pipefail
export GROK_HOME="$GRODEX_HOME"
PROXY="$GRODEX_HOME/codex-proxy.py"
LOG="$GRODEX_HOME/codex-proxy.log"
up() { python3 -c "import socket,sys;s=socket.socket();s.settimeout(0.3);sys.exit(0 if s.connect_ex(('127.0.0.1',$PORT))==0 else 1)"; }
# Lazy-start the shim if it isn't already listening.
if ! up 2>/dev/null; then
  GROK_CODEX_PROXY_PORT=$PORT nohup python3 "\$PROXY" >>"\$LOG" 2>&1 &
  for _ in \$(seq 1 25); do up 2>/dev/null && break; sleep 0.2; done
fi
exec "$GROK_BIN" "\$@"
WRAP
chmod 755 "$WRAPPER"

# ---- one-time session (runs the codex bridge to sign in) ------------------
say "Signing in the grodex session (via your Codex bridge)…"
GROK_HOME="$GRODEX_HOME" "$GROK_BIN" login >/dev/null 2>&1 \
  || die "grok login through the codex bridge failed. Make sure 'codex' is logged in (codex login)."

# ---- PATH hint ------------------------------------------------------------
case ":$PATH:" in
  *":$BIN_DIR:"*) : ;;
  *) say "NOTE: $BIN_DIR is not on your PATH. Add this to your shell rc:"
     printf '       export PATH="%s:$PATH"\n' "$BIN_DIR" ;;
esac

say "Done. Start it with:  grodex"
say "  (plain 'grok' is untouched — it still uses your normal xAI login.)"
