/**
 * Mutable settings for dsh-wx-desktop.
 *
 * The profile's `cordis.patch.yml` is a fine place for paths, but it is an awful
 * place to tune "cooldown = 30 秒" from a web page: it is YAML, it is shared with
 * other plugins, and a broken edit takes the whole profile down. So everything the
 * panel can edit lives in `<wcdb>/settings.json` and is merged on top of the YAML
 * config at use time (no restart needed).
 *
 * watched-chats.txt stays the whitelist: it is the watcher's poll list too, so
 * "allowed to reply" and "actually watched" cannot drift apart.
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'

export const DEFAULTS = {
  /** 私聊冷却，秒 */
  directCooldownSeconds: 20,
  /** 群聊冷却，秒（0 = 不限） */
  groupCooldownSeconds: 300,
  /** 时间闸：超过这么多秒的旧消息不回 */
  staleSkipSeconds: 172_800,
  /** 积压合批：消息年龄超过这么多秒才进压制队列 */
  backlogAgeSeconds: 60,
  /** 压制队列等这么久，后到的顶掉前面的 */
  backlogHoldSeconds: 4,
  /** 轮询间隔，秒 */
  intervalSeconds: 1.5,
  /** 群聊触发词 */
  groupTriggers: ['@'],
  /** 黑名单：永不回复（按 wxid 或显示名） */
  blockedChats: [],
}

const NUMBER_KEYS = [
  'directCooldownSeconds',
  'groupCooldownSeconds',
  'staleSkipSeconds',
  'backlogAgeSeconds',
  'backlogHoldSeconds',
  'intervalSeconds',
]

function clamp(n, lo, hi) {
  return Math.min(Math.max(n, lo), hi)
}

/** Coerce one patch coming from the panel; unknown keys are ignored. */
export function sanitizePatch(patch) {
  const out = {}
  if (!patch || typeof patch !== 'object') return out
  for (const key of NUMBER_KEYS) {
    if (patch[key] === undefined) continue
    const n = Number(patch[key])
    if (!Number.isFinite(n)) continue
    const limits = {
      directCooldownSeconds: [0, 86_400],
      groupCooldownSeconds: [0, 86_400],
      staleSkipSeconds: [0, 2_592_000],
      backlogAgeSeconds: [0, 86_400],
      backlogHoldSeconds: [0, 600],
      intervalSeconds: [0.5, 60],
    }[key]
    out[key] = clamp(n, limits[0], limits[1])
  }
  if (Array.isArray(patch.groupTriggers)) {
    out.groupTriggers = patch.groupTriggers.map((t) => String(t)).filter((t) => t !== '')
  }
  if (Array.isArray(patch.blockedChats)) {
    out.blockedChats = patch.blockedChats
      .map((it) => ({ id: String(it?.id ?? '').trim(), name: String(it?.name ?? '').trim() }))
      .filter((it) => it.id !== '' || it.name !== '')
  }
  return out
}

export function settingsFile(cfg) {
  return cfg.settingsFile ?? join(cfg.wcdbDir ?? join(cfg.dataDir, 'wcdb'), 'settings.json')
}

export function readSettings(cfg) {
  const file = settingsFile(cfg)
  if (!existsSync(file)) return { ...DEFAULTS }
  try {
    const parsed = JSON.parse(readFileSync(file, 'utf8'))
    return { ...DEFAULTS, ...sanitizePatch(parsed) }
  } catch {
    return { ...DEFAULTS }
  }
}

export function writeSettings(cfg, settings) {
  const file = settingsFile(cfg)
  mkdirSync(dirname(file), { recursive: true })
  writeFileSync(file, JSON.stringify(settings, null, 2) + '\n', 'utf8')
  return file
}

/** Apply panel-editable settings on top of a resolved config. */
export function applySettings(cfg, settings) {
  const s = settings ?? readSettings(cfg)
  return {
    ...cfg,
    directCooldownMs: s.directCooldownSeconds * 1000,
    groupCooldownMs: s.groupCooldownSeconds * 1000,
    staleSkipSeconds: s.staleSkipSeconds,
    backlogAgeSeconds: s.backlogAgeSeconds,
    backlogHoldSeconds: s.backlogHoldSeconds,
    intervalSeconds: s.intervalSeconds,
    groupTriggers: s.groupTriggers,
    blockedChats: s.blockedChats,
    settings: s,
  }
}

// ---------------------------------------------------------------- 白名单

export function readChatList(cfg) {
  const file = cfg.chatListFile
  if (!file || !existsSync(file)) return []
  const rows = []
  for (const line of readFileSync(file, 'utf8').split(/\r?\n/)) {
    const trimmed = line.trim()
    if (trimmed === '' || trimmed.startsWith('#')) continue
    const [id, name] = trimmed.split('|')
    if (!id) continue
    rows.push({ id: id.trim(), name: String(name ?? '').trim() })
  }
  return rows
}

export function writeChatList(cfg, rows) {
  const file = cfg.chatListFile
  const header = [
    '# watched chats: one per line, format  wxid|nickname',
    '# 这个文件就是白名单：里面的人/群会被监控并允许回复；没写进来的不回。',
    '# 面板「白名单」里增删即可，本文件可手改。',
  ].join('\n')
  const body = rows.map((r) => `${r.id}|${r.name}`).join('\n')
  mkdirSync(dirname(file), { recursive: true })
  writeFileSync(file, `${header}\n${body}${body ? '\n' : ''}`, 'utf8')
  return file
}
