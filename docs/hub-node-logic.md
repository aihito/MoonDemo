# Hub 节点逻辑分析（`server/main_hub.lua`）

> 目标：解释 hub 节点在该工程中的职责、架构与数据流，便于后续排查与扩展。

## 1. Hub 节点在系统中的角色

`server/main_hub.lua` 本质上是一个“前置入口/网关 + 控制台控制器”：

1. 读取当前 node 的配置，确定 hub 需要监听的地址与端口。
2. 启动若干个 hub worker（`game/service_hub.lua`），用于承载外部连接。
3. 通过 TCP 监听接入连接，并将连接（socket fd）按轮询策略分发到 hub worker。
4. hub worker 提供两类能力：
   - 接入后解析控制台命令（纯文本协议），并把命令转发给 cluster 内其他服务（`cluster.call`）。
   - 若客户端发起 HTTP `GET/POST`，则把连接交给 `moon.http.server` 处理，提供 `/console` 等 HTTP API。

换句话说：**main_hub 负责“怎么起、怎么分发”；service_hub 负责“怎么处理控制台/HTTP 请求”。**

## 2. 启动参数与配置加载（`main_hub.lua`）

`main_hub.lua` 使用 `moon.args()` 获取启动参数：

- `arg[1]`：当前节点编号（node id），会被当作 `tonumber(arg[1])` 使用。
- `arg[2]`：节点配置文件路径（由 `io.readfile(arg[2])` 读取）。

配置文件内容被 `json.decode` 成数组 `res`，其中每一项类似：

- `v.node`：节点编号
- `v.type`：节点类型字符串（用于 `SERVER_NAME`）
- `v.host`：监听地址（形如 `ip:port` 或仅 `ip`）
- `v.cluster`：可选集群信息（在 service_hub 里也会被整理为 host/port）

代码会遍历 `res` 找到匹配 `v.node == arg[1]` 的那一项，作为 `selfnode`。

### 2.1 日志缩减策略

通过 `GameDef.LogShrinkToFit("log", selfnode.type .. "-" .. selfnode.node, 10)` 初始化日志滚动策略（log 名称按 `type-node` 组织）。

## 3. 服务拓扑（`moon.new_service`）

`main_hub.lua` 会创建一组 Moon 服务实例：

### 3.1 cluster 服务（唯一）

```lua
{
  unique = true,
  name = "cluster",
  file = "moon/service/cluster.lua",
  threadid = 1,
  url = serverconf.CLUSTER_ETC_URL,
  etc_path = "/conf.cluster?node=%s"
}
```

该服务负责集群通讯（在 `moon/service/cluster.lua` 中实现了 `cluster.send`/`cluster.call`，并维护到其他 node 的 socket 连接）。

### 3.2 hub worker 服务（按线程数创建）

读取 `worker_count = math.tointeger(moon.env("THREAD_NUM"))`，然后创建 `hub1..hubN`：

- `name = "hub"..i`
- `file = "game/service_hub.lua"`
- `unique = true`

这些 worker 用来承载外部连接的 socket fd 与控制台命令处理。

## 4. 环境变量注入与 worker 初始化

在 `moon.async(function() ... end)` 中，会设置：

- `moon.env("NODE", arg[1])`
- `moon.env("SERVER_NAME", selfnode.type .. "-" .. selfnode.node)`
- `moon.env("NODE_FILE_NAME", arg[2])`

随后对每个 worker 地址执行：

- 如果服务名以 `hub` 开头：`moon.send("lua", addr, "loadnode")`

这一步对应 `game/service_hub.lua` 里的 `command.loadnode()`：

1. 清空 `node_list`
2. 从 `moon.env("NODE_FILE_NAME")` 读配置 json
3. 为每个 node 解析 `host`（抽取 `([^:]+)` 和端口）
4. 若配置包含 `v.cluster`，同样解析成 `{ host, port }`
5. 将解析结果放入 `node_list[v.node] = v`

worker 初始化完成后，hub worker 才能正确处理控制台命令中的“转发目标 node/服务”。

## 5. 网络接入与连接分发（TCP 监听）

main_hub 内部再启动一个 `moon.async` 来监听连接：

1. 解析监听地址：
   - `host, port = selfnode.host:match("([^:]+):?(%d*)$")`
   - `port` 转整数，缺省 `80`
2. `socket.listen(host, port, moon.PTYPE_SOCKET_TCP)` 创建监听 fd
3. 轮询分发策略：
   - `balance` 从 1 开始递增
   - 每次 `socket.accept(listenfd, addr)` 接入后：
     - `moon.send("lua", addr, "start", fd, 30)`
     - `balance = balance + 1`，超过 worker 数量就归回 1

其中：

- `fd`：新连接的 socket 文件描述符
- `30`：传给 worker 的读超时（注释里写的是 30 秒 read timeout）

**要点**：main_hub 不处理连接内容，只做“分发 fd + 参数”。真正读 socket、解析协议、处理命令发生在 hub worker 内。

## 6. Hub worker 处理逻辑（`game/service_hub.lua`）

`game/service_hub.lua` 在文件尾部注册了一个 Moon `lua` dispatch：

- `moon.dispatch("lua", function(sender, session, cmd, ...) ... end)`

它会找到 `command[cmd]` 并执行：

- `command.start(fd, timeout)`
- `command.loadnode()`

### 6.1 `command.start(fd, timeout)`：解析连接类型并进入对应处理

核心逻辑：

1. 定义 `echo(...)`：把参数用 `\t` 拼接并写入 socket，末尾加 `\r\n`
2. 循环读取 `cmdline = socket.read(fd, "\n")`
3. 如果读取到内容以 `GET ` 或 `POST` 开头：
   - 认为这是 HTTP 请求行
   - 调用 `httpserver.start(fd, timeout, cmdline.."\n")` 进入 HTTP 处理
4. 否则把这一行当作控制台命令：
   - 调用 `command_handler(cmdline, echo)`

### 6.2 `command_handler(cmdline, echo)`：控制台命令协议（文本）

`cmdline` 会先 `string.trim`，然后根据首字符决定模式：

- `S`：按 server 指令（`serverid` 直接从 `split[1]` 中截取）
- `U`：按 user gm 指令（把 `uid` 转成 `serverid`：`uuid.serverid(uid)`）
- `T`：按 task（批量下发到匹配类型的 node）

#### 6.2.1 文本命令格式（`S/U/T`）

命令会被按空白拆分为 `split[]`（使用 `%S+`），并且 `handle_one()` 会把 `split[2]` 改写为 `Console.<split[2]>`，随后调用：

`clusterd.call(to_serverid, "node", table.unpack(split, 2))`

也就是说，目标 node 的 `node` 服务最终收到的参数序列形如：

`("Console.<cmd>", <后续 split[3..N]...>)`

常见格式可以理解为：

1. 单目标 server：
   - `S<serverid> <cmd> [args...]`
   - 其中 `<cmd>` 会被改写成 `Console.<cmd>`，并作为目标 node 收到的第一个参数
2. 按 uid 跳转到 server（GM）：
   - `U<uid> <cmd> [args...]`
   - 会通过 `uuid.serverid(uid)` 算出 `serverid`
   - 代码会在 `split` 的索引 3 位置插入 `uid`，因此目标 node 实参通常形如：`("Console.<cmd>", uid, <args...>)`
3. 按 node 类型批量任务：
   - `T<type> <cmd> [args...]`
   - 会遍历 `node_list`，把所有 `v.type == <type>` 的 node 作为 fan-out 目标
   - 返回会被编码为 JSON：`{ code = 0, data = { [nodeId] = <result_or_err> } }`，并附带 `<CMD OK>`

#### 6.2.2 回显与结束标记

当通过纯 socket 文本通道执行时，`echo(...)` 的输出会用 `\t` 拼接、`\r\n` 换行。

当命令执行完成时，可能会回显以下标记：

- `<CMD OK>`：调用成功结束
- `<CMD Error>`：调用失败结束

`/console`（HTTP）接口还会对 `<CMD OK>/<CMD Done>` 做过滤，以便返回内容更适配脚本解析。

在 `handle_one(split, to_serverid, echo)` 中：

1. 将第二个参数改写为 `Console.<原第二参数>`
2. 调用：`clusterd.call(to_serverid, "node", table.unpack(split, 2))`

也就是：**命令被转成对目标 node 的 `node` 服务的 cluster call**。

当 `cmdline` 的返回需要回显时：

- 如果 `res` 是 table：用 `format_table` / `dump_list` 输出
- 否则输出字符串

为了便于脚本化，`/console` HTTP 接口还做了额外的 `<CMD OK>/<CMD Error>` 字符串过滤与 JSON/文本返回判定（见下面 HTTP API 部分）。

### 6.3 HTTP 接入：`moon.http.server` 路由

`service_hub.lua` 创建了 `moon.http.server` 实例并注册路由：

#### `/console`

支持 `POST` 或 body 包含 JSON 的方式：

1. `command = string.trim(request.body)`
2. 若 `content-type == application/json`：`command = json.decode(command).command`
3. 调用 `command_handler(command, ...)`
4. 收集回显结果拼成输出：
   - 如果内容看起来像 JSON（第一个字节为 `[` 或 `{`），则设置 `Content-Type: application/json`
   - 否则返回 `text/plain`（或 `application/text`）
5. 出错时会将 `response.status_code` 设置为 400

#### `/conf.updatenode`

用于运行时刷新 node 配置：

1. 从 `i=1` 循环：`moon.queryservice("hub"..i)`
2. 找到服务就对该 worker 执行 `moon.send("lua", addr, "loadnode")`
3. 当某个 i 找不到 hub 服务时停止

返回 `OK`

#### `/conf.node?node=...`

返回指定 node 的配置（从 `node_list[node]` 取值）：

- 未找到返回 404
- 找到则返回 JSON 编码配置

#### `/conf.cluster?node=...`

返回指定 node 的集群信息（仅当 `cfg.cluster` 存在时）：

- 未找到或无 cluster 返回 404
- 找到则返回 `{ host, port }`

#### 静态资源

`httpserver.static("static/www")`：提供 `static/www` 下资源。

## 7. 与集群通讯的关系（`moon/service/cluster.lua`）

hub worker 中真正把“命令转发到其他 node”发生在：

- `clusterd.call(to_serverid, "node", ...)`

而 `clusterd` 对应 `moon/service/cluster.lua` 导出的 `cluster` 模块，关键行为：

1. `cluster.call(receiver_node, receiver_sname, ...)`：
   - 分配 `session = moon.next_sequence()`
   - 构造 header：`session = -session`（负数表示 call）
   - `moon.raw_send` 给 cluster socket 服务，等待 `moon.wait(session)`
2. cluster 服务在 socket message 里区分：
   - call（`header.session < 0`）：转发给对应 node 的目标服务，并写回响应
   - response（`header.session > 0`）：匹配之前的 session，完成 `moon.wait`

因此，hub 节点的“跨服务控制台”能力依赖 cluster 服务把 call 消息路由到目标 node 的 `node` 服务。

## 8. 数据流总览

外部请求到 hub 节点的典型路径：

1. 外部建立 TCP 连接 -> 连接进入 `main_hub.lua` 监听
2. main_hub 按轮询策略选择一个 `hub worker` -> `moon.send(..., "start", fd, 30)`
3. `service_hub.command.start`：
   - 若第一行是 `GET/POST`：转给 `httpserver.start`
   - 否则：把行作为文本命令 -> `command_handler`
4. `command_handler` -> `handle_one` -> `clusterd.call(target_node, "node", ...)`
5. cluster 服务完成跨 node 调用，返回结果给 hub worker
6. hub worker 通过 socket echo 或 `/console` HTTP response 把结果返回给调用方

## 9. 扩展与排查建议

1. 如果控制台命令无法执行，优先检查：
   - `NODE_FILE_NAME` 是否正确（影响 `loadnode` 的 node_list）
   - `/conf.node` 是否能返回目标 node 配置
   - cluster config（`CLUSTER_ETC_URL` + `/conf.cluster?node=%s`）是否可达
2. 如果外部连接频繁超时：
   - 检查 `main_hub.lua` 传给 `start` 的 `timeout`（当前是 30）
   - 检查连接协议是否按 `\n` 结尾（`socket.read(fd, "\n")` 逐行读取）
3. `/conf.updatenode` 刷新失败时，检查：
   - `hub1..hubN` 是否都已创建（依赖 `THREAD_NUM`）
   - queryservice 返回是否一致

