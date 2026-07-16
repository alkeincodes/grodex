#!/usr/bin/env bash
#
# Grok Build external auth provider — bridges your ChatGPT/Codex subscription
# credentials (~/.codex/auth.json) into Grok Build so it can call the ChatGPT
# backend Responses API (chatgpt.com/backend-api/codex) with your session.
#
# Contract (Grok docs → "External Auth Provider"):
#   stdout : the access token as JSON {"access_token": "...", "expires_in": N}
#            — and NOTHING else. Grok parses stdout as the token.
#   stderr : human-readable status / login URLs (surfaced to the user).
#   exit 0 : success; non-zero → Grok falls back to interactive login.
#
# Behaviour:
#   * Reads the Codex access token and checks its JWT `exp`.
#   * If still valid (beyond the early-invalidation window) and not a forced
#     refresh, emits it as-is.
#   * Otherwise refreshes via the OpenAI refresh_token grant and rewrites
#     ~/.codex/auth.json atomically. If that fails (or no refresh token),
#     falls back to `codex login` (opens the browser).
#
# Grok re-runs this with GROK_AUTH_EXPIRED=1 to force a refresh near expiry
# or on a 401.
#
set -euo pipefail

AUTH_FILE="${CODEX_AUTH_FILE:-$HOME/.codex/auth.json}"
CLIENT_ID="${CODEX_OAUTH_CLIENT_ID:-app_EMoamEEZ73f0CkXaXp7hrann}"
TOKEN_URL="${CODEX_OAUTH_TOKEN_URL:-https://auth.openai.com/oauth/token}"
EARLY="${GROK_AUTH_EARLY_INVALIDATION_SECS:-300}"
FORCED="${GROK_AUTH_EXPIRED:-0}"

exec python3 - "$AUTH_FILE" "$CLIENT_ID" "$TOKEN_URL" "$EARLY" "$FORCED" <<'PY'
import base64, json, os, sys, time, urllib.request, urllib.error

auth_file, client_id, token_url, early, forced = sys.argv[1:6]
early = int(early)
forced = forced not in ("", "0", "false", "False")

def log(*a):
    print(*a, file=sys.stderr, flush=True)

def b64url(seg):
    seg += "=" * (-len(seg) % 4)
    return json.loads(base64.urlsafe_b64decode(seg))

def jwt_exp(tok):
    try:
        return int(b64url(tok.split(".")[1]).get("exp"))
    except Exception:
        return None

def load():
    with open(auth_file) as f:
        return json.load(f)

def codex_login():
    import subprocess
    log("Opening browser for ChatGPT (Codex) sign-in via `codex login`…")
    # Never let codex's stdout leak into OUR stdout (it would corrupt the token).
    subprocess.run(["codex", "login"], stdout=sys.stderr, stderr=sys.stderr, check=False)

def refresh(data):
    rt = (data.get("tokens") or {}).get("refresh_token")
    if not rt:
        log("No refresh_token present; launching interactive login.")
        codex_login()
        return load()
    body = json.dumps({
        "client_id": client_id,
        "grant_type": "refresh_token",
        "refresh_token": rt,
        "scope": "openid profile email",
    }).encode()
    req = urllib.request.Request(
        token_url, data=body,
        headers={"Content-Type": "application/json", "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            resp = json.load(r)
    except urllib.error.HTTPError as e:
        detail = ""
        try:
            detail = e.read().decode()[:300]
        except Exception:
            pass
        log(f"Refresh grant failed (HTTP {e.code}): {detail}")
        log("Falling back to interactive login.")
        codex_login()
        return load()
    except Exception as e:
        log(f"Refresh grant error: {e}")
        codex_login()
        return load()
    if not resp.get("access_token"):
        log("Refresh response missing access_token; falling back to login.")
        codex_login()
        return load()
    tk = data.setdefault("tokens", {})
    tk["access_token"] = resp["access_token"]
    if resp.get("refresh_token"):
        tk["refresh_token"] = resp["refresh_token"]
    if resp.get("id_token"):
        tk["id_token"] = resp["id_token"]
    data["last_refresh"] = time.strftime("%Y-%m-%dT%H:%M:%S.000000Z", time.gmtime())
    tmp = auth_file + ".grok.tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
    os.chmod(tmp, 0o600)
    os.replace(tmp, auth_file)
    log("Codex token refreshed; ~/.codex/auth.json updated.")
    return data

try:
    data = load()
except FileNotFoundError:
    log(f"{auth_file} not found — signing in with `codex login`.")
    codex_login()
    data = load()

access = (data.get("tokens") or {}).get("access_token")
exp = jwt_exp(access) if access else None
now = int(time.time())
need_refresh = forced or (not access) or (exp is None) or (exp - now <= early)

if need_refresh:
    reason = "forced" if forced else ("no/invalid token" if not exp else f"expires in {exp - now}s")
    log(f"Refreshing Codex token ({reason})…")
    data = refresh(data)
    access = (data.get("tokens") or {}).get("access_token")
    exp = jwt_exp(access) if access else None

if not access:
    log("Failed to obtain a Codex access token.")
    sys.exit(1)

now = int(time.time())
expires_in = max(60, (exp - now)) if exp else 3600
print(json.dumps({"access_token": access, "expires_in": expires_in}))
PY
