#!/usr/bin/env python3
"""Simple CLI chat client for an AIR Pro / Nova assistant.

Nova has no public REST "generate" endpoint; chat turns ride the RWG chat
websocket. This drives the supported `nova-cli chat` commands:

  chat start   -> api/start-conversation
  chat send    -> api/chat
  chat cancel  -> api/conversation/cancel
  chat end     -> api/conversation

Config comes from .env (see .env.example); identity and credentials come from
`nova-cli auth login`, cached in ~/.nova-cli/auth.env.
"""

import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime

NOVA_CLI_AUTH_ENV = os.path.expanduser("~/.nova-cli/auth.env")


def clock():
    return datetime.now().strftime("%H:%M:%S")


def load_env_file(path, override=False):
    if not os.path.exists(path):
        return
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            key, value = key.strip(), value.strip().strip("'\"")
            if override or key not in os.environ:
                os.environ[key] = value


class NovaCliError(Exception):
    pass


def nova_cli():
    exe = shutil.which("nova-cli")
    if not exe:
        sys.exit("nova-cli not found on PATH. Install it, then run: nova-cli auth login")
    return exe


def run_json(args, debug=False):
    """Run nova-cli and parse its JSON stdout."""
    cmd = [nova_cli(), *args]
    if debug:
        printable = [a if not a.startswith("--message") else "--message ..." for a in cmd]
        print(f"$ {' '.join(printable)}", file=sys.stderr)
    proc = subprocess.run(cmd, capture_output=True, text=True)
    out = proc.stdout.strip()
    if proc.returncode != 0 or not out:
        raise NovaCliError((proc.stderr.strip() or out or "no output").splitlines()[0])
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        raise NovaCliError(f"unexpected output: {out[:200]}")


def ensure_authenticated():
    try:
        status = run_json(["auth", "status"])
    except NovaCliError:
        status = {"status": "unauthenticated"}
    if status.get("status") == "unauthenticated":
        print("Not logged in. Running: nova-cli auth login-jwt\n", file=sys.stderr)
        if subprocess.run([nova_cli(), "auth", "login-jwt"]).returncode != 0:
            sys.exit("login failed")
        load_env_file(NOVA_CLI_AUTH_ENV, override=True)


def resolve_version_id(assistant_id):
    """Pick the published version of the assistant, else the highest version."""
    versions = run_json([
        "assistant", "versions",
        "--input-json", json.dumps({"assistantId": assistant_id}),
        "--body-only",
    ])
    if isinstance(versions, dict):
        versions = versions.get("records", [])
    if not versions:
        sys.exit(f"no versions found for assistant {assistant_id}")
    published = [v for v in versions if v.get("published")]
    best = max(published or versions, key=lambda v: v.get("version", 0))
    return str(best["versionId"])


class NovaChat:
    def __init__(self, assistant_id, version_id, channel, debug=False):
        self.assistant_id = assistant_id
        self.version_id = version_id
        self.channel = channel
        self.debug = debug
        self.conversation_id = None

    def _chat(self, subcommand, *extra):
        return run_json([
            "chat", subcommand,
            "--assistant-id", self.assistant_id,
            *extra,
            "--confirm",
        ], self.debug)

    def start(self):
        result = self._chat(
            "start",
            "--version-id", self.version_id,
            "--channel", self.channel,
        )
        self.conversation_id = result["conversationId"]
        return result.get("text", "").strip()

    def send(self, message):
        result = self._chat(
            "send",
            "--conversation-id", self.conversation_id,
            "--message", message,
        )
        return result.get("text", "").strip()

    def cancel(self):
        self._chat("cancel", "--conversation-id", self.conversation_id,
                   "--reason", "User canceled")

    def end(self):
        self._chat("end", "--conversation-id", self.conversation_id)


def main():
    load_env_file(".env")
    load_env_file(NOVA_CLI_AUTH_ENV)
    debug = "--debug" in sys.argv

    assistant_id = os.environ.get("NOVA_ASSISTANT_ID")
    if not assistant_id:
        sys.exit("set NOVA_ASSISTANT_ID in .env (see .env.example)")

    ensure_authenticated()

    version_id = os.environ.get("NOVA_VERSION_ID") or resolve_version_id(assistant_id)
    chat = NovaChat(
        assistant_id=assistant_id,
        version_id=version_id,
        channel=os.environ.get("NOVA_CHANNEL", "Webchat"),
        debug=debug,
    )

    started = time.monotonic()
    try:
        greeting = chat.start()
    except NovaCliError as exc:
        sys.exit(f"failed to start conversation: {exc}")
    elapsed = time.monotonic() - started

    print(f"assistant {assistant_id} v{version_id} | conversation {chat.conversation_id}")
    print("/new restarts, /quit ends the conversation and exits\n")
    if greeting:
        print(f"[{clock()} {elapsed:.2f}s] nova> {greeting}\n")

    while True:
        try:
            message = input(f"[{clock()}] you> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break
        if not message:
            continue
        if message in ("/quit", "/exit"):
            break

        started = time.monotonic()
        try:
            reply = chat.start() if message == "/new" else chat.send(message)
            print(f"[{clock()} {time.monotonic() - started:.2f}s] nova> {reply}\n")
        except KeyboardInterrupt:
            try:
                chat.cancel()
            except NovaCliError:
                pass
            print(f"\n[{clock()} {time.monotonic() - started:.2f}s] cancelled\n")
        except NovaCliError as exc:
            print(f"[{clock()} {time.monotonic() - started:.2f}s] error: {exc}\n", file=sys.stderr)

    try:
        chat.end()
        print("conversation ended")
    except NovaCliError as exc:
        print(f"[warn] could not end conversation: {exc}", file=sys.stderr)


if __name__ == "__main__":
    main()
