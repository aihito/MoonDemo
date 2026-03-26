# 控制台命令 `S1 help help`：实现位置与调用流程

本文说明 Hub 控制台命令（以 `S1 help help` 为例）在代码中的落点，以及从 Hub 到目标游戏节点的完整调用链。

## 1. 命令含义

- **`S`**：按 **节点编号**（server id）指定目标。
- **`1`**：目标节点 id 为 `1`。
- **`help`**（第一个）：子命令名，在 Hub 侧会被改成 **`Console.help`** 后转发。
- **`help`**（第二个）：作为额外参数传给 `Console.help`；因 `Console.help()` 未声明形参，**Lua 会丢弃多余实参**，故与 **`S1 help`** 效果相同。

## 2. 实现位置

真正返回帮助文案的函数在：

- 文件：`server/game/node/Console.lua`
- 函数：`Console.help()`
- 返回值：模块内局部变量 `help` 定义的多行说明字符串（同文件内约 `Console.Init` 与 `Console.help` 之间）。

Hub 不负责实现 `help` 逻辑，只负责解析命令并发起集群调用。

## 3. 调用流程（端到端）

### 3.1 Hub：接收与解析

1. 客户端向 Hub 发送一行文本（TCP）或 `POST /console`（HTTP），正文例如：`S1 help help`。
2. `server/game/service_hub.lua` 中 `command_handler`：
   - `split_cmdline` 拆成 token，例如 `{"S1", "help", "help"}`。
   - 首字符 `S` → 从 `S1` 解析出 **`serverid = 1`**。
3. `handle_one`：
   - 将 `split[2]` 改为 **`"Console." .. split[2]`** → **`"Console.help"`**。
   - 调用 **`clusterd.call(1, "node", table.unpack(split, 2))`**  
     即：`cluster.call(1, "node", "Console.help", "help")`。

### 3.2 集群：`cluster.call`

- 模块：`server/moon/service/cluster.lua`（业务侧通过 `require("cluster")` 使用）。
- 将带 `session` 的请求发往 **节点 1** 上名为 **`node`** 的 Moon 服务，并等待返回。

### 3.3 游戏节点：`node` 服务与命令注册

1. 进程入口侧在 `server/main_game.lua` 中创建名为 **`node`** 的服务：`server/game/service_node.lua`。
2. `service_node.lua` 调用 **`setup(context)`**（`server/common/setup.lua`），按 **`moon.name == "node"`** 加载 **`game/node/*.lua`**。
3. `load_scripts` 扫描 `server/game/node/Console.lua` 返回的表：`help` 不是 `C2S` 前缀，注册为：
   - **`command["Console.help"] = Console.help`**。
4. `moon.dispatch("lua", ...)` 收到消息时，第一个参数为 **`cmd`**（字符串 **`"Console.help"`**），查找并执行对应函数；其余参数为 **`"help"`**（对 `Console.help` 无影响）。

### 3.4 返回路径

1. `Console.help()` 返回帮助字符串。
2. 经 `cluster.call` 回到 Hub 侧的 `handle_one`。
3. Hub 通过 `echo`（TCP）或 `/console` 的 response 拼装（`server/game/service_hub.lua`），将结果写回客户端；必要时带 `<CMD OK>` 等标记。

## 4. 相关文件速查

| 环节           | 文件 |
|----------------|------|
| 解析 S/U/T、拼 `Console.*`、发起调用 | `server/game/service_hub.lua` |
| 跨节点 RPC      | `server/moon/service/cluster.lua` |
| `node` 服务入口 | `server/game/service_node.lua` |
| 脚本加载与 `command["Console.xxx"]` | `server/common/setup.lua` |
| **`help` 实现** | **`server/game/node/Console.lua`** |

## 5. 与其它控制台命令的关系

所有经 Hub 发往某节点的 **`S<nodeid> <cmd> ...`** 命令，都会在 Hub 被改成 **`Console.<cmd>`** 作为第一个实参，再 **`cluster.call(..., "node", "Console.<cmd>", ...)`**；目标节点上由 `game/node/` 下各脚本里导出的函数表，按 **`模块名.函数名`** 注册到 `command` 表中执行。
