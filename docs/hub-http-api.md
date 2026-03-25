# Hub HTTP API 参考（`server/game/service_hub.lua`）

## 可调用接口总览

基于当前 `service_hub.lua`，Hub 对外提供以下 HTTP 接口：

- `POST /console`
- `GET /conf.updatenode`
- `GET /conf.node?node=<id>`
- `GET /conf.cluster?node=<id>`

另外还挂载了静态目录：

- `httpserver.static("static/www")`（静态资源访问）

> 说明：`command.start()` 会先判断请求首行是否为 `GET/POST`，是则进入 HTTP 处理；否则按文本命令处理。

---

## 1) `POST /console`

用于执行控制台命令（会转发到集群内目标 node 的 `node` 服务）。

### 请求体格式

支持两种 body 格式：

1. 纯文本（`text/plain`）
2. JSON（`application/json`），结构为：

```json
{
  "command": "S1 Ping"
}
```

### 命令前缀约定

- `S<serverid> ...`：发往指定 server
- `U<uid> ...`：按 uid 计算 serverid
- `T<type> ...`：广播到某类型 node

### 返回

- 成功：`HTTP 200`
- 命令错误：`HTTP 400`
- `Content-Type`：
  - 返回内容首字节是 `[` 或 `{` 时为 `application/json`
  - 否则为 `application/text`

### 调用示例

文本方式：

```bash
curl -i -X POST "http://127.0.0.1:8003/console" \
  -H "Content-Type: text/plain" \
  --data 'S1 Reload'
```

JSON 方式：

```bash
curl -i -X POST "http://127.0.0.1:8003/console" \
  -H "Content-Type: application/json" \
  --data '{"command":"Tgame Reload"}'
```

---

## 2) `GET /conf.updatenode`

触发 Hub 所有 worker 重新加载 node 配置（调用每个 `hubN` 的 `loadnode`）。

### 返回

- `HTTP 200`
- `Content-Type: text/plain`
- Body: `OK`

### 调用示例

```bash
curl -i "http://127.0.0.1:8003/conf.updatenode"
```

---

## 3) `GET /conf.node?node=<id>`

查询指定 node 的完整配置（来自 worker 内存中的 `node_list`）。

### Query 参数

- `node`：节点编号（整数）

### 返回

- 找到：
  - `HTTP 200`
  - `Content-Type: application/json`
  - Body: 对应 node 配置 JSON
- 未找到：
  - `HTTP 404`
  - `Content-Type: text/plain`
  - Body: `not found`

### 调用示例

```bash
curl -i "http://127.0.0.1:8003/conf.node?node=1"
```

---

## 4) `GET /conf.cluster?node=<id>`

查询指定 node 的 cluster 地址信息（仅返回 `host/port`）。

### Query 参数

- `node`：节点编号（整数）

### 返回

- 找到且 node 配置含 `cluster`：
  - `HTTP 200`
  - `Content-Type: application/json`
  - Body: `{"host":"...","port":...}`
- 未找到或该 node 无 cluster 字段：
  - `HTTP 404`
  - `Content-Type: text/plain`
  - Body: `cluster node not found <node>`

### 调用示例

```bash
curl -i "http://127.0.0.1:8003/conf.cluster?node=1"
```

---

## 常见排查点

- `POST /console` 返回 400：检查命令前缀是否是 `S/U/T`，以及参数是否完整。
- `/conf.node` 404：先调用 `/conf.updatenode` 刷新配置，再确认 `node.json` 中有对应节点。
- `/conf.cluster` 404：目标 node 可能没有配置 `cluster` 字段。
- 请求无响应：确认 Hub 监听地址端口是否与 `main_hub.lua` 的 `selfnode.host` 一致。

