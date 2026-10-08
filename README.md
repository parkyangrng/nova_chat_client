# Nova chat client

A small CLI that holds a conversation with a RingCentral AIR Pro / Nova assistant.

`nova_chat.py` is Python stdlib only — no `pip install` needed. It drives `nova-cli`,
which owns authentication and the chat websocket.

```
you> what vegetarian dishes do you have?
nova> We have several plant-forward options...
```

## 1. Install nova-cli

The installer package lives in [`nova-cli-dist/`](nova-cli-dist/README.md).

**Offline (recommended)** — the bundle ships binaries for linux/darwin × amd64/arm64:

```sh
tar -xzf nova-cli-dist/dist/nova-cli-0.10.14.tar.gz
./nova-cli-0.10.14/install.sh --offline
```

**Online** — downloads the latest stable build from GitLab:

```sh
./nova-cli-dist/install.sh
```

Both install to `~/.local/bin/nova-cli` and verify the binary's SHA-256 before
moving it into place. Pass `--install-dir DIR` to put it elsewhere, or
`--dry-run` to see what would happen.

Make sure the install dir is on your `PATH`:

```sh
export PATH="$HOME/.local/bin:$PATH"   # add to ~/.zshrc or ~/.bashrc
nova-cli --version
```

## 2. Log in

```sh
nova-cli auth login
```

You will be prompted for the API base URL, OAuth token URL, client ID, client
secret, and JWT. Credentials are cached in `~/.nova-cli/auth.env`, along with
your account id, extension id, and environment — `nova_chat.py` reads identity
from there, so you never put it in `.env`.

Check it worked:

```sh
nova-cli auth status
```

If you skip this step, `nova_chat.py` runs `auth login-jwt` for you on first use.

Other login modes: `nova-cli auth login` (interactive) and
`nova-cli auth login-browser`. Add `--env lab01|xmn02|stage|dev|aqa` for
non-production. Default is production.

## 3. Configure .env

Copy the template and set the assistant you want to talk to:

```sh
cp .env.example .env
```

```sh
# .env
NOVA_ASSISTANT_ID=3159
```

`NOVA_ASSISTANT_ID` is the only required setting. Optional:

| Variable | Default | Notes |
| --- | --- | --- |
| `NOVA_ASSISTANT_ID` | — | **Required.** Numeric assistant id. |
| `NOVA_VERSION_ID` | published version | Pin a specific version instead of auto-resolving. |
| `NOVA_CHANNEL` | `Webchat` | Deployment channel: `Webchat`, `PBX`, `SMS`, `Email`. |

### Finding your assistant id

```sh
nova-cli assistant list --body-only
```

Each record has an `id` (that's `NOVA_ASSISTANT_ID`), a `name`, and the current
`versionId` / `published` flag. To see every version of one assistant:

```sh
nova-cli assistant versions --input-json '{"assistantId":"3159"}' --body-only
```

`nova_chat.py` picks the published version automatically, so you only need
`NOVA_VERSION_ID` when testing an unpublished draft.

## 4. Chat

```sh
python3 nova_chat.py
```

```
assistant 3159 v14220 | conversation b607fdb0-ee43-4c10-8f37-27281a371198
/new restarts, /quit ends the conversation and exits

nova> Hi, thanks for contacting Paladar. How can I help you today?

you> what are your hours?
nova> We're open 11am to 10pm, seven days a week.

you> /quit
conversation ended
```

Commands inside the session:

| Input | Effect |
| --- | --- |
| `/new` | Start a fresh conversation with the same assistant |
| `/quit` or `/exit` | End the conversation and exit |
| `Ctrl-C` during a reply | Cancel that turn, keep the conversation |
| `Ctrl-C` at the prompt | Exit |

Add `--debug` to print each `nova-cli` command as it runs:

```sh
python3 nova_chat.py --debug
```

These are **real conversations** against whatever environment you logged into.
If you are signed in to production, they hit the live assistant.

## How it works

There is no public REST "generate" endpoint — Nova chat turns ride the RWG chat
websocket. `nova_chat.py` shells out to the `nova-cli chat` commands that speak
it, and parses their JSON:

| Python | nova-cli | websocket path |
| --- | --- | --- |
| `chat.start()` | `chat start` | `api/start-conversation` |
| `chat.send()` | `chat send` | `api/chat` |
| `chat.cancel()` | `chat cancel` | `api/conversation/cancel` |
| `chat.end()` | `chat end` | `api/conversation` |

Config precedence: existing environment variables win, then `.env`, then
`~/.nova-cli/auth.env`.

## Troubleshooting

**`nova-cli not found on PATH`** — install it (step 1) and make sure the install
directory is exported in your shell profile.

**`set NOVA_ASSISTANT_ID in .env`** — you have no `.env`, or the key is blank.
Note that `.env.example` is only a template; the client reads `.env`.

**`failed to start conversation: ...`** — usually auth or a bad id. Run
`nova-cli auth status`, then confirm the assistant exists with
`nova-cli assistant list --body-only`.

**`no versions found for assistant <id>`** — the id is wrong, or it belongs to a
different account than the one you logged into.

**Wrong environment** — `nova-cli auth status` shows the active environment. Log
in again with `--env` to switch.

## Files

```
nova_chat.py        the chat client
.env.example        config template; copy to .env
nova-cli-dist/      installer package for nova-cli (see its own README)
```
