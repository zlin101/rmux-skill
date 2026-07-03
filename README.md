# rmux-skill

> A skill that teaches AI agents to discover, talk to, read, and synchronize **other terminal-based agents** through [rmux](https://github.com/Helvesec/rmux) — a universal, tmux-compatible Rust terminal multiplexer that runs natively on Linux, macOS, and Windows.

**English** · [简体中文](./README.zh-CN.md)

---

## Why

When multiple coding agents (Claude Code, Codex, etc.) run at once, they each live in their own terminal session — isolated, with no built-in way to see or message each other. `rmux-skill` gives an orchestrator agent the **vocabulary to coordinate a fleet**: find which panes are which agents, hand them tasks, read back their rendered output, and wait for them to finish.

It is a pure knowledge skill: no runtime, no dependencies beyond `rmux` itself. Every command is plain `rmux`/`tmux` CLI that the agent learns to compose.

## Use it when…

- You want one agent to **dispatch work** to another ("ask the worker agent to implement `foo()`").
- You need to **read another agent's reply** by capturing its rendered pane.
- Agents should exchange **payloads** (JSON, diffs, logs) via a shared mailbox.
- You're **synchronizing** agents — one waits until another signals completion.
- You're building a **multi-agent workflow** and need tmux-style orchestration primitives.

> 📄 The installable skill instructions live in [`rmux-skill/SKILL.md`](./rmux-skill/SKILL.md). This README is for humans; the `SKILL.md` is what the agent loads. A Chinese README is kept at [`README.zh-CN.md`](./README.zh-CN.md).

## The core loop

```
discover ─▶ send ─▶ read ─▶ (share / sync)
            send-keys    capture-pane    buffers / wait-for
```

## RMUX mode protocol

When the master/orchestrator enters rmux mode, it treats that as a fleet state change: discover live agent panes, build a roster, broadcast one notice to every other agent pane, then use pane ids for later messages. Every inter-agent notification should end with:

```text
[pane %PANE_ID, SIGNATURE]
```

Example:

```sh
rmux send-keys -t %1 'RMUX mode is active. Please use rmux to reply when needed. [pane %0, Codex]' Enter
```

This suffix gives each recipient the sender pane and a human-readable signature, so replies can be routed back without guessing. The master entry flow is: identify self, list panes, filter live agent CLIs, exclude self, broadcast once, remember the roster. After broadcasting, the master should not continuously poll for replies unless the workflow explicitly needs it.

Direct `send-keys` writes into the target pane's current input. Use it when the target appears idle or the user explicitly wants prompt injection; use buffers for large, structured, or non-ASCII payloads.

| Step | Do | Command |
|------|----|---------|
| **Discover** | Find the other agents | `rmux -L fleet list-panes -a` |
| **Send** | Type into an agent's pane | `rmux -L fleet send-keys -t bob 'do X' Enter` |
| **Read** | Capture its rendered reply | `rmux -L fleet capture-pane -t bob -p` |
| **Share** | Exchange a payload | `rmux -L fleet set-buffer -b inbox.bob '...'` |
| **Sync** | Block until signalled | `rmux -L fleet wait-for -L chan.task1` |

## Install

### Quick install

Install directly from the published script, without cloning this repository.

For Codex:

```sh
curl -fsSL https://raw.githubusercontent.com/zlin101/rmux-skill/main/install.sh | sh -s -- codex
```

For Claude Code:

```sh
curl -fsSL https://raw.githubusercontent.com/zlin101/rmux-skill/main/install.sh | sh -s -- claude
```

To inspect before running:

```sh
curl -fsSL https://raw.githubusercontent.com/zlin101/rmux-skill/main/install.sh -o /tmp/rmux-skill-install.sh
less /tmp/rmux-skill-install.sh
sh /tmp/rmux-skill-install.sh codex
```

Pin a branch or tag:

```sh
RMUX_SKILL_REF=<tag-or-commit> sh /tmp/rmux-skill-install.sh codex
```

Restart Codex, Claude Code, or reload skills if your environment requires it.

### 1. Install rmux (required dependency)

`rmux` is the terminal multiplexer this skill drives. Install it from the [rmux project](https://github.com/Helvesec/rmux):

| Platform | Command |
|---|---|
| macOS (Homebrew) | `brew install rmux` |
| Windows (WinGet) | `winget install rmux` |
| Windows (Chocolatey) | `choco install rmux` |
| Windows (Scoop) | `scoop bucket add rmux https://github.com/Helvesec/scoop-rmux && scoop install rmux` |
| Windows (PowerShell) | `irm https://rmux.io/install.ps1 \| iex` |
| Linux / macOS (Nix) | `nix profile install github:Helvesec/rmux` |
| Any (Cargo) | `cargo install rmux --locked` |
| Linux (APT / DNF) | see the [rmux install guides](https://github.com/Helvesec/rmux#-installation) |

Verify it's on your `$PATH`: `rmux -V`, then `rmux diagnose` (or `rmux capabilities`).

> The skill assumes an **isolated rmux server** via `-L SOCKET` so agent fleets never disturb your real tmux sessions. Full docs: [rmux.io/docs](https://rmux.io/docs).

### 2. Install the skill

This repo ships one self-contained, installable skill directory:

```
rmux-skill/        # English skill — SKILL.md
```

Install `rmux-skill/`. Its `SKILL.md` is a markdown file the agent reads on demand — drop it wherever your agent loads skills from. The Chinese README is documentation only, not a separate installable skill.

**Claude Code** — install to `~/.claude/skills/rmux-skill/` (so the file lands at `~/.claude/skills/rmux-skill/SKILL.md`), or reference this repo from a plugin.

**Codex** — install to `~/.codex/skills/rmux-skill/` (so the file lands at `~/.codex/skills/rmux-skill/SKILL.md`).

**Other agents** that support file-based skills — point them at `rmux-skill/SKILL.md`. The content is platform-agnostic instructions; it tells the agent *what to do*, not which runtime tool to call.

Expected installed layout:

```text
~/.claude/skills/rmux-skill/
└── SKILL.md

~/.codex/skills/rmux-skill/
└── SKILL.md
```

## Quick start

Spin up two agents in a private fleet, hand one a task, and read the reply:

```sh
S=-L fleet
rmux $S start-server
rmux $S new-session -d -s planner 'codex'   # agent A
rmux $S new-session -d -s worker  'claude'  # agent B

# who's out there?
rmux $S list-panes -a -F '#{session_name}|#{pane_id}|#{pane_current_command}'

# planner -> worker: send a task, then read the reply
rmux $S send-keys -t worker 'implement foo()' Enter
sleep 2
rmux $S capture-pane -t worker -p -S -30 | sed '/^$/d'

rmux $S kill-server   # tear down the fleet
```

## Mental model & addressing

- **One agent = one rmux session** (recommended), running its own REPL/command.
- Spawn detached: `rmux new-session -d -s NAME 'agent-command'`.
- **Targets** (`-t`) address a pane by:
  - session name → its active pane: `bob`
  - `session:window.pane`: `bob:0.0`
  - stable pane id: `%3`
- **Socket isolation:** prefix every command with `-L SOCKET` (e.g. `-L fleet`). Pick one socket per fleet and use it everywhere — never touch the user's default sessions.
- rmux ships a private `tmux` shim, so `tmux ...` routes to rmux inside command environments (disable with `RMUX_DISABLE_TMUX_SHIM=1`).

## The five primitives

1. **Discover** — `list-sessions` / `list-panes` with format variables (`#{session_name}`, `#{pane_id}`, `#{pane_current_command}`, `#{pane_pid}`, `#{pane_dead}`) build the real agent roster. Filter with `-f`, query one attribute with `display-message -p`.
2. **Send** — `send-keys -t T 'text' Enter`. `Enter` is a *separate argument* that submits. Use `-l` for **literal** payloads (so `; $ # !` aren't interpreted as keys); move large/structured payloads through buffers instead.
3. **Read** — `capture-pane -t T -p` prints rendered text. `-S -50 -E -` grabs scrollback, `-J` joins wrapped lines, `-e` keeps colors. Agents render asynchronously, so **poll** until a marker appears.
4. **Share (buffers)** — `set-buffer`/`show-buffer`/`paste-buffer`/`save-buffer`/`load-buffer` form a cross-agent mailbox. Note `paste-buffer` types **without** a trailing `Enter`.
5. **Sync (`wait-for`)** — named channels: `-L` wait, `-S` signal/lock, `-U` release.

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
| Health / build info | `rmux capabilities` / `rmux diagnose` |

## Gotchas

- **Forgetting `Enter`** — `send-keys 'ls'` types but doesn't run it; add a trailing `Enter` argument.
- **Special chars mangled** — `; $ # !` get interpreted as keys/format. Use `send-keys -l`, or route big payloads through buffers.
- **Wrong server** — commands without `-L` hit the user's default socket. Standardize on one `-L SOCKET`.
- **Reading too early** — capture right after send often shows nothing; poll until a marker appears.
- **Target ambiguity** — a bare session name targets its *active* pane; address splits exactly with `%pane_id` or `session:win.pane`.
- **Dead agents** — a finished REPL exits the pane. Check `#{pane_dead}` / `#{pane_dead_status}` before reading silence as "still thinking".
- **Padding / doubled lines** — `capture-pane -p` pads to pane height (`sed '/^$/d'`), and foreground programs echo input (so a line may appear twice).

## Beyond the CLI

- **Rust SDK** `rmux-sdk` — typed, daemon-backed API (`ensure_session`, `pane.send_text`, `pane.expect_visible_text`, snapshots, streaming). Use when *code* is the driver.
- **Python SDK** `librmux`.
- **Browser share** `rmux web-share` — expose a pane/session in a browser (E2E encrypted); for human observation, not agent IPC.
- **Capabilities** `rmux capabilities --json` / `rmux diagnose --json` — negotiate daemon features and debug.

## License

See the repository for license details.
