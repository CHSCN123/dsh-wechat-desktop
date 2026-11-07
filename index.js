/**
 * dsh-wx-desktop — drive a DSH agent from the DESKTOP WeChat client.
 *
 * The iLink bot channel (dsh-plugin-weixin) can only see messages that arrive
 * through the bot account. This plugin covers the other half: the real WeChat
 * client running on this machine. It watches the (decrypted) local message DB
 * for one conversation, hands each inbound message to a DSH agent session
 * through the same AgentBridge the weixin plugin uses, and types the agent's
 * answer back into the WeChat input box (clipboard + Enter).
 *
 * Pipeline:
 *   watch.py (child process)  --@@MSG json-->  AgentBridge.deliver()  -->  wx_send.ps1
 *
 * Everything is change-driven: no screenshots, no polling of the screen, and
 * no kernel injection while the DB is idle.
 */
import { spawn, spawnSync } from 'node:child_process'
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { appendFile, unlink, writeFile } from 'node:fs/promises'
import { startPanel } from './panel.js'
import { applySettings, readChatList, readSettings, sanitizePatch, writeChatList, writeSettings } from './settings.js'
import { homedir, tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { pathToFileURL } from 'node:url'

export const name = 'dsh-wx-desktop'
export const inject = ['agents']

/**
 * We reuse the AgentBridge that `dsh-plugin-weixin` ships: it already knows how to
 * create/lookup a DSH session for a conversation id, steer a running turn and
 * collect the reply. Its package exports map hides `src/agent-bridge.js`, so it is
 * imported by absolute path — and the path is resolved at startup instead of being
 * baked in, because the profile directory differs per machine.
 */
const BRIDGE_RELATIVE = ['node_modules', 'dsh-plugin-weixin', 'src', 'agent-bridge.js']

/**
 * Candidate locations for the bridge, best first: explicit config, the DSH home of
 * this process, the caller's profile, then a couple of usual install roots.
 */
export function findBridgePath(cfg) {
  const explicit = expandPath(cfg?.bridgePath ?? '')
  if (explicit !== '') return explicit
  const roots = []
  const dshHome = process.env.DSH_HOME
  if (dshHome) roots.push(dshHome)
  if (process.env.APPDATA) roots.push(join(process.env.APPDATA, 'dsh-desktop', 'harness'))
  if (process.env.HOME) roots.push(join(process.env.HOME, '.dsh'))
  if (process.env.USERPROFILE) roots.push(join(process.env.USERPROFILE, '.dsh'))
  for (const root of roots) {
    for (const profile of ['web', 'headless', 'cli']) {
      const candidate = join(root, 'profiles', profile, ...BRIDGE_RELATIVE)
      if (existsSync(candidate)) return candidate
    }
    const direct = join(root, ...BRIDGE_RELATIVE)
    if (existsSync(direct)) return direct
  }
  return join(roots[0] ?? '', ...BRIDGE_RELATIVE)
}

/**
 * Defaults only — no schemastery schema, so the module stays importable without
 * extra packages. The cordis.patch.yml entry overrides any field it names.
 */
export const DEFAULTS = {
  enabled: true,
  /** Absolute path to dsh-plugin-weixin's src/agent-bridge.js. Empty = autodetect. */
  bridgePath: '',
  /** Local control panel port. 0 = off. Binds 127.0.0.1 only. */
  panelPort: 0,
  /** 可选：面板密码（要给别的机器/端口转发时设）。 */
  panelToken: '',
  /**
   * Root for everything this plugin writes: decrypted DB copies, inbox spool,
   * logs, sticker cache. `~` and `%ENV%` are expanded at startup, so the shipped
   * defaults contain no machine-specific absolute paths.
   */
  dataDir: '~/.dsh/weixin',
  /** Where the helper scripts live. Empty = <dataDir>/wcdb (or <repo>/scripts). */
  wcdbDir: '',
  /** Python 3.14+ (needs `compression.zstd`). Empty = autodetect. */
  pythonPath: '',
  /** Empty = `<dataDir>/wcdb/watch.py`. */
  watcherScript: '',
  /** Node 24+ (`node:sqlite`, `zlib.zstd*`). Empty = autodetect. */
  nodePath: '',
  /** Empty = `<dataDir>/wcdb/sticker_resolve.mjs`. */
  stickerResolveScript: '',
  keysFile: '',
  /**
   * The WeChat data directory of the bot account (the one holding `db_storage`).
   * Required: every install picks its own folder, so it cannot be guessed.
   */
  dbDir: '',
  decryptDir: '',
  inboxPath: '',
  /** The person on the other end of the desktop WeChat chat (wxid). */
  chatUser: '',
  peerName: '',
  /** Session key: decides which DSH session this channel writes into. */
  conversationId: '',
  cwd: '',
  intervalSeconds: 1.5,
  autoSend: true,
  sendScript: '',
  sayScript: '',
  /** Windows PowerShell: this host has no pwsh 7 on PATH, and 5.1 is always there. */
  powershellPath: '%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',
  /** 0 = resolve the WeChat main window at send time. */
  hwnd: 0,
  xFrac: 0.47,
  yFrac: 0.79,
  maxReplyChars: 1800,
  /** Mirror of every log line, so a dead harness can still be debugged afterwards. */
  logPath: '',
  /**
   * 会话切换不在这里配置：wx_send.ps1 自己按 -ExpectChat 调 wx_find_chat.ps1 并校验表头。
   * （wx_open_chat.ps1 只是老调用方的薄壳，仍留给 wx_proactive.ps1 用。）
   */
  /** Plan A: client for the on-demand helper that lives on the virtual desktop. */
  vdeskClientScript: '',
  /** wxid|nickname lines: also used to name conversations and to open them. */
  chatListFile: '',
  settingsFile: '',
  /** One DSH session per conversation: `desktop:<chat>`. */
  conversationPrefix: 'desktop:',
  /** 1:1 chats: ignore a burst of messages that arrive within this window. */
  directCooldownMs: 20_000,
  /**
   * Messages older than this are treated as backlog (the watcher was down, or the
   * client was offline and the queue flushed at login) and are NOT answered.
   * 0 disables the check. 2026-11-06: 48 h, because a machine switched off for a
   * day and a half should still answer the newest message on login.
   */
  staleSkipSeconds: 172_800,
  /** Messages already this old count as backlog and get coalesced, not answered one by one. */
  backlogAgeSeconds: 60,
  /** How long a backlog burst is held so that only its newest message survives. */
  backlogHoldSeconds: 4,
  /** Groups: only answer this often, and only when addressed. */
  groupCooldownMs: 300_000,
  groupDailyLimit: 12,
  /**
   * In a group, only react when the text contains one of these.
   * 只用名字触发：早期写的是 ['@']，但卡片类消息（视频号/图片）里带着
   * `<fromusr>xxx@chatroom</fromusr>` 这种 XML，'@' 会无条件命中 →
   * 没被艾特也会回，把群聊刷屏（2026-10-25 22:32 被用户抓到）。
   */
  groupTriggers: ['@大肥鱼', '@肥鱼'],
  remotePrefix:
    '（来源：本机电脑微信客户端，不是 iLink 机器人通道。回复会自动打回微信窗口，直接写正文即可。）',
}

const HOME_DIR = homedir()

/** `~` → home directory, `%NAME%` → environment variable. */
export function expandPath(value) {
  const raw = String(value ?? '').trim()
  if (raw === '') return ''
  const withHome = /^~([\\/]|$)/.test(raw) ? join(HOME_DIR, raw.replace(/^~[\\/]?/, '')) : raw
  return withHome.replace(/%([A-Za-z_][A-Za-z0-9_]*)%/g, (whole, name) => process.env[name] ?? whole)
}

const PATH_KEYS = [
  'dataDir', 'wcdbDir', 'pythonPath', 'watcherScript', 'nodePath', 'stickerResolveScript', 'keysFile',
  'dbDir', 'decryptDir', 'inboxPath', 'cwd', 'sendScript', 'sayScript', 'powershellPath',
  'logPath', 'vdeskClientScript', 'chatListFile',
]

/**
 * Turn user config into the flat, absolute shape the rest of the plugin uses:
 * expand `~`/`%ENV%`, derive the empty script paths from `dataDir`, and build the
 * conversation id from the chat id when the user did not pin one.
 */
export function resolveConfig(input) {
  const cfg = { ...input }
  for (const key of PATH_KEYS) cfg[key] = expandPath(cfg[key])
  if (cfg.dataDir === '') cfg.dataDir = join(HOME_DIR, '.dsh', 'weixin')
  const wcdb = cfg.wcdbDir !== '' ? cfg.wcdbDir : join(cfg.dataDir, 'wcdb')
  cfg.wcdbDir = wcdb
  const fill = (key, fallback) => {
    if (cfg[key] === '' || cfg[key] === undefined) cfg[key] = fallback
  }
  fill('watcherScript', join(wcdb, 'watch.py'))
  fill('stickerResolveScript', join(wcdb, 'sticker_resolve.mjs'))
  fill('keysFile', join(wcdb, 'key.json'))
  fill('decryptDir', join(wcdb, 'decrypted'))
  fill('inboxPath', join(wcdb, 'inbox.jsonl'))
  fill('logPath', join(wcdb, 'plugin.log'))
  fill('sendScript', join(wcdb, 'wx_send.ps1'))
  fill('sayScript', join(wcdb, 'wx_say.ps1'))
  fill('vdeskClientScript', join(wcdb, 'wx_vdesk_client.ps1'))
  fill('chatListFile', join(wcdb, 'watched-chats.txt'))
  fill('settingsFile', join(wcdb, 'settings.json'))
  fill('cwd', join(cfg.dataDir, 'sessions'))
  if (cfg.conversationId === '' && cfg.chatUser !== '') {
    cfg.conversationId = `${cfg.conversationPrefix ?? 'desktop:'}${cfg.chatUser}`
  }
  return cfg
}

function stamp() {
  const d = new Date()
  const p = (n) => String(n).padStart(2, '0')
  return `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`
}

/** XML/HTML → one readable line (WeChat wraps every text field in markup). */
export function stripXml(value) {
  return String(value ?? '')
    .replace(/<br\s*\/?>/gi, ' ')
    .replace(/<[^>]+>/g, '')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, '&')
    .replace(/\s+/g, ' ')
    .trim()
}

/** First `<tag>…</tag>` body of an XML blob, raw (may be nested XML itself). */
function xmlTag(xml, tagName) {
  const match = new RegExp(`<${tagName}>([\\s\\S]*?)</${tagName}>`, 'i').exec(String(xml ?? ''))
  return match ? match[1] : ''
}

/**
 * WeChat turns "回复/引用某条消息" into an appmsg (local_type 49) that carries a
 * <refermsg> block: <displayname> who was quoted, <content> the quoted text.
 * Without this the agent only saw "[对方发来一个卡片/链接]" and answered blind.
 */
export function parseQuote(xml) {
  const inner = xmlTag(xml, 'refermsg')
  if (inner === '') return null
  const displayname = stripXml(xmlTag(inner, 'displayname'))
  const rawContent = xmlTag(inner, 'content')
  // A quoted card/sticker is itself XML: prefer its <title>, else strip tags.
  const title = stripXml(xmlTag(rawContent, 'title'))
  const text = title !== '' ? title : stripXml(rawContent)
  const type = stripXml(xmlTag(inner, 'type'))
  return { displayname, text, type }
}

const PYTHON_CANDIDATES = [
  { command: 'python', args: [] },
  { command: 'python3', args: [] },
  { command: 'py', args: ['-3'] },
]

/**
 * Preflight: everything a fresh install gets wrong shows up here instead of as a
 * silent "nothing happens". Returns `{ ok, report: [{ ok, item, detail }] }`.
 * Pure reads + one short python probe, so it is safe to call from a command.
 */
export function selfCheck(cfg) {
  const report = []
  const add = (ok, item, detail) => report.push({ ok: Boolean(ok), item, detail: String(detail ?? '') })

  add(existsSync(cfg.dataDir), 'dataDir', cfg.dataDir)
  add(existsSync(cfg.watcherScript), 'watch.py', cfg.watcherScript)
  add(existsSync(cfg.sendScript), 'wx_send.ps1', cfg.sendScript)
  add(existsSync(cfg.sayScript), 'wx_say.ps1', cfg.sayScript)
  add(existsSync(cfg.keysFile), 'key.json', cfg.keysFile === '' ? '(未配置)' : cfg.keysFile)
  if (cfg.dbDir === '') {
    add(false, 'dbDir', '未配置：必须指向小号微信的 db_storage 目录')
  } else {
    const hasDb =
      existsSync(join(cfg.dbDir, 'message')) || existsSync(join(cfg.dbDir, 'contact'))
    add(existsSync(cfg.dbDir) && hasDb, 'dbDir', cfg.dbDir)
  }

  // Python with `compression.zstd` (3.14+). Without it no inbound text is readable.
  const candidates = cfg.pythonPath === '' ? PYTHON_CANDIDATES : [{ command: cfg.pythonPath, args: [] }]
  let pythonOk = false
  let pythonSeen = ''
  for (const candidate of candidates) {
    try {
      const probe = spawnSync(candidate.command, [...candidate.args, '-c', 'import compression.zstd'], {
        timeout: 8_000,
        windowsHide: true,
        encoding: 'utf8',
      })
      if (probe.status === 0) {
        pythonOk = true
        pythonSeen = candidate.command
        break
      }
      if (pythonSeen === '' && probe.error === undefined) pythonSeen = candidate.command
    } catch {
      // keep probing
    }
  }
  add(pythonOk, 'python(compression.zstd)', pythonOk ? pythonSeen : '找不到 3.14+ 的 Python（需要 compression.zstd）')

  // Node 24+ for sticker rows (node:sqlite + zlib.zstdDecompressSync).
  let nodeOk = false
  let nodeDetail = cfg.nodePath === '' ? '(自动)' : cfg.nodePath
  const nodeCmd = cfg.nodePath === '' ? 'node' : cfg.nodePath
  try {
    const probe = spawnSync(nodeCmd, ['-e', 'process.exit(Number(process.versions.node.split(".")[0]) >= 24 ? 0 : 1)'], {
      timeout: 8_000,
      windowsHide: true,
      encoding: 'utf8',
    })
    nodeOk = probe.status === 0
    if (nodeOk) nodeDetail = `${nodeCmd} ${String(probe.stdout ?? '').trim()}`
  } catch {
    // fall through with nodeOk = false
  }
  add(nodeOk, 'node 24+', nodeDetail)

  const bad = report.filter((row) => !row.ok)
  return { ok: bad.length === 0, report }
}

/** One compact line per failing check — this is what the chat command shows. */
export function formatSelfCheck(result) {
  if (result.ok) {
    return '自检全过：Python 3.14+、Node 24+、脚本、数据库、密钥都在。'
  }
  const lines = result.report.map((row) => `${row.ok ? '√' : '×'} ${row.item}：${row.detail}`)
  return `自检 ${result.report.length - result.report.filter((r) => !r.ok).length}/${result.report.length} 通过\n${lines.join('\n')}`
}

export function apply(ctx, config) {
  const cfg = resolveConfig({ ...DEFAULTS, ...(config ?? {}) })
  // 面板可改的参数（冷却 / 时间闸 / 合批 / 轮询间隔 / 触发词 / 黑名单）存在
  // <wcdb>/settings.json，每次用它时现读，改完不用重启。
  const eff = () => applySettings(cfg, readSettings(cfg))
  const fileLog = (level, line) => {
    appendFile(cfg.logPath, `${new Date().toISOString()} ${level} ${line}\n`, 'utf8').catch(() => {})
  }
  const log = (line) => {
    ctx.logger?.info?.(`wx-desktop: ${line}`)
    fileLog('INFO', line)
  }
  const warn = (line) => {
    ctx.logger?.warn?.(`wx-desktop: ${line}`)
    fileLog('WARN', line)
  }

  if (cfg.enabled === false) {
    log('disabled by configuration')
    return
  }

  // Hot reloading the plugin leaves more than one live copy behind, and every copy
  // spawns its own watcher / agent bridge: one inbound message then gets answered
  // twice (once from a context that is already inactive, so it replies with
  // "(模型调用失败: cannot create effect on inactive context)"). Keep a single owner.
  const instanceFile = join(cfg.cwd ?? '.', '..', 'wcdb', 'plugin-instance.json')
  try {
    const prev = existsSync(instanceFile)
      ? JSON.parse(readFileSync(instanceFile, 'utf8'))
      : undefined
    if (prev && Number.isInteger(prev.pid) && prev.pid !== process.pid) {
      let alive = false
      try {
        process.kill(prev.pid, 0)
        alive = true
      } catch {
        alive = false
      }
      const fresh = Date.now() - Number(prev.at ?? 0) < 24 * 60 * 60 * 1000
      if (alive && fresh) {
        warn(`another plugin instance (pid=${prev.pid}) is already running; standing down`)
        return
      }
    }
    Object.assign(globalThis, { __wxDesktopInstance: process.pid })
    writeFileSync(
      instanceFile,
      JSON.stringify({ pid: process.pid, at: Date.now() }),
      'utf8',
    )
  } catch (error) {
    warn(`instance lock skipped: ${error.message}`)
  }

  // Wrapped so that a wiring mistake can never abort the whole plugin tree:
  // a failing required entry takes DSH's startup down with it.
  const install = () => {
    let cancelled = false
    /** @type {import('node:child_process').ChildProcess | undefined} */
    let watcher
    let bridge
    let retryTimer
    /** serializes deliveries so replies cannot interleave with each other */
    let chain = Promise.resolve()

    const bridgePath = findBridgePath(cfg)
    const removeWatcher = () => {
      if (watcher !== undefined && watcher.exitCode === null) {
        // `kill()` is SIGTERM, which a Windows python child can ignore; the
        // tree kill is what actually frees the single-instance lock.
        try {
          spawn('taskkill', ['/PID', String(watcher.pid), '/T', '/F'], {
            stdio: 'ignore',
            windowsHide: true,
          }).unref()
        } catch {}
        try {
          watcher.kill()
        } catch {}
      }
      watcher = undefined
    }

    const startWatcher = () => {
      if (cancelled) return
      const args = [
        cfg.watcherScript,
        '--user', cfg.chatUser,
        '--interval', String(eff().intervalSeconds),
        '--out', cfg.inboxPath,
        '--db-dir', cfg.dbDir,
        '--dec', cfg.decryptDir,
        '--keys', cfg.keysFile,
      ]
      log(`starting watcher (${cfg.watcherScript})`)
      const child = spawn(cfg.pythonPath, args, {
        cwd: dirname(cfg.watcherScript),
        stdio: ['ignore', 'pipe', 'pipe'],
        windowsHide: true,
      })
      watcher = child
      let buf = ''
      child.stdout.setEncoding('utf8')
      child.stdout.on('data', (chunk) => {
        buf += chunk
        let idx
        while ((idx = buf.indexOf('\n')) >= 0) {
          const line = buf.slice(0, idx).trimEnd()
          buf = buf.slice(idx + 1)
          onWatcherLine(line)
        }
      })
      child.stderr.setEncoding('utf8')
      child.stderr.on('data', (chunk) => warn(`watcher stderr: ${String(chunk).trim().slice(0, 400)}`))
      child.on('error', (error) => warn(`watcher spawn failed: ${String(error)}`))
      child.on('exit', (code, signal) => {
        if (cancelled) return
        if (code === 3) {
          // Another plugin instance already owns the watch (single-instance lock
          // inside watch.py). Respawning would only fight over it every 5s.
          log('another instance owns the watcher; standing down')
          return
        }
        warn(`watcher exited (code=${code} signal=${signal}); retrying in 5s`)
        retryTimer = setTimeout(startWatcher, 5_000)
      })
    }

    /**
     * Backlog coalescing. When the client has been offline (or the watcher was
     * down) the DB can flush a burst of unseen rows at once; the machine was off,
     * so nobody is waiting for answers to "在吗?" from two days ago. Messages whose
     * own timestamp already looks old are held for a few seconds and the newest
     * one wins — live traffic (fresh timestamp) always goes straight through, so
     * normal chat keeps its latency.
     */
    const pendingInbound = new Map()
    const ageSeconds = (msg) => {
      const epoch = Number(msg?.time ?? 0)
      return Number.isFinite(epoch) && epoch > 0 ? Math.floor(Date.now() / 1000 - epoch) : 0
    }
    const dispatchInbound = (msg) => {
      chain = chain.then(() => handleInbound(msg)).catch((error) => warn(`inbound failed: ${String(error)}`))
    }
    const enqueueInbound = (msg) => {
      const chat = String(msg?.chat ?? '')
      const live = eff()
      const hold = Number(live.backlogHoldSeconds ?? 0)
      if (!(hold > 0) || ageSeconds(msg) < Number(live.backlogAgeSeconds ?? 60)) {
        dispatchInbound(msg)
        return
      }
      const previous = pendingInbound.get(chat)
      if (previous !== undefined) {
        clearTimeout(previous.timer)
        log(`coalesce ${chat}: keep newest (${String(msg?.local_id ?? '?')}), drop ${String(previous.msg?.local_id ?? '?')}`)
      }
      const timer = setTimeout(() => {
        pendingInbound.delete(chat)
        dispatchInbound(msg)
      }, Math.max(200, Math.round(hold * 1000)))
      timer.unref?.()
      pendingInbound.set(chat, { msg, timer })
    }

    const onWatcherLine = (line) => {
      if (line === '') return
      if (line.startsWith('@@MSG ')) {
        let msg
        try {
          msg = JSON.parse(line.slice('@@MSG '.length))
        } catch (error) {
          warn(`bad @@MSG payload: ${String(error)}`)
          return
        }
        if (msg?.is_self === true) return
        enqueueInbound(msg)
        return
      }
      // [watch] / [NEW] lines are diagnostics
      log(line)
    }

    /**
     * Inbound stickers (local_type 47) carry their payload as zstd-compressed XML
     * that watch.py's python cannot decompress, so the agent used to see only
     * "[对方发来一个表情]". sticker_resolve.mjs re-reads the row with node:sqlite
     * and turns the md5 into a PNG on disk, which the agent can open directly.
     */
    const resolveSticker = async (msg) => {
      const chat = String(msg?.chat ?? '')
      if (chat === '' || cfg.stickerResolveScript === undefined) return null
      const args = [cfg.stickerResolveScript, '--chat', chat]
      if (msg?.local_id !== undefined) args.push('--local-id', String(msg.local_id))
      else args.push('--last', '1')
      const out = await new Promise((resolvePromise) => {
        const child = spawn(cfg.nodePath, args, { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true })
        let buf = ''
        child.stdout.setEncoding('utf8')
        child.stdout.on('data', (chunk) => { buf += chunk })
        child.on('error', () => resolvePromise(''))
        child.on('close', () => resolvePromise(buf.trim()))
      })
      if (out === '') return null
      try {
        return JSON.parse(out.split('\n').filter(Boolean).pop())
      } catch {
        return null
      }
    }

    const describe = async (msg) => {
      const type = msg?.type
      if (type === 3) return '[对方发来一张图片，内容未解析]'
      if (type === 47) {
        const info = await resolveSticker(msg)
        if (info?.ok === true && typeof info.file === 'string' && info.file !== '') {
          const bits = []
          if (typeof info.text === 'string' && info.text !== '') bits.push(`图上文字「${info.text}」`)
          if (Array.isArray(info.tags) && info.tags.length > 0) bits.push(`标签：${info.tags.join('/')}`)
          if (info.index !== null && info.index !== undefined) bits.push(`收藏序号 ${info.index}，可用 wx_sticker --index ${info.index} 回发`)
          else bits.push('这不是收藏里的表情（只能回文字或发图）')
          return `[对方发来一个表情] 图片：${info.file}${bits.length ? '（' + bits.join('；') + '）' : ''}`
        }
        if (typeof info?.md5 === 'string' && info.md5 !== '') {
          return `[对方发来一个表情] 已识别 md5=${info.md5}，但拿不到图片（${String(info.error ?? 'unknown')}）`
        }
        return '[对方发来一个表情]'
      }
      if (type === 34) return '[对方发来一条语音]'
      if (type === 43) return '[对方发来一段视频]'
      if (type === 49) {
        const rawXml = String(msg?.text ?? '')
        const quote = parseQuote(rawXml)
        const own = stripXml(xmlTag(rawXml, 'title'))
        if (quote !== null) {
          const who = quote.displayname === '' ? '' : `${quote.displayname}的`
          const kind = String(quote.type ?? '')
          const media =
            kind === '3' ? '[图片]'
            : kind === '47' ? '[表情]'
            : kind === '34' ? '[语音]'
            : kind === '43' ? '[视频]'
            : kind === '49' ? stripXml(quote.text)
            : ''
          const quoted = media !== '' ? media : quote.text === '' ? '(无文字内容)' : quote.text
          const tail = own !== '' && own !== quoted ? `；对方这次说：${own}` : ''
          return `[对方引用了${who}一条消息] 被引用内容：${quoted}${tail}`
        }
        return own !== '' ? `[对方发来一个卡片/链接] ${own}` : '[对方发来一个卡片/链接]'
      }
      const text = String(msg?.text ?? '').trim()
      return text === '' ? '[空消息]' : text
    }

    const chatNames = new Map()
    const loadChatNames = () => {
      chatNames.set(cfg.chatUser, cfg.peerName)
      try {
        const lines = readFileSync(cfg.chatListFile, 'utf8').split(/\r?\n/)
        for (const line of lines) {
          const trimmed = line.trim()
          if (trimmed === '' || trimmed.startsWith('#')) continue
          const [id, name] = trimmed.split('|')
          if (id) chatNames.set(id.trim(), String(name ?? '').trim())
        }
      } catch (error) {
        warn(`chat list unreadable: ${String(error)}`)
      }
    }
    const isGroup = (chat) => chat.endsWith('@chatroom')
    const lastReplyAt = new Map()
    const groupBudget = new Map()
    const dayKey = () => new Date().toISOString().slice(0, 10)

    const handleInbound = async (msg) => {
      if (bridge === undefined) {
        warn('bridge not ready; dropping one message')
        return
      }
      const chat = String(msg?.chat ?? cfg.chatUser)
      const group = isGroup(chat)
      // 先读一次名单再取名：以前是先取名后 loadChatNames()，插件刚启动或
      // 名单刚改过时第一(批)消息会拿到空名字，然后被下面的闸拒发。
      loadChatNames()
      const name =
        chatNames.get(chat) ??
        (chat === cfg.chatUser ? cfg.peerName : '') ??
        ''
      // ---- 黑名单 / 白名单 ---------------------------------------------------
      // 白名单 = watched-chats.txt（后台也靠它决定轮询谁），主用户永远在内。
      // 黑名单 = settings.json 的 blockedChats，命中就彻底不回（优先于白名单）。
      {
        const live = eff()
        const blocked = (live.blockedChats ?? []).some(
          (it) => (it.id !== '' && it.id === chat) || (it.name !== '' && it.name === name),
        )
        if (blocked) {
          log(`skip ${chat}: blacklisted`)
          return
        }
        const allowed = new Set([cfg.chatUser, ...readChatList(cfg).map((it) => it.id)])
        if (!allowed.has(chat)) {
          log(`skip ${chat}: not in whitelist (${allowed.size - 1} extra chats watched)`)
          return
        }
      }
      // ---- 命令层：/new 最先处理（不受冷却、也不受 describe 影响） ----------
      // 以前它排在 describe 和 20 秒冷却之后，刚聊过一句再发 /new 会被直接跳过，
      // 表现就是"发了 /new 没反应、也没有新会话"。
      const rawText = String(msg?.text ?? '').trim()
      if (/^[/／]\s*(new|新会话|新对话)\s*$/i.test(rawText)) {
        const gen = bumpGen(chat)
        log(`rotate ${chat}: /new -> generation ${gen}`)
        loadChatNames()
        const rotateName = chatNames.get(chat) ?? (chat === cfg.chatUser ? cfg.peerName : '')
        if (rotateName === '') {
          warn(`rotate ${chat}: no display name; cannot reply about rotation`)
        } else {
          try {
            await runSend(`好，新会话开好了（#${gen}）。再发一句就接上。`, rotateName, group, String(chat))
            log(`rotate ${chat}: replied about generation ${gen}`)
          } catch (error) {
            warn(`rotate reply failed: ${String(error)}`)
          }
        }
        return
      }
      // ---- /doctor：装不上、发不出的时候先跑这个 ------------------------------
      if (/^[/／]\s*(doctor|自检|体检)\s*$/i.test(rawText)) {
        loadChatNames()
        const doctorName = chatNames.get(chat) ?? (chat === cfg.chatUser ? cfg.peerName : '')
        const result = selfCheck(cfg)
        log(`doctor: ${result.ok ? 'all green' : formatSelfCheck(result).replace(/\n/g, ' | ')}`)
        if (doctorName === '') {
          warn('doctor: no display name; cannot reply')
          return
        }
        try {
          await runSend(formatSelfCheck(result), doctorName, group, String(chat))
        } catch (error) {
          warn(`doctor reply failed: ${String(error)}`)
        }
        return
      }
      const body = await describe(msg)
      // ---- send-mode switch (/mode a|b) ------------------------------------
      // A = virtual desktop + helper, B = the current main-desktop automation.
      // B is the always-working default: if A's helper is missing or fails, the
      // send layer falls back to B instead of dropping the reply.
      const modeHit = /^[/／]\s*(mode|模式)\s*(a|b|A|B)?\s*$/i.exec(body.trim())
      if (modeHit) {
        const want = String(modeHit[2] ?? '').toLowerCase()
        loadChatNames()
        const modeName = chatNames.get(chat) ?? (chat === cfg.chatUser ? cfg.peerName : '')
        let answer
        if (want === 'a' || want === 'b') {
          sendMode = want
          saveMode()
          answer = want === 'a'
            ? '发送方式已切到 A（虚拟桌面）。A 的助手动不了会自动退回 B，不会丢消息。'
            : '发送方式已切回 B（当前这套主桌面方案）。'
        } else {
          answer = `现在用 ${sendMode.toUpperCase()} 方案（A=虚拟桌面，B=主桌面）。用 /mode a 或 /mode b 切换。`
        }
        log(`send mode -> ${sendMode}`)
        if (modeName !== '') {
          try {
            await runSend(answer, modeName, group, String(chat))
          } catch (error) {
            warn(`mode reply failed: ${String(error)}`)
          }
        }
        return
      }
      const now = Date.now()
      // ---- backlog guard ---------------------------------------------------
      // The watcher only reports rows it has not seen, but a login after hours
      // offline (or a restarted client) can flush a queue of very old messages.
      // Answering a four-day-old "早" in the evening looks broken, so stay quiet.
      const msgEpoch = Number(msg?.time ?? 0)
      const live = eff()
      if (live.staleSkipSeconds > 0 && Number.isFinite(msgEpoch) && msgEpoch > 0) {
        const ageSec = Math.round(now / 1000 - msgEpoch)
        if (ageSec > live.staleSkipSeconds) {
          log(
            `skip ${chat}: stale message (${Math.round(ageSec / 60)} min old > ` +
              `${Math.round(live.staleSkipSeconds / 60)} min)`,
          )
          return
        }
      }
      const since = now - (lastReplyAt.get(chat) ?? 0)
      const cooldown = group ? 0 : live.directCooldownMs
      if (since < cooldown) {
        log(`skip ${chat}: cooldown ${Math.round(since / 1000)}s < ${Math.round(cooldown / 1000)}s`)
        return
      }
      if (group) {
        // Groups: answer ONLY when the message actually mentions us. No type
        // filter, no cooldown, no daily cap - a real @ mention is rare enough.
        const triggered = (live.groupTriggers ?? ['@']).some((t) => t !== '' && body.includes(t))
        if (!triggered) {
          log(`skip ${chat}: group message without @ mention`)
          return
        }
      }
      lastReplyAt.set(chat, now)
      loadChatNames()
      const when = msg?.time_str ?? stamp()
      const where = group ? `群聊 ${name || chat} · 发言人 ${msg?.sender ?? '?'}` : name || cfg.peerName
      const prompt = [cfg.remotePrefix, `[电脑微信 · ${where} · ${when}] ${body}`].join('\n')
      log(`inbound ${when} [${chat}]: ${body.slice(0, 60)}`)
      let reply
      try {
        reply = await bridge.deliver({
          conversationId: convIdFor(chat),
          accountId: 'desktop',
          text: prompt,
        })
      } catch (error) {
        warn(`deliver failed: ${String(error)}`)
        if (isOverflowError(error) && now - (rotatedAt.get(chat) ?? 0) > 10 * 60_000) {
          rotatedAt.set(chat, now)
          let handoff = ''
          try {
            handoff = await writeHandoff(chat, name, String(error).slice(0, 200))
            log(`handoff written: ${handoff}`)
          } catch (e) {
            warn(`handoff failed: ${String(e)}`)
          }
          const gen = bumpGen(chat)
          log(`overflow rotate ${chat} -> generation ${gen}`)
          if (name !== '') {
            try {
              await runSend(
                `这个对话塞满了（上下文超了模型窗口），我换了个新会话再接着说。你再发一句就接上。${handoff ? `交接写在这里：${handoff}` : ''}`,
                name,
                group,
                String(chat),
              )
            } catch (e) {
              warn(`overflow notice failed: ${String(e)}`)
            }
          }
        }
        return
      }
      const text = String(reply?.text ?? '').trim()
      if (text === '') {
        warn('agent returned an empty reply; nothing sent')
        return
      }
      if (cfg.autoSend !== true) {
        log('autoSend off; reply stays in the session')
        return
      }
      const trimmed = text.length > cfg.maxReplyChars ? `${text.slice(0, cfg.maxReplyChars)}…` : text
      if (name === '') {
        warn(`no display name for ${chat}; refusing to type into whatever chat is open`)
        return
      }
      // No separate "open chat" step here on purpose. Switching the conversation
      // and checking that the right one is open both live inside wx_send.ps1
      // (-ExpectChat -> wx_find_chat.ps1 -> header OCR). Doing it here as well
      // meant two places could decide whether a reply is deliverable, and in
      // plan A the main-desktop copy failed every time and silently dropped the
      // reply (2026-10-30 22:16). One owner: the sender.
      try {
        const out = await runSend(trimmed, name, String(chat).endsWith('@chatroom'), String(chat))
        log(`sent ${trimmed.length} chars -> ${chat} (${out})`)
      } catch (error) {
        warn(`send failed: ${String(error)}`)
      }
    }

    /**
     * Type a reply into WeChat.
     *
     * The text travels as a UTF-8 temp file instead of stdin or an argument:
     * Windows PowerShell 5.1 reads redirected stdin with the ANSI code page, so
     * Chinese came through as mojibake, and long/multiline text is unsafe on a
     * command line. `-TextFile` with `-Encoding UTF8` is deterministic.
     */
    /**
     * Send mode: 'b' (default, main-desktop automation) or 'a' (virtual desktop
     * helper). Persisted so a restart keeps whatever the operator chose. A is
     * allowed to fail - the send path must fall back to B rather than drop a
     * reply, see /mode in the command block.
     */
    let panel = null
    const modeFile = join(cfg.cwd ?? tmpdir(), '..', 'wcdb', 'wx-mode.json')
    let sendMode = String(cfg.mode ?? 'b').toLowerCase() === 'a' ? 'a' : 'b'
    try {
      if (existsSync(modeFile)) {
        const saved = JSON.parse(readFileSync(modeFile, 'utf8'))
        if (String(saved?.mode ?? '').toLowerCase() === 'a') sendMode = 'a'
      }
    } catch (error) {
      warn(`wx-mode.json unreadable (${String(error)}); staying on mode B`)
    }
    const saveMode = () => {
      writeFile(modeFile, JSON.stringify({ mode: sendMode, at: new Date().toISOString() }, null, 2), 'utf8')
        .catch((error) => warn(`wx-mode.json write failed: ${String(error)}`))
    }

    /**
     * Session rotation state: chat -> generation. Generation 0 keeps the
     * original conversation id (`desktop:<chat>`), so nothing changes until the
     * first /new or the first overflow.
     */
    const genFile = join(cfg.cwd ?? tmpdir(), '..', 'wcdb', 'chat-gen.json')
    let chatGen = {}
    try {
      if (existsSync(genFile)) chatGen = JSON.parse(readFileSync(genFile, 'utf8')) ?? {}
    } catch (error) {
      warn(`chat-gen.json unreadable (${String(error)}); starting from 0`)
      chatGen = {}
    }
    const saveGen = () => {
      writeFile(genFile, JSON.stringify(chatGen, null, 2), 'utf8').catch((error) =>
        warn(`chat-gen.json write failed: ${String(error)}`))
    }
    const convIdFor = (chat) => {
      const gen = Number(chatGen[chat] ?? 0)
      return gen > 0 ? `${cfg.conversationPrefix}${chat}#${gen}` : `${cfg.conversationPrefix}${chat}`
    }
    const bumpGen = (chat) => {
      const gen = Number(chatGen[chat] ?? 0) + 1
      chatGen[chat] = gen
      saveGen()
      return gen
    }
    /** Mechanical handoff: no model call, costs no tokens. */
    const writeHandoff = async (chat, name, reason) => {
      const handoffDir = join(cfg.cwd ?? tmpdir(), 'KB', 'HANDOFF')
      const stampText = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 15)
      const file = join(handoffDir, `${stampText}-${chat.replace(/[^a-zA-Z0-9]+/g, '-')}.md`)
      const pick = (path, kind) => {
        try {
          if (!existsSync(path)) return []
          return readFileSync(path, 'utf8')
            .split(/\r?\n/)
            .filter((line) => line.trim() !== '')
            .map((line) => { try { return JSON.parse(line) } catch { return null } })
            .filter((row) => row && (row.chat === chat || String(row.sender ?? '') === chat || kind === undefined))
            .slice(-20)
        } catch { return [] }
      }
      const inbox = pick(cfg.inboxPath, 'msg')
      const acted = pick(join(cfg.cwd ?? '', '..', 'wcdb', 'activity.jsonl'), 'act')
      const body = [
        `# 交接：${name || chat}`,
        '',
        '## 身份与通道',
        `- chat = \`${chat}\`（${String(chat).endsWith('@chatroom') ? '群聊' : '私聊'}），显示名 = ${name || '(未知)'}`,
        `- 触发原因：${reason}`,
        `- 轮换到新会话：generation ${Number(chatGen[chat] ?? 0)}`,
        '',
        '## 最近收发（inbox 末 20 条）',
        ...(inbox.length ? inbox.map((r) => `- ${r.time_str ?? ''} ${r.is_self ? '我' : '对方'}：${String(r.text ?? '').slice(0, 120)}`) : ['- (无)']),
        '',
        '## 当天动作（activity 末 20 条）',
        ...(acted.length ? acted.map((r) => `- ${r.ts ?? ''} [${r.kind ?? ''}] ${String(r.text ?? '').slice(0, 120)}`) : ['- (无)']),
        '',
        '## 下一步',
        '- 新会话先读 `KB\\00-INDEX.md` 与 `KB\\HANDOFF\\` 下最新文件，再回这条消息。',
        '',
      ].join('\n')
      await mkdirHandoff(handoffDir)
      await writeFile(file, body, 'utf8')
      return file
    }
    const mkdirHandoff = async (dir) => {
      try {
        const { mkdir } = await import('node:fs/promises')
        await mkdir(dir, { recursive: true })
      } catch (error) {
        warn(`handoff dir create failed: ${String(error)}`)
      }
    }
    /** Overflow: session context exceeded the model window (502 preflight). */
    const isOverflowError = (error) =>
      /preflight_compress_failed|exceeds the model window/i.test(String(error))
    const rotatedAt = new Map()

    const PS_FLAGS = ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass']

    /** Run one PowerShell script and resolve with its trimmed stdout. */
    const runPs = (args) =>
      new Promise((resolvePromise, reject) => {
        const child = spawn(cfg.powershellPath, args, { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true })
        let out = ''
        let err = ''
        child.stdout.setEncoding('utf8')
        child.stderr.setEncoding('utf8')
        child.stdout.on('data', (chunk) => { out += chunk })
        child.stderr.on('data', (chunk) => { err += chunk })
        child.on('error', reject)
        child.on('close', (code) => {
          if (code === 0) resolvePromise(out.trim())
          else reject(new Error(`exit ${code}: ${err.trim().slice(0, 300)}`))
        })
      })

    /**
     * Send one reply. Switching the conversation and verifying that the right
     * one is open both happen inside wx_send.ps1 (-ExpectChat), so this only
     * picks the transport:
     *   A = helper on the virtual desktop (woken on demand, exits after 15 idle
     *       minutes); if it cannot deliver we fall back to B and log it
     *   B = the plain main-desktop click path
     */
    const runSend = async (text, expectChat = '', isGroup = false, chatId = '') => {
      const file = join(tmpdir(), `wx-desktop-${process.pid}-${Date.now()}.txt`)
      await writeFile(file, text, 'utf8')
      const verify = chatId === '' ? [] : ['-VerifyChat', chatId]
      if (sendMode === 'a' && expectChat !== '') {
        try {
          const out = await runPs([
            ...PS_FLAGS,
            '-File', cfg.vdeskClientScript,
            '-Action', 'send',
            '-Chat', expectChat,
            '-TextFile', file,
            ...verify,
          ])
          await unlink(file).catch(() => {})
          return out
        } catch (error) {
          log(`plan A failed (${error.message}); falling back to plan B`)
        }
      }
      try {
                // 2026-10-31: plan B goes through wx_say.ps1 - it never clicks the chat
        // list and never types into a search box: look at the open chat, switch
        // once only if needed, clear the input box, paste, wait 500 ms, Enter.
        return await runPs([
          ...PS_FLAGS,
          '-File', cfg.sayScript,
          '-Chat', expectChat === '' ? cfg.peerName : expectChat,
          '-TextFile', file,
          ...(expectChat === '' || isGroup ? [] : ['-NotContains', '、']),
        ])
      } finally {
        await unlink(file).catch(() => {})
      }
    }

    const ready = (async () => {
      if (!existsSync(bridgePath)) {
        throw new Error(
          `agent bridge not found: ${bridgePath}. Install the dependency once with ` +
            `\`dsh plugin --profile web add dsh-plugin-weixin\`, or point \`bridgePath\` at ` +
            `its src/agent-bridge.js in the plugin config.`,
        )
      }
      const mod = await import(pathToFileURL(bridgePath).href)
      if (typeof mod.AgentBridge !== 'function') throw new Error(`${bridgePath} does not export AgentBridge`)
      bridge = new mod.AgentBridge({ ctx, cwd: cfg.cwd, log, errLog: warn })
      log(`bridge ready (cwd=${cfg.cwd}, conversation=${cfg.conversationId})`)
      // Surface a broken install immediately instead of failing quietly later.
      try {
        const check = selfCheck(cfg)
        for (const row of check.report) {
          if (!row.ok) warn(`self-check: ${row.item} — ${row.detail}（发 /doctor 可复查）`)
        }
        if (check.ok) log('self-check: all green')
      } catch (error) {
        warn(`self-check crashed: ${String(error)}`)
      }
      startWatcher()
      // Local control panel (opt-in: panelPort > 0).
      if (Number(cfg.panelPort) > 0) {
        try {
          panel = startPanel({
            cfg,
            log,
            warn,
            check: () => selfCheck(cfg),
            format: formatSelfCheck,
            mode: {
              get: () => sendMode,
              set: (want) => {
                sendMode = want === 'a' ? 'a' : 'b'
                saveMode()
              },
            },
            settings: {
              get: () => readSettings(cfg),
              update: (patch) => {
                const next = { ...readSettings(cfg), ...sanitizePatch(patch) }
                writeSettings(cfg, next)
                return next
              },
            },
            chats: {
              list: () => readChatList(cfg),
              add: (id, chatName) => {
                const rows = readChatList(cfg)
                if (!rows.some((it) => it.id === id)) rows.push({ id, name: chatName })
                writeChatList(cfg, rows)
                return rows
              },
              remove: (id) => {
                const rows = readChatList(cfg).filter((it) => it.id !== id)
                writeChatList(cfg, rows)
                return rows
              },
            },
            runPs,
            sendSticker: async (index) => {
              const script = join(cfg.wcdbDir, 'wx_sticker.ps1')
              if (!existsSync(script)) throw new Error(`missing ${script}`)
              log(`panel: send sticker #${index}`)
              try {
                const out = await runPs(['-File', script, '-Index', String(index)])
                log(`panel: sticker #${index} -> ${out.split('\n').filter(Boolean).slice(-1)[0] ?? 'ok'}`)
                return `已发送 #${index}`
              } catch (error) {
                warn(`panel: sticker #${index} failed: ${String(error)}`)
                throw error
              }
            },
          })
        } catch (error) {
          warn(`panel: start failed: ${String(error)}`)
        }
      }
    })()
    // Attach the handler here, not in the disposer: DSH treats an unhandled
    // rejection as fatal, and the disposer may never run.
    ready.catch((error) => warn(`startup failed: ${String(error)}`))

    return () => {
      cancelled = true
      if (retryTimer !== undefined) clearTimeout(retryTimer)
      removeWatcher()
    }
  }

  try {
    ctx.effect(install)
  } catch (error) {
    warn(`install failed: ${String(error)}`)
  }
}
