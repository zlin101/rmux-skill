---
name: rmux-skill
description: 当通过 rmux 协调多个基于终端的 agent 时使用——例如：发现哪些 rmux session/pane 代表其他 agent、向另一个 agent 的 pane 发送命令或消息、读取另一个 agent 已渲染的输出、通过共享 buffer 交换数据、或用 wait-for 同步各 agent。当任务提及 rmux、tmux 风格的 agent 编排、"另一个 agent"、或用于多 agent 工作流的终端复用时也会触发。
---

# RMUX Agent 通信

## 概述

`rmux` 是一个 tmux 兼容的终端复用器（Rust 编写）。**每个 agent 运行在自己的 rmux session/pane 里。** 你通过列举 session 和 pane 来发现其他 agent；通过向彼此的 pane 输入内容来让 agent 交流；通过捕获 pane 的已渲染文本来读取回复。本 skill 覆盖多 agent 发现与通信的 CLI 原语。

核心循环：**发现**（`list-sessions` / `list-panes`）→ **发送**（`send-keys`）→ **读取**（`capture-pane`）→ 可选地 **共享**（buffer）/ **同步**（`wait-for`）。

> 以下所有命令均已对 `rmux` 实测验证。标志与 tmux 一致；运行 `rmux <命令> --help` 查看完整参数，运行 `rmux list-commands` 查看所有命令。

## 心智模型与寻址

- 一个 **agent** = 一个 rmux **session**（推荐）或其中的一个 **pane**。
- 后台启动一个 agent：`rmux new-session -d -s 名字 'agent命令'`。
- **目标**（`-t`）可用以下任一方式定位一个 pane：
  - session 名 → 其活动 pane：`bob`
  - session:window.pane：`bob:0.0`
  - pane id（移动后仍稳定）：`%3`
- **socket 隔离：** 每条命令加 `-L SOCKET` 使用一个私有 rmux 服务器（不要去碰用户真实的 session）。为一个 agent 集群选定一个 socket 并全程使用它。示例：`rmux -L fleet list-sessions`。
- rmux 还内置一个私有 `tmux` shim，因此命令环境里的 `tmux ...` 命令会路由到 rmux（用 `RMUX_DISABLE_TMUX_SHIM=1` 关闭）。

## 1. 发现其他 agent

列举每个 agent（session）：
```sh
rmux -L fleet list-sessions
# bob: 1 windows ...
# alice: 1 windows ...
```

枚举所有 session 下的所有 pane —— 这才是真正的 agent 名册。用格式变量暴露身份：
```sh
rmux -L fleet list-panes -a -F '#{session_name}|#{pane_id}|#{pane_current_command}|#{pane_pid}|#{pane_title}'
# bob|%1|claude|84123|worker
# alice|%0|codex|84001|planner
```

常用格式变量：`#{session_name}`、`#{window_index}`、`#{pane_index}`、`#{pane_id}`、`#{pane_current_command}`（前台程序——即该 agent 是什么）、`#{pane_pid}`、`#{pane_title}`、`#{pane_dead}`、`#{pane_dead_status}`（检测崩溃/已退出的 agent）。

直接查询单个 pane 的属性：
```sh
rmux -L fleet display-message -t bob -p '#{pane_current_command}'
# claude
```

过滤 pane（例如找出所有运行 `claude` 的 pane）：
```sh
rmux -L fleet list-panes -a -f '#{m:claude,#{pane_current_command}}' -F '#{session_name}|#{pane_id}'
```
`-f` 接受一个 tmux 格式串，需求值为真；`#{m:pat,str}` 是通配匹配。

## 2. 向另一个 agent 发送消息/命令

把内容输入到目标 pane 的前台程序：
```sh
rmux -L fleet send-keys -t bob 'please review src/cli.rs' Enter
```
- `Enter` 是一个**独立的参数**（在文本之后发送的按键名）。省略它则只输入不提交。
- 对于包含特殊字符（`;`、`'`、`#`、`$`、`!`）的**字面**文本，加 `-l`，这样任何内容都不会被当作按键名解释：
  ```sh
  rmux -L fleet send-keys -l -t bob 'a && b; echo $HOME #not-a-comment'
  ```
- 不加 `-l` 时，`Enter`、`C-c`、`Up`、`Escape`、`Space` 这类名字会被当作按键。

> `send-keys` 把内容输入到 pane 当前正在运行的程序。如果该 agent 的 REPL 不在提示符处（例如正在思考、在分页器里），输入可能被吞掉或被误解。建议约定清晰的 agent 输入契约（一个提示符，或一个 agent 会读取的命令通道）。

## 3. 读取另一个 agent 的输出

把 pane 已渲染的文本捕获到标准输出：
```sh
rmux -L fleet capture-pane -t bob -p
```
- `-p` → 打印到标准输出（而不是存入 buffer）。几乎总是你要的。
- `-S 起始 -E 结束` → 行范围；用 `-S -50 -E -` 取可见屏幕上方约 50 行**滚动回看**。
- `-J` → 把软换行（被折断）的行各合并为一行。
- `-e` → 保留 ANSI/转义序列（颜色）。省略则得到纯文本。
- 输出包含空白/填充行——解析前先过滤（例如 `| sed '/^$/d'`）。

轮询直到回复出现（agent 异步渲染）：
```sh
for i in $(seq 1 30); do
  out=$(rmux -L fleet capture-pane -t bob -p -S -20 | sed '/^$/d')
  echo "$out" | grep -q 'DONE_MARKER' && { echo "$out"; break; }
  sleep 1
done
```

## 4. 通过 buffer 的共享消息总线

命名 buffer 是一个跨 agent 的邮箱——任何 pane 可写，任何 pane 可读：
```sh
# alice 写入一个载荷
rmux -L fleet set-buffer -b inbox.bob 'payload JSON or text'

# bob（或你）读取它
rmux -L fleet show-buffer -b inbox.bob

# 把它作为输入粘贴进 bob 的 pane
rmux -L fleet paste-buffer -b inbox.bob -t bob

# 注意：paste-buffer 只输入 buffer 内容，不带末尾的 Enter ——
# 与 `send-keys 'text' Enter` 不同。若要把整行提交到 agent 的
# 提示符/REPL，需要你自己补发按键：
rmux -L fleet send-keys -t bob Enter

# 跨运行持久化 / 重新载入
rmux -L fleet save-buffer -b inbox.bob ./msg.bob
rmux -L fleet load-buffer -b inbox.bob ./msg.bob

# 清点 + 清理
rmux -L fleet list-buffers
rmux -L fleet delete-buffer -b inbox.bob
```
buffer 会一直存在，直到服务器停止。用命名约定（`inbox.<agent>`、`topic.<x>`）来建模频道。

## 5. 用 `wait-for` 同步 agent

命名频道让一个 agent 阻塞，直到另一个发信号：
```sh
# agent/工作流等待（阻塞），直到该频道被发信号
rmux -L fleet wait-for -L chan.task1

# 在别处，发信号/释放它
rmux -L fleet wait-for -U chan.task1
```
标志：`-L` 等待该频道，`-S` 发信号/加锁，`-U` 释放。请在你的构建上用 `rmux wait-for --help` 确认确切的标志语义，然后全程使用一致的约定。

## 完整生命周期（编排者）

```sh
S=-L fleet
rmux $S start-server
rmux $S new-session -d -s planner 'codex'   # agent A
rmux $S new-session -d -s worker  'claude'  # agent B

# 发现
rmux $S list-panes -a -F '#{session_name}|#{pane_id}|#{pane_current_command}'

# planner -> worker：发任务，再读取 worker 的回复
rmux $S send-keys -t worker 'implement foo()' Enter
sleep 2
rmux $S capture-pane -t worker -p -S -30 | sed '/^$/d'

# 通过 buffer 共享结果
rmux $S set-buffer -b result.worker "$(rmux $S capture-pane -t worker -p -S -5)"

rmux $S kill-server   # 拆掉整个集群
```

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

## 常见错误

- **忘了 `Enter`。** `send-keys -t bob 'ls'` 只输入 `ls` 但不执行——需再加一个 `Enter` 参数。
- **特殊字符被破坏。** `; $ # !` 会被当作按键/格式解释。字面载荷用 `send-keys -l`，或者把大载荷改走 **buffer**。
- **连错服务器。** 不带 `-L` 的命令会连到用户默认 socket，可能干扰真实 session。整个集群统一用一个 `-L SOCKET`。
- **读得太早。** agent 异步渲染；`send-keys` 之后立即 `capture-pane` 常常什么也看不到。轮询直到出现标记（见 §3）。
- **目标歧义。** 裸 session 名定位的是其*活动* pane；如果窗口被拆分过，用 `%pane_id` 或 `session:win.pane` 精确定位。
- **已死的 agent。** 一个结束的 REPL 会退出 pane。在把"沉默"当成"还在思考"之前，先查 `#{pane_dead}` / `#{pane_dead_status}`。
- **捕获里的空行。** `capture-pane -p` 会填充到 pane 高度；解析前用 `sed '/^$/d'` 去掉空行。
- **捕获里的重复行。** 前台程序常常会回显你 `send-keys` 的输入（例如 `cat`、shell），所以捕获可能显示同一行两次（输入回显 + 重新渲染）。`capture-pane` 显示的是该程序渲染出来的内容——并不是重复发送。

## CLI 之外

- **Rust SDK** `rmux-sdk` —— 后台守护进程支撑的类型化 API（`ensure_session`、`pane.send_text`、`pane.expect_visible_text`、快照、流式）。当*代码*是驱动方时使用。见 `docs/scripting-sdk.md`。
- **Python SDK** `librmux`。
- **浏览器共享** `rmux web-share` —— 在浏览器中暴露一个 pane/session（端到端加密）。不用于 agent 间 IPC，但便于人类观察。
- **能力探测** `rmux capabilities --json` / `rmux diagnose --json` —— 协商守护进程特性、调试构建/运行时。
