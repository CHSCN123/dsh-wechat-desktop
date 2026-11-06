# dsh-wx-desktop — WeChat Desk Bridge

> Turn the **desktop WeChat client on your own Windows machine** into an agent channel for DSH: read the local message DB, wake a session, type the answer back into the chat window.

This is not an auto-reply bot for strangers. It makes your *own* WeChat client another way to talk to an agent running on your machine. The community plugin `dsh-plugin-weixin` covers the iLink bot half; this one covers the real client window.

---

## What it does

- Watches the bot account's local WeChat message DB and wakes the DSH session bound to that conversation
- Reads text, images, stickers, locations and **quoted messages** (including the quoted content)
- Types the reply back into the chat (paste + Enter), then verifies the chat area actually changed
- Groups: only answers when mentioned, 5 min cooldown. Direct chats: 20 s cooldown
- Backlog guard: messages older than 48 h are dropped, and a burst of queued messages is coalesced down to the newest one
- Two send strategies: **A** = WeChat inside a Windows virtual desktop (never steals your mouse/keyboard), **B** = plain main-desktop automation; A falls back to B automatically
- Stickers: can send a favourite sticker by index (template matching + page scrolling)

## What it does not do

- No voice messages (the desktop client cannot send them)
- No payments, no transfers, no addresses, no captchas
- No protocol RE, no third-party accounts — it only drives the client you are logged into
- Windows only; no bulk messaging

## Requirements

| | |
|---|---|
| OS | Windows 10 / 11 |
| WeChat | 4.x desktop |
| Python | **3.14+** (`compression.zstd`) |
| Node | **24+** (`node:sqlite`, `zlib.zstd*`) |
| DSH | 0.2.x |
| Peer plugin | `dsh-plugin-weixin` (provides the AgentBridge) |

## Install

### One command (recommended)

```powershell
git clone https://github.com/CHSCN123/dsh-wechat-desktop.git
cd dsh-wechat-desktop
powershell -ExecutionPolicy Bypass -File .\install.ps1 `
  -DbDir    'D:\WeChat\xwechat_files\wxid_xxx\db_storage' `
  -ChatUser 'wxid_xxx' `
  -PeerName 'Alice'
```

`install.ps1` locates your DSH install, adds the plugin to the profile with `dsh plugin --profile web add`, ensures it is listed in `dsh.profile.bundles`, then runs `setup.ps1` to write the config block. Options: `-SkipConfig`, `-LocalPath`, `-PanelPort`, `-Profile`, `-DshHome`.

Restart DSH afterwards; a **WeChat Desk Bridge** section appears in Settings.

### Manual steps

```powershell
dsh plugin --profile web add dsh-wx-desktop
dsh plugin --profile web add dsh-plugin-weixin
```

Copy `scripts/` into `%USERPROFILE%\.dsh\weixin\wcdb\` (or point `wcdbDir` at it), then:

```powershell
python %USERPROFILE%\.dsh\weixin\wcdb\wcdb_key_tool_windows.py   # export the DB key -> key.json
python %USERPROFILE%\.dsh\weixin\wcdb\watch.py --once            # first decrypt + probe
```

Add to `%APPDATA%\dsh-desktop\harness\profiles\web\cordis.patch.yml`:

```yaml
- id: dsh-wx-desktop
  disabled: false
  config:
    dataDir: 'C:\Users\<you>\.dsh\weixin'
    dbDir: 'D:\WeChat\xwechat_files\wxid_xxx\db_storage'
    chatUser: 'wxid_xxx'
    peerName: 'Alice'
```

Restart DSH and send `/doctor` from WeChat.

## Commands

| Command | Meaning |
|---|---|
| `/doctor` | Preflight: Python/Node version, scripts, DB, key, session bridge |
| `/new` | Start a fresh session line for this conversation |
| `/mode a` / `/mode b` | Switch send strategy |

## Notes on the session bridge

The bridge lives in `dsh-plugin-weixin` (`src/agent-bridge.js`) — both plugins share it so a WeChat conversation always lands in the same DSH session. Install it, or set `bridgePath` explicitly. If neither exists the plugin says so at startup instead of failing silently.

## Known fragility

WeChat updates move controls and re-encode panels; windows can end up in the tray at `(-32000,-32000)`; DPI changes break coordinates. The scripts re-measure and self-heal where they can, and `plugin.log` records every step so you can see which stage gave up.

## License

MIT. WeChat is a Tencent trademark; this project is unaffiliated. Check your local law and the service terms before use.
