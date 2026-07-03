---
name: rmux-skill
description: Use when coordinating multiple terminal-based agents through rmux — e.g. discovering which rmux sessions/panes represent other agents, sending a command or message into another agent's pane, reading another agent's rendered output, exchanging payloads via shared buffers, or synchronizing agents with wait-for. Also triggers on mentions of rmux, tmux-style agent orchestration, "the other agent", or terminal multiplexing for multi-agent workflows.
---

# RMUX Agent Communication

## Overview

`rmux` is a tmux-compatible terminal multiplexer (Rust). **Each agent runs in its own rmux session/pane.** You discover other agents by listing sessions and panes; you make agents talk by typing into each other's panes; you read replies by capturing a pane's rendered text. This skill covers the CLI primitives for multi-agent discovery and communication.

Core loop: **discover** (`list-sessions` / `list-panes`) → **send** (`send-keys`) → **read** (`capture-pane`) → optionally **share** (buffers) / **sync** (`wait-for`).

> All commands below are live-verified against `rmux`. Flags mirror tmux; run `rmux <command> --help` for the full surface, and `rmux list-commands` for every command.

## RMUX mode protocol

When the user asks the master/orchestrator to enter **rmux mode**, treat it as a state change for the whole agent fleet, not just as a one-off message. The master must discover the live agent panes, announce coordination, and remember the resulting roster for later sends.

Use this notification suffix on every inter-agent message:

```text
[pane %PANE_ID, SIGNATURE]
```

Rules:
- `PANE_ID` is the sender's pane id, such as `%0` or `%3`.
- `SIGNATURE` is a short sender identity, such as `Codex`, `Claude`, `master`, `worker`, or `codex/%0`.
- Put the suffix at the end of the message so recipients can identify who sent it and where to reply.
- Use the same suffix for broadcast notices, task handoffs, status updates, and replies.
- If you are not inside rmux, discover your own pane from `RMUX_PANE`, `TMUX`, or `list-panes` before sending. If it cannot be determined, use `[pane unknown, SIGNATURE]`.

Master entry checklist:
1. Determine the master's own pane id (`RMUX_PANE` if present; otherwise infer it from the active pane/session or the known orchestration pane).
2. List all panes with `pane_id`, `pane_current_command`, `pane_title`, and `pane_dead`.
3. Build an agent roster from live panes whose foreground command looks like an agent CLI (`codex`, `claude`, `gemini`, `aider`, `cursor-agent`, `opencode`, etc.).
4. Exclude the master's own pane from the broadcast targets.
5. Send one rmux-mode notice to every remaining agent pane, with the suffix.
6. Store the roster mentally for the current task so later messages can target pane ids directly.
7. Do not wait on replies unless the user asks you to wait or the workflow requires an acknowledgement.

Example:

```sh
rmux send-keys -t %1 'RMUX mode is active. Please use rmux to reply when needed. [pane %0, Codex]' Enter
```

Reference shell flow for entering rmux mode as master:

```sh
ME=${RMUX_PANE:-%0}
SIG=Codex
rmux list-panes -a -F '#{pane_id}|#{pane_current_command}|#{pane_title}|#{pane_dead}' |
  while IFS='|' read -r pane cmd title dead; do
    [ "$dead" = "0" ] || continue
    [ "$pane" = "$ME" ] && continue
    case "$cmd" in codex|claude|gemini|aider|cursor-agent|opencode)
      rmux send-keys -t "$pane" "RMUX mode is active. I am coordinating this session. Reply through rmux when useful; include your pane/signature suffix. [pane $ME, $SIG]" Enter
      ;;
    esac
  done
```

After the broadcast, do not continuously poll for replies unless the user asks you to wait, a deadline/marker was agreed, or the next step depends on that reply. Prefer sending the notice/task and continuing with useful local work.

### Direct-send cautions

Direct `send-keys ... Enter` writes into whatever the target pane is doing. If a human or another agent is typing in that pane, direct sends can corrupt the input line. Prefer direct sends only when the target appears idle or the user explicitly wants prompt injection.

For large, structured, or non-ASCII payloads, prefer `set-buffer` + `paste-buffer`; direct `send-keys` may mangle content or fail on some builds.

## Mental model & addressing

- An **agent** = one rmux **session** (recommended) or a **pane** inside it.
- Spawn an agent detached: `rmux new-session -d -s NAME 'agent-command'`.
- **Targets** (`-t`) address a pane by any of:
  - session name → its active pane: `bob`
  - session:window.pane: `bob:0.0`
  - pane id (stable across moves): `%3`
- **Socket isolation:** add `-L SOCKET` to every command to use a private rmux server (do NOT touch the user's real sessions). Pick one socket per fleet and use it everywhere. Example: `rmux -L fleet list-sessions`.
- rmux also ships a private `tmux` shim, so `tmux ...` commands route to rmux inside command environments (disable with `RMUX_DISABLE_TMUX_SHIM=1`).

## 1. Discover other agents

List every agent (session):
```sh
rmux -L fleet list-sessions
# bob: 1 windows ...
# alice: 1 windows ...
```

Enumerate every pane across all sessions — this is the real agent roster. Use format variables to expose identity:
```sh
rmux -L fleet list-panes -a -F '#{session_name}|#{pane_id}|#{pane_current_command}|#{pane_pid}|#{pane_title}'
# bob|%1|claude|84123|worker
# alice|%0|codex|84001|planner
```

Useful format variables: `#{session_name}`, `#{window_index}`, `#{pane_index}`, `#{pane_id}`, `#{pane_current_command}` (foreground program — what the agent is), `#{pane_pid}`, `#{pane_title}`, `#{pane_dead}`, `#{pane_dead_status}` (detect a crashed/exited agent).

Query a single pane's attribute directly:
```sh
rmux -L fleet display-message -t bob -p '#{pane_current_command}'
# claude
```

Filter panes (e.g. find every pane running `claude`):
```sh
rmux -L fleet list-panes -a -f '#{m:claude,#{pane_current_command}}' -F '#{session_name}|#{pane_id}'
```
`-f` accepts a tmux format that must evaluate truthy; `#{m:pat,str}` is a glob match.

## 2. Send a message / command to another agent

Type into the target pane's foreground program:
```sh
rmux -L fleet send-keys -t bob 'please review src/cli.rs' Enter
```
- `Enter` is a **separate argument** (a key name, sent after the text). Omit it to type without submitting.
- For **literal** text containing special characters (`;`, `'`, `#`, `$`, `!`), add `-l` so nothing is interpreted as a key name:
  ```sh
  rmux -L fleet send-keys -l -t bob 'a && b; echo $HOME #not-a-comment'
  ```
- Without `-l`, names like `Enter`, `C-c`, `Up`, `Escape`, `Space` are treated as keys.

> `send-keys` types into whatever the pane is currently running. If the agent's REPL isn't at a prompt (e.g. mid-thought, in a pager), input may be swallowed or misinterpreted. Prefer a well-defined agent input contract (a prompt or a command channel the agent reads).

## 3. Read another agent's output

Capture the pane's rendered text to stdout:
```sh
rmux -L fleet capture-pane -t bob -p
```
- `-p` → print to stdout (instead of into a buffer). Almost always what you want.
- `-S START -E END` → line range; use `-S -50 -E -` for ~50 lines of **scrollback** above the visible screen.
- `-J` → join wrapped (soft-broken) lines into one line each.
- `-e` → keep ANSI/escape sequences (colors). Omit for plain text.
- Output includes blank/padding lines — filter them (e.g. `| sed '/^$/d'`).

Poll for a reply until it appears (agents render asynchronously):
```sh
for i in $(seq 1 30); do
  out=$(rmux -L fleet capture-pane -t bob -p -S -20 | sed '/^$/d')
  echo "$out" | grep -q 'DONE_MARKER' && { echo "$out"; break; }
  sleep 1
done
```

## 4. Shared message bus via buffers

Named buffers are a cross-agent mailbox — any pane can write, any pane can read:
```sh
# alice writes a payload
rmux -L fleet set-buffer -b inbox.bob 'payload JSON or text'

# bob (or you) reads it
rmux -L fleet show-buffer -b inbox.bob

# paste it into bob's pane as typed input
rmux -L fleet paste-buffer -b inbox.bob -t bob

# NOTE: paste-buffer types the buffer WITHOUT a trailing Enter — unlike
# `send-keys 'text' Enter`. To submit it as a complete line to the agent's
# prompt/REPL, send the key yourself:
rmux -L fleet send-keys -t bob Enter

# persist / reload across runs
rmux -L fleet save-buffer -b inbox.bob ./msg.bob
rmux -L fleet load-buffer -b inbox.bob ./msg.bob

# inventory + cleanup
rmux -L fleet list-buffers
rmux -L fleet delete-buffer -b inbox.bob
```
Buffers survive until the server stops. Use a naming convention (`inbox.<agent>`, `topic.<x>`) to model channels.

## 5. Synchronize agents with `wait-for`

Named channels let one agent block until another signals:
```sh
# agent/workflow waits (blocks) until the channel is signaled
rmux -L fleet wait-for -L chan.task1

# elsewhere, signal/release it
rmux -L fleet wait-for -U chan.task1
```
Flags: `-L` wait on the channel, `-S` signal/lock, `-U` release. Verify exact flag semantics with `rmux wait-for --help` on your build, then use one consistent convention.

## Full lifecycle (orchestrator)

```sh
S=-L fleet
rmux $S start-server
rmux $S new-session -d -s planner 'codex'   # agent A
rmux $S new-session -d -s worker  'claude'  # agent B

# discover
rmux $S list-panes -a -F '#{session_name}|#{pane_id}|#{pane_current_command}'

# planner -> worker: send a task, then read the worker's reply
rmux $S send-keys -t worker 'implement foo()' Enter
sleep 2
rmux $S capture-pane -t worker -p -S -30 | sed '/^$/d'

# share a result via buffer
rmux $S set-buffer -b result.worker "$(rmux $S capture-pane -t worker -p -S -5)"

rmux $S kill-server   # tear down the whole fleet
```

## Quick reference

| Goal | Command |
|---|---|
| Spawn agent (detached) | `rmux -L s new-session -d -s NAME 'cmd'` |
| List agents | `rmux -L s list-sessions` |
| Enumerate all panes | `rmux -L s list-panes -a -F '#{session_name}|#{pane_id}|#{pane_current_command}|#{pane_pid}'` |
| Query one pane attribute | `rmux -L s display-message -t T -p '#{var}'` |
| Filter panes | `rmux -L s list-panes -a -f '#{m:pat,#{pane_current_command}}' -F '#{session_name}'` |
| Send input to agent | `rmux -L s send-keys -t T 'text' Enter` (add `-l` for literal) |
| Read agent output | `rmux -L s capture-pane -t T -p` (scrollback: `-S -50 -E -`) |
| Write mailbox | `rmux -L s set-buffer -b NAME 'data'` |
| Read mailbox | `rmux -L s show-buffer -b NAME` |
| Mailbox → typed input | `rmux -L s paste-buffer -b NAME -t T` |
| Sync channel | `rmux -L s wait-for -L\|-S\|-U CHANNEL` |
| Kill one agent | `rmux -L s kill-session -t NAME` |
| Kill whole fleet | `rmux -L s kill-server` |
| Health/build info | `rmux capabilities` / `rmux diagnose` |

## Common mistakes

- **Forgetting `Enter`.** `send-keys -t bob 'ls'` types `ls` but doesn't run it — add a trailing `Enter` argument.
- **Special chars mangled.** `; $ # !` get interpreted as keys/format. Use `send-keys -l` for literal payloads, or move big payloads through **buffers** instead.
- **Wrong server.** Commands without `-L` hit the user's default socket and can disturb real sessions. Standardize on one `-L SOCKET` for the fleet.
- **Reading too early.** An agent renders asynchronously; `capture-pane` right after `send-keys` often shows nothing. Poll until a marker appears (see §3).
- **Target ambiguity.** A bare session name targets its *active* pane; if windows were split, address the exact pane with `%pane_id` or `session:win.pane`.
- **Dead agents.** A finished REPL exits the pane. Check `#{pane_dead}` / `#{pane_dead_status}` before assuming silence means "still thinking".
- **Blank lines in captures.** `capture-pane -p` pads to the pane height; strip empties with `sed '/^$/d'` before parsing.
- **Doubled lines in captures.** The foreground program often echoes the input you `send-keys` (e.g. `cat`, a shell), so capture may show the line twice (typed echo + re-render). What `capture-pane` shows is whatever that program renders — not a duplicate send.

## Beyond the CLI

- **Rust SDK** `rmux-sdk` — daemon-backed typed API (`ensure_session`, `pane.send_text`, `pane.expect_visible_text`, snapshots, streaming). Use when *code* is the driver. See `docs/scripting-sdk.md`.
- **Python SDK** `librmux`.
- **Browser share** `rmux web-share` — expose a pane/session in a browser (E2E encrypted). Not for agent-to-agent IPC, but useful for human observation.
- **Capabilities** `rmux capabilities --json` / `rmux diagnose --json` — negotiate daemon features, debug build/runtime.
