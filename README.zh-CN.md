# rmux-skill

> 一个 skill，教会 AI agent 通过 [rmux](https://github.com/Helvesec/rmux) —— 一个通用、兼容 tmux 的 Rust 终端复用器，在 Linux、macOS、Windows 上原生运行 —— 去**发现、对话、读取并同步其他基于终端的 agent**。

[English](./README.md) · **简体中文**

---

## 为什么需要

当多个 coding agent（Claude Code、Codex 等）同时运行时，它们各自待在自己的终端 session 里——彼此隔离，没有内建的方式互相看见或互发消息。`rmux-skill` 给编排者 agent 一套**协调整个集群的词汇**：找出哪些 pane 是哪些 agent、把任务交给它们、读回它们渲染出来的输出、并等待它们完成。

它是一个纯知识 skill：没有运行时，除了 `rmux` 本身之外没有别的依赖。每条命令都是普通的 `rmux`/`tmux` CLI，由 agent 学习如何组合使用。

## 何时使用

- 你想让一个 agent 向另一个 **派发任务**（"让 worker agent 实现 `foo()`"）。
- 你需要通过捕获另一个 agent 已渲染的 pane 来 **读取它的回复**。
- agent 之间需要通过共享邮箱交换 **载荷**（JSON、diff、日志）。
- 你在 **同步** 多个 agent —— 一个等到另一个发出完成信号。
- 你在搭建 **多 agent 工作流**，需要 tmux 风格的编排原语。

> 📄 可安装的 skill 指令在 [`rmux-skill/SKILL.md`](./rmux-skill/SKILL.md)。本 README 是保留给人阅读的中文说明；`SKILL.md` 才是 agent 加载的文件。

## 核心循环

```
发现 ─▶ 发送 ─▶ 读取 ─▶（共享 / 同步）
        send-keys    capture-pane    buffers / wait-for
```

## RMUX 模式协议

当 master/编排者进入 rmux 模式时，这不是一次普通消息，而是整个 agent fleet 的状态切换：发现存活 agent pane、建立名册、向除自己以外的 agent pane 广播一次通知，之后用 pane id 定向发消息。每条 agent 间通知都应以后缀结尾：

```text
[pane %PANE_ID, SIGNATURE]
```

示例：

```sh
rmux send-keys -t %1 'RMUX mode is active. Please use rmux to reply when needed. [pane %0, Codex]' Enter
```

这个后缀让接收方知道发送者 pane 和可读署名，回复时不需要猜目标。master 进入流程是：识别自己、列出 panes、筛选存活 agent CLI、排除自己、广播一次、记住名册。广播后，除非工作流明确需要等待，否则 master 不应持续轮询回复。

`send-keys` 会写入目标 pane 当前输入位置。只有在目标看起来空闲或用户明确要求注入 prompt 时使用；大载荷、结构化内容或非 ASCII 文本优先使用 buffer。

| 步骤 | 做什么 | 命令 |
|------|----|---------|
| **发现** | 找到其他 agent | `rmux -L fleet list-panes -a` |
| **发送** | 向某 agent 的 pane 输入 | `rmux -L fleet send-keys -t bob 'do X' Enter` |
| **读取** | 捕获它渲染出的回复 | `rmux -L fleet capture-pane -t bob -p` |
| **共享** | 交换一个载荷 | `rmux -L fleet set-buffer -b inbox.bob '...'` |
| **同步** | 阻塞直到收到信号 | `rmux -L fleet wait-for -L chan.task1` |

## 安装

### 快速安装

通过发布的安装脚本直接安装，不需要 clone 本仓库。

Codex：

```sh
curl -fsSL https://raw.githubusercontent.com/zlin101/rmux-skill/main/install.sh | sh -s -- codex
```

Claude Code：

```sh
curl -fsSL https://raw.githubusercontent.com/zlin101/rmux-skill/main/install.sh | sh -s -- claude
```

如果想先检查脚本内容：

```sh
curl -fsSL https://raw.githubusercontent.com/zlin101/rmux-skill/main/install.sh -o /tmp/rmux-skill-install.sh
less /tmp/rmux-skill-install.sh
sh /tmp/rmux-skill-install.sh codex
```

固定安装某个分支或 tag：

```sh
RMUX_SKILL_REF=<tag-or-commit> sh /tmp/rmux-skill-install.sh codex
```

如果你的环境需要重新加载 skills，重启 Codex、Claude Code 或执行对应的 reload 操作。

### 1. 安装 rmux（必需依赖）

`rmux` 是本 skill 驱动的终端复用器。从 [rmux 项目](https://github.com/Helvesec/rmux) 安装：

| 平台 | 命令 |
|---|---|
| macOS（Homebrew） | `brew install rmux` |
| Windows（WinGet） | `winget install rmux` |
| Windows（Chocolatey） | `choco install rmux` |
| Windows（Scoop） | `scoop bucket add rmux https://github.com/Helvesec/scoop-rmux && scoop install rmux` |
| Windows（PowerShell） | `irm https://rmux.io/install.ps1 \| iex` |
| Linux / macOS（Nix） | `nix profile install github:Helvesec/rmux` |
| 通用（Cargo） | `cargo install rmux --locked` |
| Linux（APT / DNF） | 见 [rmux 安装指南](https://github.com/Helvesec/rmux#-installation) |

确认它在 `$PATH` 上：`rmux -V`，然后 `rmux diagnose`（或 `rmux capabilities`）。

> 本 skill 假定使用一个 **隔离的 rmux 服务器**（通过 `-L SOCKET`），这样 agent 集群绝不会打扰你真实的 tmux session。完整文档：[rmux.io/docs](https://rmux.io/docs)。

### 2. 安装 skill

本仓库提供一个自包含、可安装的 skill 目录：

```
rmux-skill/        # 英文 skill —— SKILL.md
```

安装 `rmux-skill/`。其中的 `SKILL.md` 是一个 markdown 文件，agent 按需读取——把它放到你的 agent 加载 skill 的地方即可。中文 README 仅作为说明文档保留，不再提供单独的中文 skill。

**Claude Code** —— 安装到 `~/.claude/skills/rmux-skill/`（让文件落在 `~/.claude/skills/rmux-skill/SKILL.md`），或在一个 plugin 里引用本仓库。

**Codex** —— 安装到 `~/.codex/skills/rmux-skill/`（让文件落在 `~/.codex/skills/rmux-skill/SKILL.md`）。

**其他支持文件式 skill 的 agent** —— 指向 `rmux-skill/SKILL.md`。内容是平台无关的指令；它告诉 agent *做什么*，而不是调用哪个运行时工具。

期望的安装后目录结构：

```text
~/.claude/skills/rmux-skill/
└── SKILL.md

~/.codex/skills/rmux-skill/
└── SKILL.md
```

## 快速开始

在一个私有集群里启动两个 agent，给其中一个派任务，再读取回复：

```sh
S=-L fleet
rmux $S start-server
rmux $S new-session -d -s planner 'codex'   # agent A
rmux $S new-session -d -s worker  'claude'  # agent B

# 谁在那儿？
rmux $S list-panes -a -F '#{session_name}|#{pane_id}|#{pane_current_command}'

# planner -> worker：发任务，再读回复
rmux $S send-keys -t worker 'implement foo()' Enter
sleep 2
rmux $S capture-pane -t worker -p -S -30 | sed '/^$/d'

rmux $S kill-server   # 拆掉整个集群
```

## 心智模型与寻址

- **一个 agent = 一个 rmux session**（推荐），运行它自己的 REPL/命令。
- 后台启动：`rmux new-session -d -s 名字 'agent命令'`。
- **目标**（`-t`）可用以下方式定位一个 pane：
  - session 名 → 其活动 pane：`bob`
  - `session:window.pane`：`bob:0.0`
  - 稳定的 pane id：`%3`
- **socket 隔离：** 每条命令加 `-L SOCKET`（例如 `-L fleet`）。为一个集群选一个 socket 并全程使用——绝不要碰用户默认的 session。
- rmux 内置一个私有 `tmux` shim，所以命令环境里的 `tmux ...` 会路由到 rmux（用 `RMUX_DISABLE_TMUX_SHIM=1` 关闭）。

## 五个原语

1. **发现** —— 用 `list-sessions` / `list-panes` 加格式变量（`#{session_name}`、`#{pane_id}`、`#{pane_current_command}`、`#{pane_pid}`、`#{pane_dead}`）构建真正的 agent 名册。用 `-f` 过滤，用 `display-message -p` 查询单个属性。
2. **发送** —— `send-keys -t T 'text' Enter`。`Enter` 是一个*独立的参数*，用来提交。载荷含字面内容时用 `-l`（这样 `; $ # !` 不会被当作按键）；大/结构化载荷改走 buffer。
3. **读取** —— `capture-pane -t T -p` 打印已渲染文本。`-S -50 -E -` 取回看，`-J` 合并折行，`-e` 保留颜色。agent 异步渲染，所以要**轮询**直到出现标记。
4. **共享（buffer）** —— `set-buffer`/`show-buffer`/`paste-buffer`/`save-buffer`/`load-buffer` 构成跨 agent 邮箱。注意 `paste-buffer` 输入时**不带**末尾的 `Enter`。
5. **同步（`wait-for`）** —— 命名频道：`-L` 等待，`-S` 发信号/加锁，`-U` 释放。

## 快速参考

| 目标 | 命令 |
|---|---|
| 后台启动 agent | `rmux -L s new-session -d -s 名字 'cmd'` |
| 列举 agent | `rmux -L s list-sessions` |
| 枚举所有 pane | `rmux -L s list-panes -a -F '#{session_name}|#{pane_id}|#{pane_current_command}|#{pane_pid}'` |
| 查询单 pane 属性 | `rmux -L s display-message -t T -p '#{var}'` |
| 过滤 pane | `rmux -L s list-panes -a -f '#{m:pat,#{pane_current_command}}' -F '#{session_name}'` |
| 向 agent 发送输入 | `rmux -L s send-keys -t T 'text' Enter`（字面文本加 `-l`） |
| 读取 agent 输出 | `rmux -L s capture-pane -t T -p`（回看：`-S -50 -E -`） |
| 写邮箱 | `rmux -L s set-buffer -b 名字 'data'` |
| 读邮箱 | `rmux -L s show-buffer -b 名字` |
| 邮箱 → 输入 | `rmux -L s paste-buffer -b 名字 -t T` |
| 同步频道 | `rmux -L s wait-for -L\|-S\|-U CHANNEL` |
| 杀掉单个 agent | `rmux -L s kill-session -t 名字` |
| 杀掉整个集群 | `rmux -L s kill-server` |
| 健康/构建信息 | `rmux capabilities` / `rmux diagnose` |

## 易踩的坑

- **忘了 `Enter`** —— `send-keys 'ls'` 只输入不执行；加一个末尾的 `Enter` 参数。
- **特殊字符被破坏** —— `; $ # !` 会被当作按键/格式解释。用 `send-keys -l`，或把大载荷改走 buffer。
- **连错服务器** —— 不带 `-L` 的命令会打到用户默认 socket。整个集群统一用一个 `-L SOCKET`。
- **读得太早** —— 发送后立即 capture 常常什么也没有；轮询直到出现标记。
- **目标歧义** —— 裸 session 名定位的是其*活动* pane；要精确分割就用 `%pane_id` 或 `session:win.pane`。
- **已死的 agent** —— 结束的 REPL 会退出 pane。在把"沉默"当成"还在思考"之前，先查 `#{pane_dead}` / `#{pane_dead_status}`。
- **填充/重复行** —— `capture-pane -p` 会填充到 pane 高度（`sed '/^$/d'`），前台程序也会回显输入（所以某行可能出现两次）。

## CLI 之外

- **Rust SDK** `rmux-sdk` —— 类型化、守护进程支撑的 API（`ensure_session`、`pane.send_text`、`pane.expect_visible_text`、快照、流式）。当*代码*是驱动方时使用。
- **Python SDK** `librmux`。
- **浏览器共享** `rmux web-share` —— 在浏览器里暴露一个 pane/session（端到端加密）；供人类观察，不用于 agent 间 IPC。
- **能力探测** `rmux capabilities --json` / `rmux diagnose --json` —— 协商守护进程特性并调试。

## 许可证

见仓库了解许可证详情。
