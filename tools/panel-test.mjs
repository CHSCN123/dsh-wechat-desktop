/**
 * Offline smoke test for the local panel: starts the real HTTP server against a
 * throwaway data dir, then walks every route including the settings / whitelist /
 * blacklist ones. No WeChat, no DSH, no sending.
 *
 *   node tools/panel-test.mjs
 */
import { mkdirSync, mkdtempSync, writeFileSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { DEFAULTS, resolveConfig, selfCheck, formatSelfCheck } from 'file:///E:/DSH/dsh-wx-desktop/index.js'
import { startPanel } from 'file:///E:/DSH/dsh-wx-desktop/panel.js'
import { readChatList, readSettings, sanitizePatch, writeChatList, writeSettings } from 'file:///E:/DSH/dsh-wx-desktop/settings.js'

const dataDir = mkdtempSync(join(tmpdir(), 'wxdesk-panel-'))
const wcdb = join(dataDir, 'wcdb')
const cfg = resolveConfig({
  ...DEFAULTS,
  dataDir,
  pythonPath: process.env.WX_PYTHON ?? 'python',
  nodePath: process.env.WX_NODE ?? 'node',
  dbDir: process.env.WX_DB_DIR ?? 'D:\\WeChat\\wxid_test\\db_storage',
  chatUser: process.env.WX_CHAT_USER ?? 'wxid_test',
  peerName: process.env.WX_PEER_NAME ?? '张三',
  panelPort: 47189,
})

// seed a watched-chats.txt so the whitelist routes have something to edit
writeChatList(cfg, [{ id: 'wxid_test', name: '张三' }])
writeFileSync(join(wcdb, 'plugin.log'), 'seed line\n', 'utf8')

let mode = 'b'
const lines = []
const server = startPanel({
  cfg,
  log: (l) => { lines.push(l); console.log('LOG', l) },
  warn: (l) => { lines.push(l); console.log('WARN', l) },
  check: () => selfCheck(cfg),
  format: formatSelfCheck,
  mode: { get: () => mode, set: (m) => { mode = m } },
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
    add: (id, name) => {
      const rows = readChatList(cfg)
      if (!rows.some((it) => it.id === id)) rows.push({ id, name })
      writeChatList(cfg, rows)
      return rows
    },
    remove: (id) => {
      const rows = readChatList(cfg).filter((it) => it.id !== id)
      writeChatList(cfg, rows)
      return rows
    },
  },
  runPs: async () => 'stub',
  sendSticker: async (i) => `已发送 #${i}`,
})

const base = 'http://127.0.0.1:47189'
const wait = (ms) => new Promise((r) => setTimeout(r, ms))
const post = (path, body) =>
  fetch(base + path, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) })
await wait(300)

const status = await (await fetch(base + '/api/status')).json()
console.log('mode =', status.mode, '| healthy =', status.healthy)
console.log('rows =', status.rows.length, '| whitelist row =', status.rows.find((r) => r[0] === '白名单'))
console.log('checkText first line =', status.checkText.split('\n')[0])
console.log(lines.length, 'log lines so far')

const page = await (await fetch(base + '/')).text()
console.log('page bytes =', page.length, '| has grid =', page.includes('id="stickers"'), '| has save =', page.includes('id="save-settings"'))

const before = await (await fetch(base + '/api/settings')).json()
console.log('settings GET =', JSON.stringify(before.settings), '| chats =', JSON.stringify(before.chats))

const saved = await (await post('/api/settings', {
  directCooldownSeconds: 45,
  staleSkipSeconds: 86_400,
  groupTriggers: ['@肥鱼'],
  intervalSeconds: 2.5,
})).json()
console.log('POST /api/settings =', saved.ok, '| cooldown =', saved.settings.directCooldownSeconds, '| stale =', saved.settings.staleSkipSeconds, '| triggers =', JSON.stringify(saved.settings.groupTriggers))

const clamped = await (await post('/api/settings', { directCooldownSeconds: 999_999, intervalSeconds: 0.01 })).json()
console.log('clamped =', clamped.settings.directCooldownSeconds, clamped.settings.intervalSeconds)

const added = await (await post('/api/chats', { op: 'add', id: '123@chatroom', name: '瓦' })).json()
console.log('whitelist + =', added.chats.map((c) => c.name).join(','))
const removed = await (await post('/api/chats', { op: 'remove', id: '123@chatroom' })).json()
console.log('whitelist - =', removed.chats.map((c) => c.name).join(','))

const blkAdd = await (await post('/api/blacklist', { op: 'add', id: 'spam@chatroom', name: '广告群' })).json()
console.log('blacklist + =', JSON.stringify(blkAdd.settings.blockedChats))
const blkDel = await (await post('/api/blacklist', { op: 'remove', id: 'spam@chatroom' })).json()
console.log('blacklist - =', JSON.stringify(blkDel.settings.blockedChats))

const setMode = await post('/api/mode', { mode: 'a' })
console.log('POST /api/mode =', setMode.status, '| mode now =', mode)

const log = await (await fetch(base + '/api/log?n=5')).json()
console.log('log lines =', log.text.split('\n').length)

const send = await post('/api/sticker', { index: 8 })
console.log('POST /api/sticker =', send.status, await send.text())

// --- persona (workspace AGENTS.md) ---
mkdirSync(cfg.cwd, { recursive: true })
const personaPath = join(cfg.cwd, 'AGENTS.md')
writeFileSync(personaPath, '# 原人设\n\n- 第一条\n', 'utf8')
const p1 = await (await fetch(base + '/api/persona')).json()
console.log('persona GET =', p1.exists, p1.bytes, 'bytes |', p1.path)
const p2 = await (await post('/api/persona', { text: '# 新人设\n\n- 改过了\n' })).json()
console.log('persona POST =', p2.ok, '| backup =', p2.backup.split('\\').pop())
console.log('persona file now =', JSON.stringify(readFileSync(personaPath, 'utf8')))
const p3 = await post('/api/persona', { text: '   ' })
console.log('persona empty rejected =', p3.status)

server.close()
console.log('closed | data dir =', dataDir)
