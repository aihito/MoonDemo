# AOI 结构与 API 参考（`server/moon/src/common/aoi.hpp`）

本文梳理 `aoi.hpp` 的核心抽象、数据结构、设计思路与对外 API（insert/update/query/erase 等），用于快速理解该 AOI（Area of Interest）实现的行为与边界。

## 1. 核心抽象：Watcher / Marker

该 AOI 把对象分为两类“角色”，并允许一个对象同时具备两种角色（通过 bitmask 控制）：

- **Watcher（观察者）**：拥有一个“视野矩形”（由 `w/h` 表示），会关注视野范围内的 marker。
- **Marker（被观察者）**：被 watcher 关注的对象，通常只需要坐标；也支持“范围 marker”（占据一个矩形区域）。

角色常量（bitmask）：

- `mode::watcher = 1`
- `mode::marker  = 1<<1`

事件类型：

- `event_enter`：进入 watcher 视野
- `event_leave`：离开 watcher 视野（需要显式开启，见第 4 节）

## 2. 数据结构：规则网格（tile grid）

### 2.1 地图与 tile

构造函数：

```cpp
aoi(int posx, int posy, int map_size, int tile_size)
```

- 地图被视为一个 `map_size x map_size` 的矩形（左下角起点为 `posx/posy`）。
- 将地图按 `tile_size` 划分为网格：`count_ = map_size / tile_size`，并要求整除：
  - `assert(map_size % tile_size == 0)`
- 内部用一维数组 `data_ = new tile[count_ * count_]` 存储格子数据。

每个 tile 维护两套容器：

- `markers`：`std::forward_list<object_type*>`（链表）
- `watchers`：`std::unordered_set<object_type*>`

选择原因（设计取舍）：

- marker 常见操作是“插入/删除/遍历”，链表插入 O(1)，但删除是 `forward_list.remove(obj)`（线性扫描）。
- watcher 需要频繁查重/移除，`unordered_set` 适合集合语义。

### 2.2 对象存储

所有对象实体本体存放在：

- `objects_ : std::unordered_map<object_handle_type, object_type>`

tile 中只保存指向 `objects_` 内部对象的指针。

> 注意：`objects_` rehash 会使内部对象地址变化。该实现将对象指针缓存到 tile 中，因此 **隐含要求** `objects_` 的元素地址在使用期间保持稳定或 rehash 不发生。实际工程中通常通过提前 reserve/控制增长来避免 rehash 导致指针失效；若未处理，属于潜在风险点。

### 2.3 Watcher 如何“观察”、Marker 变化如何“通知”

这份 AOI 的核心不是“watcher 主动扫描”，而是 **watcher 先把自己登记到覆盖的 tile 上，后续 marker/watcher 变化时 AOI 主动产出事件**。

#### 2.3.1 Watcher 的观察机制（watch 注册）

watcher 有一个视野矩形（中心点 `x,y`，宽高 `w,h`）：

1. 计算 watcher 视野覆盖的 tile 范围 `tile_rect = make_tile_rect(x, y, w, h)`
2. 对 `tile_rect` 覆盖的每个 tile：
   - 将 watcher 指针放入该 tile 的 `watchers` 集合
3. 同时对这些 tile 的 marker 做 enter/leave 判定（insert 时为“初始 enter”，update 时做“差量 enter/leave”）

因此 watcher 的“观察列表”隐式由 **(watcher 覆盖的 tile 集合)** 决定。

#### 2.3.2 Marker 变化时 watcher 如何得知（事件产生）

AOI 在以下变化点会主动生成事件到 `event_queue_`：

- **marker insert**：marker 加入某 tile（或 range-marker 加入多个 tile）时，遍历该 tile 的 `watchers`，对每个 watcher 的视野矩形做 `contains(marker.x, marker.y)` 判断，满足则产生 `event_enter`。
- **marker erase**：marker 从 tile 移除时（且开启 leave），遍历该 tile 的 `watchers`，产生 `event_leave`。
- **marker update（跨 tile）**：marker 移动导致 tile 变化时，等价于“从旧 tile erase + 向新 tile insert”，因此会触发 leave/enter。

一句话：**marker 的插入/移除/跨 tile 移动 = 通过 tile.watchers 通知所有可能受影响的 watcher**。

#### 2.3.3 Watcher 变化时可见集如何更新（差量）

watcher update 时会计算 old/new 覆盖范围与视野矩形：

- 对“旧覆盖但新不覆盖”的 tile：从 tile.watchers 移除该 watcher，并对 marker 做 leave 判定
- 对“新覆盖但旧不覆盖”的 tile：加入 tile.watchers，并对 marker 做 enter 判定
- 对“重叠区域”的 tile：尽量跳过重复扫描，只对边缘差量做计算（这是 `update` 中较复杂的分支目的）

#### 2.3.4 事件如何被 Lua 消费（`update_event`）

AOI 的 enter/leave/自定义事件都会先进入 `event_queue_`，Lua 侧通过 `update_event(event_cache)` 拉取：

- 每条事件是三元组：`(watcher, marker, eventid)`
- 事件不会自动清空：一般由 Lua 每次 insert/update/erase/fire_event 后立刻 `update_event` 消费（本项目 `Aoi.lua` 就是这么做的）

## 3. 坐标到 tile 的映射

- `get_tile_x(v)` / `get_tile_y(v)`：将坐标映射到 tile 索引，并在越界时 clamp 到 `[0, count_-1]`。
- `make_rect(x,y,w,h)`：根据中心点与宽高得到“实际视野矩形”，并 clamp 到地图边界。
- `make_tile_rect(...)`：将视野矩形映射为“覆盖的 tile 范围”。

该实现的视野/范围都是以 `(x,y)` 为中心，使用 `w/2`、`h/2` 来计算左右上下边界。

## 4. 事件模型：事件队列与开关

事件以结构体 `aoi_event` 形式写入 `event_queue_`：

- `eventid`：enter/leave
- `watcher`：观察者 handle
- `marker`：被观察者 handle

事件触发路径主要有三类：

1. marker 插入：对所在 tile 的 watchers 检查 `enter`
2. marker 移除：对所在 tile 的 watchers 检查 `leave`
3. watcher 视野更新：对涉及 tile 的 markers 做 enter/leave 比对

“离开事件”默认关闭，需要调用：

- `enbale_leave_event(bool v)`（注意函数名拼写为 `enbale_...`）

辅助接口：

- `clear_event()`：清空事件队列
- `get_event()`：读取事件队列（返回 `const std::vector<aoi_event>&`）

## 5. API 文档

下面按“对外可调用方法”梳理其语义与关键行为。

### 5.1 `insert(handle, x, y, w, h, layer, mode, range_marker=false) -> bool`

用途：把一个对象加入 AOI 系统。

参数要点：

- `handle`：对象唯一标识（由 `AoiObject::handle_type` 定义）
- `x,y`：坐标
- `w,h`：
  - 对 watcher：表示视野宽高（必须 `>=0`）
  - 对 marker：通常可以为 0；若 `range_marker=true`，则 marker 也用 `w/h` 表示占据范围
- `layer`：层级（用于 `AoiObject::check(args...)` 做过滤时可参与判定，具体取决于 AoiObject 的实现）
- `mode`：watcher/marker bitmask
- `range_marker`：仅对 marker 生效；当 marker 占范围且 `w/h>0` 时，会插入到覆盖的所有 tile 的 marker 列表中

行为概览：

- 若 `(x,y)` 不在地图矩形 `rect_` 内：返回 `false`
- 若 `objects_.try_emplace(handle, ...)` 失败（handle 已存在）：返回 `false`
- 插入 marker：
  - 普通 marker：仅放入当前位置 tile
  - range marker：放入覆盖 tile 范围内的每个 tile
- 插入 watcher：
  - 对覆盖的每个 tile：把 watcher 放进 tile.watchers，并对 tile 中 marker 做 enter/leave 的差量计算（初始进入）

### 5.2 `update(handle, x, y, w, h, layer) -> bool`

用途：更新对象的位置、视野（w/h）和 layer。

关键路径：

- 若新 `(x,y)` 越界，或 `w/h<0`：返回 `false`
- 找不到 handle：返回 `false`
- 更新 marker：
  - 通过 `update_marker(obj, old_x, old_y)` 处理跨 tile 移动
  - 如 `enbale_leave_event_` 开启，会生成 leave 事件
- 更新 watcher：
  - 计算 old/new 的视野矩形与 tile 覆盖范围
  - 分情况处理：
    - new 视野被 old 包含 / old 被 new 包含 / 部分重叠
  - 对受影响的 tile：插入/移除 watcher 集合，并对 markers 做 enter/leave 判断

> watcher 更新部分属于该实现的复杂核心，目标是避免对完全包含区域做重复扫描，只对“边缘差量 tile”进行处理。

### 5.3 `query(x, y, w, h, out, args...)`

用途：查询一个矩形区域内的 marker（以 handle 输出到 `out`）。

实现要点：

- 计算查询 rect 与覆盖 tile 范围
- 遍历覆盖 tile：
  - 对边缘 tile：逐个 marker 做 `inside(rect)` 精确判断
  - 对内部 tile：不做 inside 判断（直接 `check(args...)` 后加入）

这是一种典型优化：内部 tile 的 markers 必定完全落在查询 rect 内（前提是 tile 完全被 rect 覆盖），可省掉逐个几何判断。

`args...` 会透传给 `AoiObject::check(args...)`，用来做额外过滤（例如 layer 过滤、阵营过滤等）。

### 5.4 `fire_event(handle, eventid)`

用途：对一个 marker 手动触发 enter/leave 类型事件检查。

它会：

- 找到对象所在 tile
- 对该 tile 的 watchers 逐个检查 `rc.contains(obj->x,obj->y)`，满足则写入事件

> 该函数不会改变对象的坐标或集合关系，只是“按当前状态补发事件”。

### 5.5 `erase(handle)`

用途：从 AOI 系统删除对象。

行为：

- 如果是 marker：
  - range marker：从覆盖的所有 tile 的 marker 链表中 remove
  - 普通 marker：从所在 tile 的 marker 链表 remove
  - 同时对该 tile 的 watchers 生成 leave（若开启）
- 如果是 watcher：
  - 对其覆盖的所有 tile：从 `watchers` 集合 erase
- 最后从 `objects_` 删除该对象

### 5.6 `clear()`

用途：清空整个 AOI 状态（tiles + objects）。

### 5.7 其它辅助

- `enable_debug(bool)`：打印 watch/unwatch 等调试输出到 stdout
- `has_object(handle)`：是否存在该对象
- `find(handle)`：返回对象指针（找不到返回 null）
- `for_each_all(handler, filter)`：遍历所有 tiles，把符合 filter 的 watcher/marker 交给 handler

### 5.8 Lua 绑定补充：`update_event(event_cache_table) -> integer`

> 这是 **Lua 层使用 AOI 的关键接口**，在 `server/game/room/Aoi.lua` 中通过 `space:update_event(event_cache)` 消费 C++ 侧累积的 enter/leave/自定义事件。

来源：

- C++ AOI 事件队列：`aoi.hpp` 的 `event_queue_`
- Lua 绑定实现：`server/moon/src/lualib-src/lua_aoi.cpp` 的 `laoi_update_event`

#### 5.8.1 入参/返回

- **入参**：一个 Lua table（作为输出缓存数组），例如 `event_cache = {}`
- **返回**：写入到 table 的 **元素个数**（不是事件条数）
  - 若有 `N` 条事件，返回值是 `N * 3`
  - 若无事件，返回 `0`

#### 5.8.2 写入格式（三元组数组）

`update_event(t)` 会把每条事件按顺序写入 `t`：

- `t[i]   = watcher_handle`
- `t[i+1] = marker_handle`
- `t[i+2] = eventid`（enter/leave 或业务自定义 eventid）

因此 Lua 层通常按步长 3 遍历：

```lua
local n = space:update_event(event_cache)
for i = 1, n, 3 do
  local watcher = event_cache[i]
  local marker  = event_cache[i + 1]
  local eventid = event_cache[i + 2]
  -- 处理 enter/leave/其它事件
end
```

#### 5.8.3 事件从哪里来（与 clear_event 的关系）

Lua 绑定中以下调用会 **先 clear_event 再产生新事件**（见 `lua_aoi.cpp`）：

- `space:insert(...)`
- `space:update(...)`
- `space:erase(...)`
- `space:fire_event(...)`

这意味着：每次调用上述 API 后，你应该尽快调用一次 `update_event` 把本次产生的事件“取走”，否则下一次 AOI 操作会清空旧事件。

> 这也解释了 `Aoi.lua` 里 `insert/update/erase/fireEvent` 都会立刻调用 `update_aoi_event()` 的原因：保证 enter/leave 事件不会被覆盖。

## 6. 复杂度与适用场景（直观理解）

- insert/update/query 的性能主要取决于：
  - watcher 的视野覆盖了多少 tile（tile_rect 面积）
  - 每个 tile 中 marker/watcher 的数量
  - 是否启用 range marker（会在多个 tile 挂载同一 marker 指针）
- 通过 tile 网格分割，避免全图扫描，适合“对象数较多、局部交互为主”的场景。

## 7. 实际使用提示（Lua 侧）

本仓库 Lua 侧的 AOI 使用在 `server/game/room/Aoi.lua`、`Room.lua`（可结合查看），通常模式是：

- 玩家作为 watcher + marker（既能看别人也能被别人看）
- 食物作为 marker
- 周期性对玩家 update 位置；事件队列驱动进入/离开视野的广播

### 7.1 使用案例（对照现有实现）

下面是项目当前 AOI 的一条典型“房间内可见性与广播”链路（对应 `server/game/room/Aoi.lua` + `Room.lua`）：

#### 1) 初始化地图与开关 leave 事件

在房间启动时初始化 AOI 空间（tile_size 固定 16），并开启 leave 事件：

- `Aoi.init_map(orginx, orginy, size)`
  - `space = aoi.new(orginx, orginy, size, 16)`
  - `space:enable_leave_event(true)`

#### 2) 玩家进入房间：先给自己发“进入视野”，再插入 AOI

在 `Room.C2SEnterRoom(uid, req)` 中：

- 先 `scripts.Aoi.enter(uid, uid)`：给玩家自己发一次 `S2CEnterView`（包含自己的实体数据）
- 再 `scripts.Aoi.insert(player.id, player.x, player.y, 20, true)`：
  - `mover=true` 表示插入为 watcher|marker（可移动玩家）
  - 视野大小 `view_size=20`
  - 插入后 `update_aoi_event()` 读取并处理 enter/leave 事件：
    - enter：`Aoi.enter(watcher, marker)` -> `S2CEnterView`
    - leave：`Aoi.leave(watcher, marker)` -> `S2CLeaveView`

#### 3) 玩家移动：先更新方向/坐标，再“按 watcher 集合”广播

在 `Room.C2SMove(uid, req)` 中：

- 更新玩家位置/方向
- 调用 `scripts.Aoi.fireEvent(uid, GameDef.AoiEvent.UpdateDir, function(watchers) ... end)`
  - `space:fire_event(id, eventid)`：把“对当前 tile watchers 的事件”写入 event_cache
  - `update_aoi_event(fn)`：
    - 处理 enter/leave
    - 把需要广播的 watchers 收集成列表传给回调 `fn(watchers)`
  - 回调中使用 `protocol.encode(watchers, CmdCode.S2CMove, {...})` 一次性给 watchers 推送移动包（多播）

#### 4) 房间 tick：持续 update 视野并驱动 enter/leave

在 `Room.Update()` 中会周期性执行：

- `scripts.Aoi.update(player.id, player.x, player.y, 20)`
  - `space:update(...)` 更新玩家视野覆盖范围
  - `update_aoi_event()` 处理 enter/leave，并向客户端推送 `S2CEnterView`/`S2CLeaveView`

#### 5) 关键点总结

- **enter/leave 是 AOI 的事件队列驱动**：每次 insert/update/erase 都会触发 `update_event`，再由 Lua 层转成具体协议下发。
- **移动广播是“先算 watchers，再多播”**：减少逐个判断/逐个发送开销。
- **marker 类型区分**：Lua 层用 `uuid.isuid(marker)` 来区分“玩家(marker=uid)”和“食物(marker!=uid)”，从而查不同实体数据并下发。

