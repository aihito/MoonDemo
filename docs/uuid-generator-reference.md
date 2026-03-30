# UUID 生成规则与接口参考（`lua_uuid.cpp`）

本文档基于 `server/moon/src/lualib-src/lua_uuid.cpp` 与项目里 `moon/api/uuid.lua` 的注释，整理出 UUID 的位布局规则、取值范围、接口行为与在本项目中的用法示例。

## 1. UUID 两种模式

该实现支持两类 UUID（由 `type` 决定）：

1. **Player UID（type=0）**  
   - 用于玩家 `uid`
   - 不包含“flag=1”的类型标识
2. **Regular UUID（type>0）**  
   - 用于房间、食物、邮件等“非玩家实体”
   - 含有 `flag=1` 的标识位，并包含 `type` 字段

接口层定义在：`server/moon/lualib/moon/api/uuid.lua`（`uuid.init/next/type/isuid/serverid`）。

## 2. 初始化：`uuid.init(channel, serverid, boottimes)`

实现位于 `lua_uuid.cpp:linit`，必须在首次调用 `uuid.next` 前执行。

参数约束（来自代码校验）：

- `channel`：1..`UID_CHANNEL_MAX`（8bit 场景，具体位数在代码里展开）
- `serverid`：1..`SERVERID_MAX`（12 bits）
- `boottimes`：1..`BOOTTIMES_MAX`（10 bits）

内部行为：

- 保存全局 `g_uuid.serverid / boottimes / channel`
- 初始化每个 `type` 的原子序列数组 `sequence[...]`：都从 **1** 开始递增

本项目集成示例（在 `server/main_game.lua`）：

- `uuid.init(1, tonumber(arg[1]), data.boot_times)`

## 3. Player UID（type=0）位布局

对应 `lua_uuid.cpp:lnext` 中 `if (type == 0)` 分支。

代码注释给出布局：

- `0`（flag 位为 0）
- `49-41`：channel（9 bits）
- `40-29`：serverid（12 bits）
- `28-19`：boottimes（10 bits）
- `18-1`：sequence（18 bits）

序列规则：

- 每个进程内 `sequence[0]` 使用 `atomic.fetch_add(1)` 递增
- 若 `sequence > UID_SEQUENCE_MAX` 则报错（序列耗尽）

生成接口：

- `uuid.next(0)` 或 `uuid.next()`：生成 Player UID

## 4. Regular UUID（type>0）位布局

对应 `lua_uuid.cpp:lnext` 的 `else` 分支。

代码注释给出布局（以 64-bit 整数理解）：

- `63`：flag（固定为 1）
- `62-51`：serverid（12 bits）
- `50-41`：boottimes（10 bits）
- `40-31`：type（9 bits，范围 1..511）
- `30-1`：sequence（31 bits）

type 范围：

- `type` 被约束为 `0..TYPE_MAX`
- 其中 `type==0` 走 Player UID
- `type>0` 走 Regular UUID

序列规则：

- Regular UUID 的 `sequence` 使用 `u.sequence[type]` 原子递增
- 允许显式传入序列值（见第 5 节）
- 若 `sequence > SEQUENCE_MAX` 则报错（序列耗尽）

生成接口：

- `uuid.next(type)`：生成 Regular UUID
- `uuid.next(type, sequence)`：当 `sequence != 0` 时使用你指定的序列（代码里是 `luaL_optinteger(L,2,0)`）

## 5. 接口清单与语义

接口（来自 `lua_uuid.cpp` 与 `moon/api/uuid.lua`）：

1. `uuid.init(channel, serverid, boottimes) -> nil`
   - 初始化并重置序列起点（从 1 开始）
2. `uuid.next(type?) -> integer`
   - `type==0` 或未传：生成 Player UID（flag=0）
   - `type>0`：生成 Regular UUID（flag=1），并编码 `type`
3. `uuid.type(uid) -> integer`
   - 仅对 Regular UUID 有意义（会从位域中取出 type）
   - 代码里要求 `flag==1`，否则报错
4. `uuid.isuid(uid) -> boolean`
   - 用于判断一个值是否符合“Player UID（flag==0）”的结构约束
   - 实现会检查 flag、sequence 非 0、以及 serverid/boottimes/channel 位域都在范围内
5. `uuid.serverid(uid) -> integer`
   - 从 Player UID 或 Regular UUID 中提取 serverid 位域

## 6. 本项目中的典型用法示例

常见实体生成：

- `Center.lua`：房间号  
  - `local roomid = uuid.next(GameDef.TypeRoom)`
- `Room.lua`：房间里的食物 id / 标记  
  - `food.id = uuid.next(GameDef.TypeFood)`
- `Mail.lua`：邮件 id  
  - `mail.id = uuid.next(GameDef.TypeMail)`

判断是否为玩家 UID：

- `Room.lua` / `Aoi.lua`：用 `uuid.isuid(id)` 区分玩家实体与食物实体

通过 uid 计算 serverid：

- `service_hub.lua`：`uuid.serverid(uid)` 用于把 `uid` 路由到正确的 node

## 7. 实战注意点

1. **必须先 `uuid.init`**  
   - `uuid.next` 会检查 `g_uuid.serverid / boottimes` 是否已初始化，否则报错。
2. **sequence 从 1 开始**  
   - `uuid.isuid` 对 Player UID 有“sequence 非 0”的约束，因此手工构造/篡改值时容易不符合判定。
3. **type==0 与 type>0 在位布局上完全不同**  
   - 不要把 Regular UUID 当 Player UID 用 `uuid.isuid` 去判断，反之亦然。

