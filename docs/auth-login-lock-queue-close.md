# Auth 登录串行化：`lock` / `queue` / `<close>` 机制说明与用法

本文梳理本项目里 **Auth 登录/拉取用户（pull）串行化** 的套路，解释 `moon.queue` 的机制原理，以及 Lua 5.4 `<close>`（to-be-closed）语法如何保证锁释放，并给出正确用法案例与常见误区。

涉及文件：

- `server/game/auth/Auth.lua`
- `server/moon/lualib/moon/queue.lua`

---

## 1. 背景：为什么需要给登录加锁

Auth 服务内是协程并发的。同一玩家（同一 `uid`）可能在短时间内触发多次认证/登录请求，例如：

- 客户端重复点击登录、重连、网络抖动重发
- 服务器侧主动 `pull`（拉起离线玩家）与客户端登录同时发生

如果不做串行化，可能导致：

- 同一 `uid` 并发创建/加载用户服务
- 状态竞争（在线状态、logouttime、socket fd 映射等）
- DB/Redis 并发写入顺序错误

因此，本项目采用 **“每个 uid 一把锁”** 的方式，让同一 uid 的关键流程按顺序执行。

---

## 2. Auth 中 `lock` 的使用方式（按 uid 分桶）

在 `server/game/auth/Auth.lua` 中（以 `Auth.C2SLogin` 片段为例）：

### 2.1 每个 uid 对应一个 lock

- `auth_queue`：`uid -> lock` 的映射
- `lock`：由 `queue()` 创建的闭包函数（下面第 3 节解释）

伪代码等价逻辑：

```lua
local lock = auth_queue[uid]
if not lock then
  lock = queue()
  auth_queue[uid] = lock
end
```

### 2.2 登录限流：非 pull 的并发直接拒绝

对 **非 pull** 的请求，如果发现锁当前被占用（或同 uid 有在途流程），直接踢掉连接：

- `lock("count") > 0`：返回内部 `ref`（持锁/重入计数）
- `> 0` 表示当前有协程持锁（或重入），因此拒绝快速重复登录

### 2.3 串行化进入临界区：`local scope_lock <close> = lock()`

关键一行：

```lua
local scope_lock <close> = lock()
```

含义：

- 若锁空闲：立即进入临界区
- 若锁被别的协程持有：当前协程会 `yield` 排队，等待被唤醒后再进入
- `<close>` 保证该临界区结束时一定会执行解锁（即使中途 `return`/报错）

> 注意：Auth 里允许多次 `pull` 的逻辑是：pull 不会被 `lock("count")` 拒绝，但仍会排队串行执行；一旦发现用户已在内存（`context.uid_map[uid]`）就快速返回。

---

## 3. `moon.queue`（`server/moon/lualib/moon/queue.lua`）机制原理

`queue()` 返回一个“锁函数” `lock(...)`，内部维护三样状态：

- `current_thread`：当前持锁协程（owner）
- `ref`：重入计数（owner 协程可重入）
- `thread_queue`：等待队列（FIFO）

### 3.1 `lock("count")`：查询当前 ref

`lock` 被传入任意真值参数时，直接返回 `ref`：

- `ref == 0`：锁空闲
- `ref > 0`：锁被持有（可能重入）

### 3.2 `lock()`：加锁（可能阻塞）

当调用 `lock()`：

1. 获取当前协程 `thread = coroutine.running()`
2. 如果有 owner 且不是自己：
   - 把当前协程放入 `thread_queue`
   - `coroutine.yield()` 挂起等待
   - 被唤醒后断言 `ref == 0`（保证唤醒时锁确实已释放）
3. 将 `current_thread = thread`
4. `ref = ref + 1`
5. 返回 `scope`（带 `__close` 的对象）

### 3.3 `scope.__close`：解锁与唤醒下一个

`scope` 的 `__close` 会：

1. `ref = ref - 1`
2. **只有当 `ref == 0`**（最外层退出）才会：
   - 从队列 pop 下一个等待协程
   - `moon.wakeup(next_thread)` 唤醒它继续

因此，锁释放/唤醒条件是 **`ref == 0`**，不是 `ref < 0`。

---

## 4. Lua 5.4 `<close>` 机制（to-be-closed 变量）

`local x <close> = expr` 表示：`x` 是一个“待关闭变量”。

当离开 `x` 的作用域时（包括正常结束、`return`、抛错等），Lua 会自动执行关闭动作：

- 若 `x` 的元表存在 `__close`，则调用 `__close(x, err)`（其中 `err` 可能携带异常信息）

在本项目里，`lock()` 返回的 `scope` 是个 table，元表里实现了 `__close`，因此：

```lua
local scope <close> = lock()
-- 临界区...
-- 作用域退出 => 自动触发 scope.__close => ref--，必要时 wakeup 下一个等待协程
```

这就是为何 Auth 里哪怕中途 `return`，也不会忘记解锁。

---

## 5. 用法案例（正确姿势）

### 5.1 串行执行（常用）

```lua
local lock = queue()

moon.async(function()
  local _ <close> = lock()
  -- do something critical
end)
```

并发启动多个协程时，临界区会按顺序一个个执行。

### 5.2 可重入（同一个协程嵌套进入同一把锁）

`queue` 的实现是可重入的：同一个 owner 协程再次 `lock()` 不会阻塞，而是 `ref++`。

```lua
local lock = queue()

do
  local a <close> = lock() -- ref=1
  -- ...
  local b <close> = lock() -- ref=2 (re-enter)
  -- ...
end
-- 退出作用域会依次 close b、close a：ref 2->1->0
```

> 注意：在 Auth.C2SLogin 这条路径里通常只 `lock()` 一次，所以 `ref` 多数在 0/1 之间变化；但机制本身允许重入。

---

## 6. 常见误区（错误示例）

### 6.1 覆盖 `<close>` 变量导致“加锁两次只释放一次”

```lua
local s <close> = lock()  -- ref=1
s = lock()                -- ref=2，但没有新增一个 <close> 变量
-- 作用域退出只 close 一次 => ref 2->1，锁不会彻底释放，后续可能卡住
```

原因：

- `<close>` 的关闭次数取决于“声明了多少个 `<close>` 变量”，而不是你调用了多少次 `lock()`。
- 正确做法：用两个 `<close>` 变量（见 5.2），或避免在同一作用域重复加锁。

### 6.2 误认为唤醒条件是 `ref < 0`

该实现中 `ref` 不应该小于 0；唤醒发生在 **`ref == 0`**。

---

## 7. 与 Auth 的关系小结

- `auth_queue[uid]`：保证 **同 uid 串行**
- `lock("count")`：对 **非 pull** 的快速重复请求做“在途检测 + 拒绝”
- `local scope <close> = lock()`：保证临界区安全进入与必然释放
- `queue`：用 `yield/wakeup` 实现协程排队，用 `ref` 支持可重入

