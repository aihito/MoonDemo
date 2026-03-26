# 协议代码生成脚本分析与文档（`server/tools`）

本文梳理并解释以下脚本的职责与数据流，帮助你理解它们如何从 `.proto` 生成 Lua/C# 需要的协议代码与类型注解。

- `server/tools/moonfly.py`
- `server/tools/make_csharp_proto.py`
- `server/tools/make_annotations.py`

## 1. 总体流水线概览

整体是“单入口脚本 + 两个生成器”的模式：

1. `moonfly.py` 作为入口，收集 `.proto` 中的 `Message/Enum` 定义并驱动生成流程
2. `moonfly.py` 内部调用：
   - `protoc`：生成 `proto.pb` 描述文件（供其它工具可能使用）
   - `make_annotations.EmmyLuaIntelliSense()`：生成 Lua EmmyLua 注解（`Annotations.lua`、`ProtoEnum.lua`）并导出 `json_verify.json`
   - `make_csharp_proto.make_proto()`：根据注解解析结果生成 C# 的消息类型文件（`*.cs`）
3. 同时 `moonfly.py` 还会生成/更新命令码映射文件：
   - `server/common/CmdCode.lua`
   - `BallAction/Assets/Proto/CmdCode.cs`

## 2. `moonfly.py`（入口与编排器）

### 2.1 关键依赖

- `import make_annotations`
- `import make_csharp_proto`
- 调用外部命令：`protoc`（要求命令行环境里可用）

### 2.2 `Config` 配置（相对路径假设）

脚本末尾构造了一个 `Config`，其关键字段默认值大致是：

- `protoc_file = "protoc"`
- `proto_src_dir = "../protocol/"`
- `descriptor_out_file = "../protocol/proto.pb"`
- `cmdcode_out_file = "../common/CmdCode.lua"`
- `csharp_out_dir = "../../BallAction/Assets/Proto"`
- `csharp_cmd_file = "../../BallAction/Assets/Proto/CmdCode.cs"`
- `ignore_file_list = ["annotations"]`
- `special_file_list = ["common"]`

这些都是**相对路径**，因此建议你以 `server/tools/` 为工作目录运行脚本，否则 `../protocol/` 等路径会落到错误位置。

### 2.3 `ProtoGen.gen()`：解析 proto 并生成 `proto.pb`

核心步骤：

1. 遍历 `proto_src_dir` 下的 `.proto` 文件（`listdirs(..., depth=10)`）
2. 用正则提取命令类消息名：
   - `pattern = re.compile(r'message\s+([S,C][2,B][S,C]\w+)')`
   - 这要求你的 `proto` 里 `message` 的命名形如 `C2SXXX` / `S2BXXX` 等（具体取决于 `[S,C][2,B][S,C]` 匹配）
3. 构建：
   - `self.cmd_list`：所有命令 message 名集合
   - `self.forward_dict`：用于生成 Lua/C# 的“转发映射”（仅对 `special_file_list` 之外的 service proto 生效）
4. 调用 `protoc` 生成描述文件：
   - 执行形如：`protoc -I{proto_src_dir} -o{descriptor_out_file} {所有proto路径...}`

输出：

- `server/protocol/proto.pb`（由 `descriptor_out_file` 决定）

### 2.4 `ProtoGen.gen_cmdcode()`：生成 `CmdCode`（Lua + C#）

它会尝试读取旧的 `cmdcode_out_file`，用同类正则抽取旧 cmd 列表，然后：

1. 将新命令加入 `order_list`（保持顺序/尽量复用旧内容）
2. 将旧但已不存在的命令从 `order_list` 移除
3. 生成两个文件：
   - `CmdCode.lua`：包含
     - `C2Sxxx = <id>`
     - （部分）`forward` 表：`C2Sxxx = 'addr_<serviceName>'`
   - `CmdCode.cs`：包含 `enum CmdCode { ... }`

命令 id 从 `startid=1` 起递增。

模板来源：

- Lua：`cmdcode_template`
- C#：`csharp_cmdcode_template`

### 2.5 `moonfly.py` 的主执行顺序（末尾 try 块）

执行顺序固定为：

1. `proto_gen.gen()`
2. `proto_gen.gen_cmdcode()`
3. `intelliSense = make_annotations.EmmyLuaIntelliSense()`
4. `protolist, proto_list_with_file = intelliSense.run(...)`
   - `json_verify_out_file = "../protocol/json_verify.json"`
   - 会额外在当前工作目录生成 `Annotations.lua`、`ProtoEnum.lua`
5. `make_csharp_proto.make_proto(proto_list_with_file, config.csharp_out_dir, config.ignore_file_list)`
6. 打印执行成功信息

异常处理：捕获 `Exception` 并打印 stack trace。

> 注意：末尾有 `os.system("pause()")`，这是偏 Windows 的用法；在 Linux/WSL 可能打印错误但不一定阻断（取决于 shell/环境）。

## 3. `make_annotations.py`（EmmyLua 注解 + json 校验数据）

### 3.1 顶层职责

`EmmyLuaIntelliSense.run(...)` 会做三类产物：

1. 生成 Lua 协议注解文件（供 IDE/类型提示）
   - `Annotations.lua`
   - `ProtoEnum.lua`
2. 生成协议字段的 JSON 描述，用于校验/对照：
   - `json_verify_out_file`（由 `moonfly.py` 传入，默认 `../protocol/json_verify.json`）
3. 生成逻辑脚本与静态配置的注解：
   - 根据 `game_dir` 下的逻辑目录结构收集脚本名，生成 `---@class <service>_scripts`
   - 根据 `game_config_dir` 收集配置文件名，生成 `---@class static_conf`

### 3.2 `parse_proto()`：解析 `.proto` 内容

它不是通过 protobuf 反射解析，而是“逐行 + 正则 + 栈”：

- message/enum 起始：`message\s+(\w+)`、`enum\s+(\w+)`
- message 字段：
  - 支持 `repeated <type> <name> = <idx>; //comment`
  - 支持 `map<key,value> <name> = <idx>; //comment`
  - 支持普通字段 `<type> <name> = <idx>; //comment`
- 用 `parse_stack` 记录当前进入的 message/enum，并在遇到 `}` 时弹栈

解析结果：

- `proto_list`：形如 `(ProtoType, name, fields)`
- `proto_list_with_file`：`{ filepath -> proto_list_for_that_file }`

> 这要求你的 `.proto` 在代码风格上尽量符合这些正则的单行匹配（比如字段声明不要被拆成多行）。

### 3.3 `make_proto_annotations()`：生成 EmmyLua 结构 + json

对每个 message：

- `repeated`：生成 `---@field public <name> <type>[]`
- `map`：生成 `---@field public <name> table<keyType, valueType>`
- 普通字段：生成 `---@field public <name> <type>`

同时会构建 `jsonconcept`：

- `jsonconcept[MessageName][FieldName] = { container, value_type, ... }`
- 并把 `jsonconcept` 写入 `json_verify_out_file`

对每个 enum：

- 生成 Lua 表枚举定义
- 并生成一个 `return { EnumName = EnumName, ... }` 结构

### 3.4 生成逻辑脚本注解：`make_game_annotations()`

它会扫描 `logicpath` 的目录结构（深度 2），把每个服务目录下面的脚本文件名收集起来，生成：

- `---@class <serviceName>_scripts`
- `---@field <scriptName> <scriptName>`

### 3.5 生成静态配置注解：`make_conf_annotations()`

会扫描配置目录下的 `.lua` 文件名，生成：

- `---@class static_conf`
- `constant` 特殊处理：字段类型直接是 `constant`
- 其它配置：字段类型会被写成 `<name>_cfg[]`

## 4. `make_csharp_proto.py`（C# ProtoBuf 消息/枚举生成）

### 4.1 顶层职责

`make_proto(proto_list_with_file, output_dir, ignore_file_list)` 会：

1. 遍历 `proto_list_with_file` 中的每个 proto 文件
2. 为每个 proto 输出一个 C# 文件：
   - 文件名：`<ProtoFileName>.cs`（使用 `shotname.capitalize() + ".cs"`）
3. 在输出文件中生成：
   - message 对应的 class + `[ProtoContract]` / `[ProtoMember]`
   - enum 对应的 enum 定义（通过 `make_enum`）

### 4.2 类型映射

脚本内置了 `proto_csharp_map`：

- `int32/int64/...` -> `int/long/...`
- `bool` -> `bool`
- `string` -> `string`
- `bytes` -> `byte[]`

### 4.3 字段命名转换

使用 `rule_convert` 做命名风格转换（大驼峰/小驼峰/下划线互转），最终生成 C# 属性名类似：

- `to_upper_camel_case(fieldName)`

### 4.4 属性与注释

字段生成规则：

- `repeated`：生成 `public List<T> Name { get; set; }`
- `map`：生成 `public Dictionary<K,V> Name { get; set; }`
- 普通字段：生成 `public T Name { get; set; }`

同时如果 proto 字段带 `//comment`，会作为 `// ...` 写进 C# 文件。

## 5. 建议的运行方式与产物位置

### 5.1 建议在 `server/tools` 目录运行

示例（任选其一）：

```bash
cd server/tools
python3 moonfly.py
```

### 5.2 主要产物

执行后会生成/更新（取决于配置）：

- `server/protocol/proto.pb`
- `server/common/CmdCode.lua`
- `BallAction/Assets/Proto/CmdCode.cs`
- `server/protocol/json_verify.json`
- 在脚本当前工作目录生成：
  - `Annotations.lua`
  - `ProtoEnum.lua`
- `BallAction/Assets/Proto/*.cs`（每个 proto 文件一个 .cs）

## 6. 常见坑位（需要你关注的点）

1. `moonfly.py` 里对 `.proto` 命令 message 的提取使用正则，要求 message 命名符合预期（例如 `C2S...` / `S2B...`）
2. `make_annotations.py` 解析字段同样依赖正则匹配，因此 `.proto` 字段声明最好保持在单行、且使用分号 `;`、注释 `//...` 的常规写法
3. 脚本的相对路径强依赖运行工作目录（强烈建议从 `server/tools` 启动）
4. `os.system("pause()")` 在 Linux/WSL 环境可能不可用；如果遇到卡住/报错，可考虑忽略或后续再做跨平台化处理

