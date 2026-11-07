## 0.3.2 — 2026-11-07

- 面板从「只能看」变成能用：
  - **参数区**：私聊冷却、群聊冷却、时间闸、积压合批、轮询间隔、群触发词，改完点保存立即生效。
  - **白名单 / 黑名单**：白名单写 `watched-chats.txt`（同时也是 watcher 的轮询名单），黑名单写 `settings.json`，黑名单优先级最高。
- 新增 `settings.js`：面板改的值落在 `<wcdb>/settings.json`，优先级高于 profile 的 YAML，插件每次处理消息时现读，改完不用重启。
- 新增路由：`GET/POST /api/settings`、`POST /api/chats`、`POST /api/blacklist`。
- **人设提示词也能在面板里改**：新增 `GET/POST /api/persona`，直接编辑工作区的 `AGENTS.md`（默认 `<dataDir>/sessions/AGENTS.md`），保存时自动留 `.bak-panel-<时间>` 备份，下一轮生效、不用重启。
- 回复前先过黑白名单：不在白名单的会话直接跳过（日志 `skip …: not in whitelist`），黑名单命中 `skip …: blacklisted`。
- `tools/panel-test.mjs` 扩成设置 / 名单 / 人设全流程冒烟（临时目录，不碰真实数据）。

## 0.3.1 — 2026-11-06

- 一行安装：`bootstrap.ps1`（下载源码 → 装插件 → 写配置），README 中英同步。
- `install.ps1`：自动探测本机 DSH（运行中的 exe / 常见安装目录 / PATH 里的 dsh），自动列出微信数据目录并交互确认，缺会话桥时给提示。
- `package.json`：补 repository / homepage / bugs / publishConfig，`files` 带上安装脚本；可直接 npm publish。
- 新增 `PUBLISHING.md`（维护者发布流程）。

## 0.3.0 — 2026-11-06

- 设置页入口：`client.js` 注册 `settings.section`，DSH 设置里直接出现「微信桌面桥」，内嵌面板（iframe），也可在新窗口打开。
- `package.json` 增加 `dsh.client`（platform: web + inject）、导出 `./client`。
- 面板地址统一走 `panelPort`（默认 47180）。
# 更新日志

## 0.2.0 — 2026-11-06

第一个「可以给别人装」的版本。

### 新增

- **本地面板** `panel.js`：`panelPort` 打开后访问 `http://127.0.0.1:<port>`，可看自检、配置摘要、日志尾巴，一键切 A/B 方案，点收藏表情直接发。
- **`/doctor` 自检命令**（也认 `/自检` `/体检`）：检查数据目录、脚本、密钥、数据库、Python 3.14+、Node 24+，缺什么直接说怎么补。
- **首次安装向导** `setup.ps1`：检查环境 → 复制脚本 → 写 profile 配置（带标记，重复执行只更新，不会重复定义）。
- **过时消息闸**：`staleSkipSeconds`（默认 48 小时）——电脑关着期间攒下的消息，超过窗口的直接不回。
- **积压合批**：一开机涌进十几条时，只回最新的那条（`backlogAgeSeconds` / `backlogHoldSeconds`）。
- **引用消息解析**：别人引用某条消息时，把被引用的内容一起给模型看（文字/图片/表情/语音/视频都有标注）。
- **表情包**：收到表情时解析出图片给模型看；可以按收藏序号精确回发（`wx_sticker.ps1 -Index N`）。

### 变更

- 配置全部支持可移植写法：`~` 展开成用户目录、`%ENV%` 展开成环境变量；`dataDir` 之外的路径留空就按 `dataDir` 推导。旧版本里写死的本机绝对路径已全部移除。
- 会话桥改为**自动查找** `dsh-plugin-weixin` 的 `agent-bridge`；找不到时报错会告诉你装哪个包、或者怎么用 `bridgePath` 指过去。
- 运行时脚本收进仓库 `scripts/`（52 个），安装时由 `setup.ps1` 复制到数据目录。
- `package.json` 去掉了 `private`，补齐 `engines`（Node ≥24）、`os`（win32）、`files`。

### 修复

- 发送失败时不再静默：会写明是窗口不在位、还是聊天区没变化（消息可能没发出去）。
- 小号微信被收进托盘时，窗口坐标会变成 `-32000`，脚本会先把它摆回 (0,0) 再操作，摆不回来就报错而不是瞎点。
- 面板的图片路径修正到 `sticker_lab/fav/`。

---

## 0.1.0 — 2026-10-30

- 首个可用版本：接管桌面微信，收消息进 DSH 会话、模型回复自动打回微信；A（虚拟桌面）/ B（主桌面）两种发送方案，A 失败自动降级 B。
