# sgs-love

QSanguosha（C++/Qt，2010-2014）→ LÖVE2D (Lua) 的重写项目。

当前进度：**A1 + B + C 已完成** —— 武将名册 60 将、sgs.* 兼容层
（可加载原版 DIY 扩展的**技能定义**）、接入美术与音频的牌桌 UI。
D（网络对局）进行中：联机/重连/观战/聊天已通，UI 联调未做。

**数量口径**（实测，防止与文档脱节）：

| 项 | 数量 | 说明 |
| --- | --- | --- |
| 武将 | 60 | 蜀 15 / 魏 15 / 吴 15 / 群 15 |
| └ 标准版 | **25** | 蜀 7 / 魏 7 / 吴 8 / 群 3 —— 与《基础版全表》对标，由测试断言锁死 |
| └ 扩展 | 35 | 风/火/林/山/一将成名等 |
| 技能条目 | 120 | 60 将 × 2（含主公技与派生子技能） |
| 卡种定义 | 39 | 基本 8 + 锦囊 16 + 装备 15（武器 9，标准版 5 张齐） |
| 牌堆 | **108** | 标准版预设，花色点数固定（`src/core/deck_spec.lua`） |

对标与修复记录见 `AUDIT-标准版对标.md`（含 §G 修复记录）。

资源已**自带**在 `assets/`（约 28MB），不再引用原 QSanguosha 源码目录。

测试：**核心 418 + UI 12 + 网络 45 = 475 全通过**。

## 牌堆口径

默认 **标准版 108 张**，花色点数按官方对照表**固定**（`src/core/deck_spec.lua`），
只洗序随机。另有 `extended` 预设（标准版 + 军争篇混堆，花色点数随机）：

```lua
Standard.PRESET = "extended"   -- 切回混堆；默认 "standard"
```

## 对局规模

身份局支持 **4 / 5 / 8 人**，**默认 5 人**，**推荐 8 人**：

| 人数 | 配置 | 说明 |
| --- | --- | --- |
| 5 | 主1 忠1 反2 内1 | **默认**，节奏适中 |
| 8 | 主1 忠2 反4 内1 | **推荐**，官方标准局，身份博弈最完整 |
| 4 | 主1 忠1 反1 内1 | 最小可玩局 |

另有 1v1 死斗（2 人）。服务端默认开 5 座。
对局类测试（压测/网络）统一用 **5 人局与 8 人局**；4 人仅保留配置表校验。

## 操作方式

**点选**：点手牌 → 点目标武将。
**拖拽**：按住手牌拖到武将面板上松手即打出（两种方式等价，可混用）。

拖拽时：合法目标描**绿边**，鼠标悬停的非法目标描**红边**；
提示条实时显示「攻击范围 N · 到某某 距离 M」，距离不够会直接给出原因
（如「距离 2 超出攻击范围 1」）且**不会打出**。
松手在空白处只回到已选中状态，不取消选择。

距离/出杀次数/禁止技一律由引擎判定（`Room:canUseCardOn`），UI 不自己算规则。

## 工具脚本

项目自带便携版 LÖVE（`tools/love.app`，11.5），无需额外安装。
所有脚本都从**项目根目录**执行。

| 脚本 | 用途 |
| --- | --- |
| `./run-tests.sh` | 静态检查 + 单测（核心 354 + UI 12，约 2 秒） |
| `./run-soak.sh` | 压测（60 将逐将覆盖 + 多种子回归 + 卡牌守恒） |
| `./run-game.sh` | 图形界面 |
| `./tools/lua.sh <脚本.lua>` | **跑任意 Lua 脚本**（用游戏同款 LuaJIT，见下） |
| `./tools/serve.sh [端口] [座位数]` | 联机服务端（默认 9527 / 5 座） |
| `./tools/join.sh [名字] [host] [port]` | 联机控制台客户端 |

不常用的入口（脚本已封装，一般不用直接敲）：

```bash
./tools/love.app/Contents/MacOS/love . --net    # 网络层测试（含真实 TCP）
./tools/love.app/Contents/MacOS/love . --test   # 同 run-tests.sh
./tools/love.app/Contents/MacOS/love . --soak   # 同 run-soak.sh
```

无头模式靠 `conf.lua` 在 `--test` / `--soak` / `--net` 下关闭窗口实现，
**不要**用 `SDL_VIDEODRIVER=dummy`（macOS 的 dummy 驱动建不出 OpenGL 上下文，会弹错误框）。

## 跑 Lua 代码：`tools/lua.sh`

本机 PATH 里没有 `lua` / `luajit`，但 LÖVE 自带了 **Lua 5.1 / LuaJIT 2.1**
（游戏运行时用的就是它）。`tools/lua.sh` 把它包成一个 CLI，
**保证验证代码时的解释器版本与游戏完全一致**。

```bash
./tools/lua.sh 脚本.lua                    # 运行脚本
echo 'print(_VERSION)' | ./tools/lua.sh -  # 跑一行代码（从标准输入读）
```

脚本内可直接 `require "src.core.*"`（package.path 已指向项目根）：

```bash
$ echo 'local C=require "src.core.cards"; print(C.get("slash").zh)' | ./tools/lua.sh -
杀
$ echo 'print(_VERSION, jit.version)' | ./tools/lua.sh -
Lua 5.1	LuaJIT 2.1.1700008891
```

> 局限：`src/ui/*` 需要 `love.graphics` 等模块，windowless 下不可用。
> UI 相关请走 `./run-tests.sh`（`test_ui.lua` 用的是打桩的 love）。
> core/ 不依赖 love，可以放心在这里跑。
>
> 若想在命令行装一个通用 `lua`：要装 **LuaJIT 2.1**（对标 Lua 5.1），
> 不要装默认的 Lua 5.4 —— 本项目用了 5.1 专有的 `setfenv`，5.4 加载就报错。

## 结构（详见 DESIGN.md）

```
src/core/     纯 Lua 规则引擎（零 love 依赖，headless 可测）
src/compat/   sgs.* 兼容层，加载 diy/ 下的原版社区扩展
src/ui/       LÖVE 场景（菜单/牌桌）+ 皮肤/音频/布局/动效
diy/          DIY 扩展示例 3 份（武将包）：转化技 / 技能牌 / 询问类 API
tests/        BOT vs BOT 全量对局测试 + 多种子回归 + 卡牌守恒
tools/        love.app（LÖVE 便携版）、lua.sh、serve.sh、join.sh、
              lint_methods.py（点号/冒号检查）
assets/       资源：image/  audio/  skins/  font/（自带，无需原项目）
```

**术语**：`BOT` = 规则驱动的脚本对手（`src/core/bot.lua`，无学习/推理/搜索）；
`AI` 留给将来由 LLM 驱动的玩家。详见 DESIGN.md「五、开发约定 0」。

## 路线图

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| A0 | 骨架 + 迷你局 + headless 测试 | ✅ |
| A1 | 标准包全量 + 60 将技能 | ✅ |
| B | sgs.* 兼容层 + diy/ 扩展加载器 | ✅（国战机制与 bot 提示表按决策不做） |
| C | 完整 UI（皮肤/布局/音频/动效） | ✅（待实机验证观感） |
| D | LuaSocket 网络服务端 + 多人 | 🚧 进行中（联机/重连/观战/聊天已完成，UI 联调未做） |
| E | 标准版对标补齐（濒死救援/主公技/武器/花色表） | ✅ 完成，见 `AUDIT-标准版对标.md` 与 `PLAN-标准版补齐.md` |

**E 阶段背景**：对照「基础版武将与卡牌全表」「身份局游玩说明」两份文档审计后，
发现角色/牌型/规则上的缺口，审计结论见 `AUDIT-标准版对标.md`，
实施计划（任务拆解 + 验收用例 + 提交切分）见 `PLAN-标准版补齐.md`。

E 阶段已落地：濒死救援轮询全场、主公技三件套（护驾/激将/救援）、
补齐 9 件标准武器（含丈八蛇矛与贯石斧的效果）、诸葛亮【观星】、陆逊【连营】、
牌堆改为文档标准版 108 张 + 固定花色点数、判定区后进先判与同名唯一、
8 项技能语义修正。
仍缺（已记在 PLAN）：主公选将流程、部分技能的玩家侧交互界面。

## 联机（阶段 D，进行中）

```bash
./tools/serve.sh [端口] [座位数]   # 启动服务端（默认 9527 / 5 座）
./tools/join.sh  [名字] [host] [port]   # 控制台客户端，连上并自动应答
./tools/love.app/Contents/MacOS/love . --net   # 网络层测试（内存通道，不占端口）
```

已验证（真机两进程 + 进程内真 socket 自动化测试）：
监听 → 接入占座 → ready → **开局** → 请求/应答 → **打完一局** → 广播 over。
客户端能实时收到 log、在需要时收到 req 并应答。

架构：服务端持有权威 `Room`；连上来的客户端占座（人类），空座由 BOT 顶替。
`Driver` 遇到人类请求会返回 `"human"`，Host 就把请求发给对应座位并等待应答。

```
src/net/protocol.lua   协议：一行一个 JSON；消息体只放可序列化数据
src/net/host.lua       房间 / 座位 / 同步 的权威层（不碰 socket，只认通道）
src/net/channel.lua    通道抽象：内存（测试） / TCP（真实）
src/net/server.lua     LuaSocket TCP 适配
src/net/client.lua     客户端：收消息、应答请求
```

测试分两层：主体走**内存通道**（不占端口、不依赖时序，完全确定），
另有「真实 TCP」一组（回环 socket，端口动态取，监听失败则 SKIP）。

## 断线重连 / 观战 / 聊天

```bash
# 掉线：服务端保留座位 60 秒（Host.dropSeat），不是立即清空
# 重连：客户端凭 welcome 下发的 token 发 {type:"resume", token} 坐回原座
# 观战：hello 带 spectate=true —— 不占座，只收 log/state/chat
# 聊天：{type:"chat", text}，服务端记 50 条历史并广播；新连入者会补发
```

真机已验证：观战者收到 22 条日志；观战席发的聊天能到达玩家客户端。
观战者不在 `clients` 表里（没占座），所以服务端要单独 drain 他们，
否则他们发的消息永远没人读（踩过）。

**服务端是常驻的**：一局结束不退出，清掉 ready 后可再开下一局
（原来打完就退出，导致后连的人根本连不上）。

尚未做：UI 联调（用真实客户端替掉本地人类玩家）、多房间大厅。

## 已知限制

按「有意为之」与「尚未覆盖」分开列，避免接手时误判成 bug：

**有意为之（决策结果）**
- **不做国战机制**，只做标准身份局 → 邹氏的【祸水】【倾城】纯属国战机制，
  她在名册里保留占位但**无技能**
- **不消费原版 bot 提示表**（`sgs.ai_*`）。表名继续保留（DIY 脚本会往里塞值，
  改名就崩），但引擎不读；决策逻辑走自己的 `src/core/bot.lua`
- `defaultSkin.audio.json` / `animation.json` 在原版里**是空的**，所以音效按
  资源目录约定解析（`audio/card/<male|female>/<名>.ogg`、`audio/system/<key>.ogg`），
  动效是自己实现的
- DIY 的 `askForYiji` / `askForExchange` 等是桩实现 —— BOT 没有对应的
  交互界面，强做反而是假的

**尚未覆盖**
- 只移植了**标准包**。原版扩展包（`strategic-advantage` 军争、
  `formation`、`jiange-defense`、`momentum`）未移植
- **宝物**（`sgs.CreateTreasure`）没有对应槽位，映射到防具槽
- DIY 卡牌包（`Package_CardPack`）刚支持，覆盖度不如武将包
- 压测中少量局因长时间拉锯**判平局**（连续 80 回合无人阵亡）——
  是 BOT 打不穿残局囤牌的合法结果，不是死循环；`MAX_TURNS=300` 仍是
  真正的死循环保险
