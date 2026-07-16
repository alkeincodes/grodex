# grodex

Run OpenAI's **GPT-5.6** models — **Sol**, **Terra**, and **Luna** — inside xAI's
**grok** terminal agent, billed to your **ChatGPT / Codex subscription**, as a
separate `grodex` command that leaves your normal `grok` untouched. Switch model
and reasoning effort (low / medium / high / xhigh) right in the TUI.

No fork, no rebuild. `grodex` is your *official* `grok` binary pointed at an
isolated config home, plus a tiny local bridge that reuses your `codex login`
session and translates between grok's request format and OpenAI's ChatGPT backend.

```
$ grodex
  … grok's TUI, but every token comes from GPT-5.6 (Sol/Terra/Luna) on your ChatGPT sub …
$ grok
  … still the normal xAI grok, unchanged …
```

---

## Requirements — what you need to run this fully

grodex is glue. It does **not** ship grok, codex, or a model — you bring those.
Everything below must be true before `./install.sh` will work end to end.

### 1. OS: macOS or Linux
The launcher is `bash` and the bridge is `python3`. Windows is not supported.

### 2. `python3` (3.8+)
Used by the auth bridge and the shim.
```sh
python3 --version      # any 3.8+ is fine
```

### 3. The official **grok CLI**, on your PATH
This is the actual agent; grodex just relaunches it with a different config home.
```sh
grok --version         # should print a version
# install if missing:
curl -fsSL https://x.ai/cli/install.sh | bash     # macOS / Linux
```

### 4. The **codex CLI**, signed in with a **ChatGPT/Codex subscription**
This is the critical one — grodex reuses your Codex session for auth. It must be
**subscription (ChatGPT) login**, *not* an API key, because subscription billing
only works against the ChatGPT backend.
```sh
codex --version
codex login            # choose "Sign in with ChatGPT" (NOT an API key)
```
After login, verify you have a subscription token (an `account_id`, and
`OPENAI_API_KEY` should be null/absent):
```sh
python3 - <<'PY'
import json, os
d = json.load(open(os.path.expanduser("~/.codex/auth.json")))
t = d.get("tokens") or {}
print("auth_mode      :", d.get("auth_mode"))
print("has account_id :", bool(t.get("account_id")))     # must be True
print("has api_key    :", bool(d.get("OPENAI_API_KEY")))  # should be False
PY
```
If `has account_id` is `False`, you're not on a subscription session — run
`codex login` and pick the ChatGPT option.

### 5. An active subscription that includes the **GPT-5.6** models
A ChatGPT Plus/Pro/Team (or equivalent) plan with Codex access to
`gpt-5.6-sol` / `gpt-5.6-terra` / `gpt-5.6-luna`. If your plan can't use a given
model in Codex itself, grodex can't either — requests will 4xx.

### 6. A free TCP port (default **8765**) and network access
The shim listens on `127.0.0.1:8765` and talks to `chatgpt.com` and
`auth.openai.com`. If 8765 is taken, install with a different port:
```sh
GRODEX_PROXY_PORT=8777 ./install.sh
```

### 7. `~/.local/bin` on your PATH (for the `grodex` command)
The installer drops the launcher there. If it warns that it's not on PATH, add:
```sh
export PATH="$HOME/.local/bin:$PATH"   # put this in ~/.zshrc or ~/.bashrc
```
(Or install elsewhere: `GRODEX_BIN_DIR=/usr/local/bin ./install.sh`.)

### Quick preflight (checks 2–4 at once)
```sh
for c in python3 grok codex; do command -v "$c" >/dev/null && echo "ok: $c" || echo "MISSING: $c"; done
test -f ~/.codex/auth.json && echo "ok: codex signed in" || echo "MISSING: run 'codex login'"
```

---

## Install

```sh
git clone <this-repo> grodex && cd grodex
./install.sh
grodex
```

The installer writes `~/.grodex`, reads *your* `account_id` from *your*
`~/.codex/auth.json`, drops a `grodex` launcher in `~/.local/bin`, and does a
one-time `grok login` (through the bridge) to establish the session. Your normal
`grok` / `~/.grok` is never touched.

## Usage

```sh
grodex                              # interactive TUI
grodex -p "explain this bug"        # headless / scripting
grodex -p "..." -m gpt-5.6-terra    # pick a model for one run
```

**Switching model & effort:**
- **Model** — `Ctrl+M` (or `/model gpt-5.6-terra`) to switch between Sol, Terra,
  and Luna.
- **Reasoning effort** — use grok's reasoning-effort control to switch between
  `low`, `medium`, `high`, and `xhigh` per session (default: `high`). `minimal`
  is intentionally omitted — the ChatGPT backend rejects it for these models.

Everything else is just grok — same keys, slash commands, config. Edit
`~/.grodex/config.toml` to change the default model, efforts, or port.

## Verify it's working

```sh
grodex -p "Reply with exactly: OK"
tail -1 ~/.grodex/codex-proxy.log
# → [codex-proxy] POST /responses -> 200 ... injected_output=True
```
The status bar in the TUI shows the selected model, e.g. `GPT-5.6 Sol (ChatGPT ...)`. (It will still
*say* "I'm Grok" if asked — that's grok's system prompt talking, not the model.
Routing is the real proof: every request goes through the shim to OpenAI.)

## Uninstall

```sh
./uninstall.sh
```
Removes the `grodex` command, `~/.grodex`, and the shim. Your `grok` and `codex`
are left alone.

---

## How it works

Two small pieces live in `~/.grodex`:

- **`codex-auth.sh`** — grok's *external auth provider*. Reads your
  `~/.codex/auth.json`, hands grok the ChatGPT access token, and silently
  refreshes it via OpenAI's `refresh_token` grant (falling back to `codex login`
  if needed).
- **`codex-proxy.py`** — a localhost shim that forwards to
  `https://chatgpt.com/backend-api/codex` and fixes the two things that
  otherwise make grok fail against that backend:
  1. **Request:** rewrites the system prompt's role `system` → `developer`
     (the ChatGPT backend rejects `system` messages).
  2. **Response:** the backend streams the assistant message but leaves the
     terminal `response.completed.output` array empty; grok reads that as an
     "empty response" and loops forever. The shim re-injects the streamed
     message so grok terminates cleanly.

`grodex` = official `grok` binary + `GROK_HOME=~/.grodex` (isolated config) +
lazy-started shim.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Not signed in` | Re-run `./install.sh` (it does the one-time `grok login`), or `GROK_HOME=~/.grodex grok login`. |
| `401 ... Could not parse your authentication token` | Your Codex session expired: `codex login`, then retry. |
| Answers repeat / never finishes | The shim isn't running or is an old version. `pkill -f codex-proxy.py` and run `grodex` again. |
| `4xx` about the model | Your plan may not have that GPT-5.6 model (Sol/Terra/Luna) in Codex. |
| `grodex: command not found` | `~/.local/bin` isn't on PATH (see requirement 7). |

## Caveats — read these

- **Gray area vs OpenAI's terms.** Routes ChatGPT-subscription tokens through a
  non-Codex client. Fine for personal use; OpenAI could rate-limit, block, or
  flag accounts, and could break it any time by changing the backend.
- **Context is capped ~272K**, not the 1M the API advertises — that's OpenAI's
  server-side Codex-subscription cap, not a grodex setting.
- **Brittle.** The two fixes target current backend quirks; if OpenAI changes
  the Codex responses format, `lib/codex-proxy.py` needs updating.
- Not affiliated with xAI or OpenAI. Use at your own risk. See `LICENSE`.

## Layout

```
grodex/
  install.sh              # sets up ~/.grodex + the `grodex` command
  uninstall.sh
  LICENSE
  lib/
    codex-auth.sh         # grok external auth provider (Codex token + refresh)
    codex-proxy.py        # localhost shim (request/response fixes)
    config.toml.template  # grok config, filled in at install time
```
