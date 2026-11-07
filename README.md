# 微信桌面桥 · dsh-wx-desktop

> 让 DSH 的 Agent 直接接管你**自己电脑上的桌面微信**：读本地消息、醒来干活、把回复打回聊天窗口。

它不是一个「自动回复机器人」。它把桌面微信变成一条 agent 通道——你在微信里说的话，进的是你本机那个 DSH 会话；agent 的答案，由它替你敲进微信输入框。

与社区插件 `dsh-plugin-weixin`（iLink 机器人通道）互补：机器人只看得到发到机器人账号的消息，这个插件看的是真微信客户端里那个会话。

---

## 它做什么 / 不做什么

**做：**

- 盯住小号微信的本地消息库，有新消息就唤醒对应的 DSH 会话
- 文本、图片、表情包、位置、引用消息（能看到被引用的原文）都能读进去
- 回复按会话粘贴 + 回车发出去，发完比对聊天区像素确认真的发出去了
- 群聊只在被 @ 时才回；同一个人 20 秒冷却；48 小时以前的老消息不回，一批积压只回最新那条
- 两种发送方案：A = 虚拟桌面里的微信（不抢你的鼠标键盘），B = 主桌面直接点；A 失败自动退回 B
- 表情包：能按序号挑一张收藏表情发出（图像匹配 + 自动翻页）

**不做：**

- 不发语音条（桌面客户端没有这个口子）
- 不碰支付、不转账、不填地址、不点验证码
- 不用微信协议、不逆向、不碰别人的号——只操作你自己已登录的客户端窗口
- 只支持 Windows，不做群发营销

---

## 工作原理

```
微信客户端写库
   └─ decrypted/message/message_0.db   ← watch.py 轮询（1.5 s，只读新增行）
        └─ 插件 index.js               ← 去重、合批、冷却、判定会话
             └─ AgentBridge            ← 复用 dsh-plugin-weixin 的会话桥
                  └─ DSH 会话 / 模型
                       └─ wx_say.ps1  ← 摆正窗口 → 粘贴 → 回车 → 截图像素校验
                            └─ 微信聊天窗口出现回复
```

发送这一步没法用 API：微信个人号没有对外的发消息接口，所以只能操作界面。代价是脆——微信改版、窗口跑进托盘、DPI 变了都可能哑，所以脚本里塞了大量自检。

---

## 环境要求

| 项 | 要求 | 说明 |
|---|---|---|
| 系统 | Windows 10 / 11 | 依赖 Win32 窗口 API |
| 微信 | 4.x 桌面版 | 建议小号单独一个客户端（独立数据目录） |
| Python | **3.14+** | 读库要用 `compression.zstd` |
| Node | **24+** | 解表情包行要用 `node:sqlite` + `zlib.zstd*` |
| DSH | 0.2.x | 插件跑在 harness 里 |
| 依赖插件 | `dsh-plugin-weixin` | 借用它的 AgentBridge 做会话桥 |

---

## 安装

### 0. 一键安装（推荐）

先拿到本仓库，然后跑 `install.ps1`：

```powershell
git clone https://github.com/CHSCN123/dsh-wechat-desktop.git
cd dsh-wechat-desktop
powershell -ExecutionPolicy Bypass -File .\install.ps1 `
  -DbDir   'D:\WeChat\xwechat_files\wxid_xxx\db_storage' `
  -ChatUser 'wxid_xxx' `
  -PeerName '张三'
```

`install.ps1` 会：

1. 找到本机的 DSH 安装（`node`、`dsh` 的 `bin.js`、`profiles\web`）；
2. 用 `dsh plugin --profile web add` 把插件装进 profile（本地目录或 git 源都行），并确认 `dsh.profile.bundles` 里有它；
3. 调 `setup.ps1` 写配置块（检查 Python/Node、复制 `scripts/`、写 `cordis.patch.yml`）。

参数：`-Profile web`、`-SkipConfig`（只装插件不写配置）、`-LocalPath <目录>`（默认就是当前目录）、`-PanelPort 47180`、`-DshHome <路径>`。装完重启一次 DSH 即可；设置里会出现「微信桌面桥」。

下面的 1–4 是它做的事，手动装时照着来。

### 1. 装插件

```powershell
dsh plugin --profile web add dsh-wx-desktop
# 会话桥来自社区插件，一起装上：
dsh plugin --profile web add dsh-plugin-weixin
```

### 2. 准备脚本与密钥

把本仓库的 `scripts/` 整个复制到 `%USERPROFILE%\.dsh\weixin\wcdb\`（或直接配 `wcdbDir` 指过去），然后：

```powershell
python %USERPROFILE%\.dsh\weixin\wcdb\wcdb_key_tool_windows.py   # 取数据库密钥 → key.json
python %USERPROFILE%\.dsh\weixin\wcdb\watch.py --once            # 首次解密并试读
```

### 3. 写配置

在 `%APPDATA%\dsh-desktop\harness\profiles\web\cordis.patch.yml` 里加：

```yaml
- id: dsh-wx-desktop
  disabled: false
  config:
    dataDir: 'C:\Users\<你>\.dsh\weixin'
    dbDir: 'D:\WeChat\xwechat_files\wxid_xxx\db_storage'   # 小号的微信数据目录（必填）
    chatUser: 'wxid_xxx'
    peerName: '张三'
    # 可选：
    # wcdbDir: 'C:\path\to\repo\scripts'
    # pythonPath: 'C:\Python314\python.exe'
    # nodePath: 'C:\Program Files\nodejs\node.exe'
    # bridgePath: 'C:\...\dsh-plugin-weixin\src\agent-bridge.js'
```

### 4. 重启 DSH，在微信里发 `/doctor`

---

## 会话命令

| 命令 | 作用 |
|---|---|
| `/doctor`（`/自检`） | 自检：Python/Node 版本、脚本、数据库、密钥、会话桥 |
| `/new` | 当前会话开新的一条（旧上下文不串味） |
| `/mode a` / `/mode b` | 切换发送方案；不带参数报告当前模式 |

---

### 本机私有值（不进仓库）

脚本里不写死任何数据库路径或联系人名。缺省值按这个顺序取：

1. 命令行参数（如 `-DbFile`）
2. 环境变量：`WX_DB_FILE` / `WX_DB_DIR` / `WX_BOT_MARKER` / `WX_BOT_WXID` / `WX_EXE` / `WX_PYTHON` / `WX_DECRYPTED_DIR`
3. 脚本同目录的 `local-env.json`（已在 `.gitignore`）

```json
{
  "dbDir": "D:\\WeChat\\xwechat_files\\wxid_xxx\\db_storage",
  "dbFile": "D:\\WeChat\\xwechat_files\\wxid_xxx\\db_storage\\message\\message_0.db",
  "botMarker": "你备注里的联系人名",
  "botWxid": "wxid_xxx"
}
```

## 设置里的面板（推荐）

插件自带一个客户端入口：打开 DSH 的 **设置**，左侧会多出一项「微信桌面桥」，点开就是面板本体（内嵌 iframe，也可以点「在新窗口打开」）。

面板由插件主机开在本机 `127.0.0.1:<panelPort>`，默认 `47180`；只绑回环地址，不对外。

### 直接开面板（不开 DSH 设置）
浏览器输入 `http://127.0.0.1:47180/` 即可。

## 本地面板（可选）

配置里写 `panelPort: 47180` 并重启，浏览器打开 http://127.0.0.1:47180 就能看到：

- 当前发送方案（A/B）与一键切换
- 自检结果、配置摘要、日志尾巴（不用去翻 plugin.log）
- 收藏表情墙，点一下就把那张表情发出去
- **参数区：私聊/群聊冷却、时间闸、积压合批、轮询间隔、群触发词，改完点保存立即生效**（不用重启，也不用碰 YAML）
- **白名单 / 黑名单**：白名单 = 监控并回复的会话（写 `watched-chats.txt`），黑名单 = 永不回复（写 `settings.json`，优先级最高）
- **人设提示词**：直接编辑工作区的 `AGENTS.md`（默认 `<dataDir>/sessions/AGENTS.md`），保存自动留备份，下一轮回复就生效

面板改的东西落在三个文件：「参数 + 黑名单」进 `<wcdb>/settings.json`，「白名单」进 `<wcdb>/watched-chats.txt`，「人设」就是工作区那个 `AGENTS.md`，都是纯文本，想手改也行。

只绑 127.0.0.1；要转发端口就设 `panelToken`，访问时带 `?token=...`。

---

## 常用配置

| 键 | 默认 | 说明 |
|---|---|---|
| `dataDir` | `~/.dsh/weixin` | 数据根目录，`~` 与 `%ENV%` 会被展开 |
| `wcdbDir` | `<dataDir>/wcdb` | 辅助脚本目录 |
| `dbDir` | — | 小号微信 `db_storage`，必填 |
| `chatUser` / `peerName` | — | 对方 wxid / 显示名 |
| `directCooldownMs` | `20000` | 私聊 20 秒内只回一条 |
| `groupCooldownMs` | `300000` | 群聊 5 分钟 |
| `groupTriggers` | `['@大肥鱼','@肥鱼']` | 群里命中这些才回 |
| `staleSkipSeconds` | `172800` | 48 小时以外不回；`0` 关闭 |
| `backlogAgeSeconds` / `backlogHoldSeconds` | `60` / `4` | 积压合批：老消息先压 4 秒，只留最新 |
| `maxReplyChars` | `1800` | 单条上限，超了自动拆分 |
| `autoSend` | `true` | 关掉只记账不发 |
| `panelPort` | `0` | 本地面板端口，0 = 关闭 |

> 上面这些「秒」为单位的参数，装好后都可以在面板里直接改，写进 `<wcdb>/settings.json`，优先级高于 profile 里的 YAML；不用重启。

---

## 故障排查

| 现象 | 原因 | 做法 |
|---|---|---|
| 微信里什么都不回 | — | 先发 `/doctor` |
| 回复打了没发出去 | 窗口在托盘：`GetWindowRect = (-32000,-32000,199,34)` | 脚本会自己 `ShowWindow` 摆回 `0,0,1500,830`；持续失败说明窗口被别的账号占用 |
| 日志 `the open chat is not '张三'` | 窗口停在别的会话 | `wx_find_chat.ps1 -Name 张三` 手动切；`-ExpectChat` 会自动切 |
| 有 inbound 但没回复 | 会话桥没加载 | 装 `dsh-plugin-weixin`，或配 `bridgePath` |
| 表情包发不出去 | 收藏页几何变了 | `wx_sticker.py --slow` 重新量面板 |
| 开机后把几天前的消息全回了 | 老版本没有时间闸 | 升级后 `staleSkipSeconds` 48 小时兜底 |

日志：`<dataDir>/wcdb/plugin.log`。

---

## 会话桥说明

会话桥不在本仓库里，它来自 `dsh-plugin-weixin`——两个插件共用同一个 AgentBridge，才能保证「同一条微信会话始终落到同一个 DSH 会话」。

1. 推荐：一起装 `dsh-plugin-weixin`，插件启动会在 profile 的 `node_modules` 里自动找到它。
2. 装在别处：配置里写 `bridgePath`。

两者都没有时，插件启动会明确告诉你缺什么，而不是静默不出声。

---

## 安全边界

- 密钥、聊天记录、表情库全部留在本机。
- `plugin.log` 含对方昵称与消息摘要，分享前先看一眼。
- 只用在自己的号上。接到别人的号或拿来群发营销，既违规也大概率触发微信风控。

---

## 路线图

- [x] 48 小时时间闸 + 积压合批只回最新
- [x] 引用消息解析
- [x] `/doctor` 自检 + 可移植配置
- [ ] DSH 设置里的可视化面板（模式、会话清单、表情库试发、日志）
- [ ] 表情包按内容自动挑
- [ ] 首次安装向导

---

## 维护者：发布到 npm

见 PUBLISHING.md。发布后别人一行就能装：`dsh plugin --profile web add dsh-wx-desktop`。

## 许可

MIT。微信是腾讯的商标，本项目与之无关；使用前请确认不违反当地法规与服务条款。
