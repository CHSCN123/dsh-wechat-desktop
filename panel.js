/**
 * Local control panel for dsh-wx-desktop.
 *
 * Deliberately a plain `node:http` server with an inline page: no build step, no
 * client-plugin API churn, works the same on any DSH version. It binds to
 * 127.0.0.1 only; set `panelToken` if you also forward the port.
 *
 * Routes
 *   GET  /                 dashboard
 *   GET  /api/status       mode, config summary, self-check, queue, watcher
 *   POST /api/mode         { mode: 'a' | 'b' }
 *   GET  /api/log?n=200    tail of plugin.log
 *   GET  /api/stickers     favourite sticker index
 *   GET  /api/sticker/:i   one sticker PNG
 *   POST /api/sticker      { index } -> send it (async, result shows up in the log)
 *   GET  /api/settings     editable settings + whitelist
 *   POST /api/settings     patch numbers / triggers (writes <wcdb>/settings.json)
 *   POST /api/chats        { op: 'add' | 'remove', id, name } -> watch list
 *   POST /api/blacklist    { op: 'add' | 'remove', id, name } -> blockedChats
 *   GET  /api/persona      the workspace AGENTS.md (人设提示词)
 *   POST /api/persona      { text } -> rewrite it (old copy kept as .bak-panel-*)
 */
import { createServer } from 'node:http'
import { copyFileSync, existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { dirname, extname, join } from 'node:path'
import { DEFAULTS as SETTINGS_DEFAULTS } from './settings.js'

const PAGE = `<!doctype html>
<html lang="zh"><head><meta charset="utf-8">
<title>微信桌面桥</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
:root{color-scheme:dark}
body{margin:0;font:14px/1.5 system-ui,"Microsoft YaHei",sans-serif;background:#14161a;color:#e6e6e6}
header{padding:16px 20px;background:#1b1e24;border-bottom:1px solid #2a2f38;display:flex;gap:12px;align-items:center;flex-wrap:wrap}
h1{font-size:16px;margin:0;font-weight:600}
.pill{padding:2px 10px;border-radius:999px;background:#262b33;font-size:12px}
.pill.ok{background:#1d3a2a;color:#7fe0a4}.pill.bad{background:#3d1f22;color:#ff9b9b}
main{padding:20px;display:grid;gap:18px;grid-template-columns:repeat(auto-fit,minmax(340px,1fr))}
section{background:#1b1e24;border:1px solid #2a2f38;border-radius:12px;padding:14px}
section h2{font-size:13px;margin:0 0 10px;color:#9aa4b2;text-transform:uppercase;letter-spacing:.06em}
button{background:#2b3240;color:#e6e6e6;border:1px solid #3a4353;border-radius:8px;padding:6px 12px;cursor:pointer;font:inherit}
button:hover{background:#354052}button.on{background:#2c5ea8;border-color:#3f7ad0}
pre{margin:0;max-height:320px;overflow:auto;font:12px/1.5 ui-monospace,Consolas,monospace;white-space:pre-wrap;word-break:break-all}
table{border-collapse:collapse;width:100%;font-size:13px}td{padding:3px 6px;border-bottom:1px solid #232830;vertical-align:top}
td:first-child{color:#9aa4b2;width:38%;white-space:nowrap}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(76px,1fr));gap:8px;max-height:340px;overflow:auto}
.grid figure{margin:0;text-align:center;cursor:pointer}
.grid img{width:70px;height:70px;object-fit:contain;background:#0f1115;border:1px solid #262b33;border-radius:8px}
.grid figcaption{font-size:10px;color:#8b94a3;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
#toast{position:fixed;right:16px;bottom:16px;background:#2c5ea8;padding:8px 14px;border-radius:8px;opacity:0;transition:.2s}
.form{display:grid;gap:8px}
.form label{display:flex;gap:6px;align-items:center;flex-wrap:wrap;color:#c9d1dc}
.form input{background:#0f1115;color:#e6e6e6;border:1px solid #333b48;border-radius:6px;padding:4px 8px;font:inherit;width:90px}
.form input[type=text]{width:auto}
table.list td:last-child{text-align:right;width:70px}
table.list{border-collapse:collapse;width:100%}
table.list td{border-bottom:1px solid #232830;padding:4px 6px;font-size:13px}
table.list td small{color:#8b94a3}
.hint{color:#8b94a3;font-size:12px;margin:4px 0}
textarea{width:100%;height:380px;background:#0f1115;color:#dfe6ef;border:1px solid #333b48;border-radius:8px;padding:10px;font:12.5px/1.6 ui-monospace,Consolas,"Microsoft YaHei",monospace;resize:vertical}
</style></head><body>
<header><h1>微信桌面桥</h1><span class="pill" id="mode">…</span><span class="pill" id="health">…</span>
<span class="pill" id="who">…</span><button id="refresh">刷新</button></header>
<main>
  <section><h2>发送方案</h2>
    <div style="display:flex;gap:8px;margin-bottom:10px">
      <button data-mode="a">A · 虚拟桌面</button><button data-mode="b">B · 主桌面</button>
    </div>
    <table id="cfg"></table>
  </section>
  <section><h2>参数（改完立即生效）</h2>
    <div class="form">
      <label>私聊冷却 <input id="s-direct" type="number" min="0" step="1"> 秒</label>
      <label>群聊冷却 <input id="s-groupcd" type="number" min="0" step="1"> 秒</label>
      <label>时间闸 <input id="s-stale" type="number" min="0" step="1"> 小时（更旧的手机积压消息不回）</label>
      <label>积压合批 <input id="s-hold" type="number" min="0" step="1"> 秒 / 只收 <input id="s-age" type="number" min="0" step="1"> 秒以前的消息</label>
      <label>轮询间隔 <input id="s-interval" type="number" min="0.5" step="0.5"> 秒（重启插件生效）</label>
      <label>群触发词 <input id="s-triggers" type="text" style="width:100%"> （逗号分隔，默认 @）</label>
      <div><button id="save-settings">保存参数</button></div>
    </div>
  </section>
  <section><h2>白名单（监控并回复）</h2>
    <table id="chats"></table>
    <div class="form" style="margin-top:10px">
      <label>wxid / 群号 <input id="chat-id" type="text" style="width:100%"></label>
      <label>显示名 <input id="chat-name" type="text" style="width:100%"></label>
      <div><button id="add-chat">加入白名单</button></div>
    </div>
  </section>
  <section><h2>黑名单（永不回复）</h2>
    <table id="blocked"></table>
    <div class="form" style="margin-top:10px">
      <label>wxid / 群号 <input id="blk-id" type="text" style="width:100%"></label>
      <label>显示名 <input id="blk-name" type="text" style="width:100%"></label>
      <div><button id="add-blocked">加入黑名单</button></div>
    </div>
  </section>
  <section style="grid-column:1/-1"><h2>人设提示词（AGENTS.md）</h2>
    <div class="hint" id="persona-path">…</div>
    <textarea id="persona" spellcheck="false"></textarea>
    <div style="display:flex;gap:8px;align-items:center;margin-top:8px;flex-wrap:wrap">
      <button id="save-persona">保存</button>
      <button id="reload-persona">放弃改动、重新读取</button>
      <span class="hint" id="persona-meta"></span>
    </div>
    <div class="hint">保存下一轮生效，不用重启。改坏了可以从同目录的 AGENTS.md.bak-panel-* 恢复。</div>
  </section>
  <section><h2>自检</h2><pre id="check">…</pre></section>
  <section><h2>日志（尾部）</h2><pre id="log">…</pre></section>
  <section><h2>收藏表情（点一下发送）</h2><div class="grid" id="stickers"></div></section>
</main>
<div id="toast"></div>
<script>
const $ = (id) => document.getElementById(id)
const toast = (msg) => { const t = $('toast'); t.textContent = msg; t.style.opacity = 1; setTimeout(() => t.style.opacity = 0, 1800) }
async function api(path, opts) {
  const res = await fetch(path, opts)
  if (!res.ok) throw new Error(res.status + ' ' + (await res.text()).slice(0, 200))
  return res.json()
}
async function refresh() {
  try {
    const s = await api('/api/status')
    $('mode').textContent = '方案 ' + s.mode.toUpperCase()
    $('health').textContent = s.healthy ? '链路正常' : '有问题'
    $('health').className = 'pill ' + (s.healthy ? 'ok' : 'bad')
    $('who').textContent = s.peerName + ' · ' + s.chatUser
    $('cfg').innerHTML = s.rows.map(([k, v]) => '<tr><td>' + k + '</td><td>' + String(v).replace(/</g, '&lt;') + '</td></tr>').join('')
    $('check').textContent = s.checkText
    $('log').textContent = (await api('/api/log?n=120')).text
    for (const b of document.querySelectorAll('[data-mode]')) b.classList.toggle('on', b.dataset.mode === s.mode)
  } catch (error) { $('health').textContent = '面板连不上'; $('health').className = 'pill bad' }
}
async function loadStickers() {
  try {
    const data = await api('/api/stickers')
    $('stickers').innerHTML = data.items.map((it) =>
      '<figure data-i="' + it.i + '" title="' + (it.desc || '') + '"><img loading="lazy" src="/api/sticker/' + it.i + '"><figcaption>#' + it.i + ' ' + (it.text || '') + '</figcaption></figure>'
    ).join('')
    for (const fig of document.querySelectorAll('.grid figure')) fig.onclick = () => sendSticker(fig.dataset.i)
  } catch (error) { $('stickers').textContent = '没有表情索引' }
}
async function sendSticker(index) {
  toast('发送 #' + index + ' …')
  try { const r = await api('/api/sticker', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ index: Number(index) }) }); toast(r.message) }
  catch (error) { toast('失败：' + error.message) }
  setTimeout(refresh, 1200)
}
function esc(v) {
  return String(v == null ? '' : v).replace(/[<>&"]/g, function (c) {
    return { '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;' }[c]
  })
}
function renderList(tableId, rows, kind) {
  const el = $(tableId)
  el.innerHTML = rows.length === 0
    ? '<tr><td>（空）</td><td></td></tr>'
    : rows.map(function (r) {
        return '<tr><td>' + esc(r.name || '(未命名)') + '<br><small>' + esc(r.id) + '</small></td>' +
          '<td><button data-del="' + esc(r.id) + '" data-kind="' + kind + '">删除</button></td></tr>'
      }).join('')
  for (const b of el.querySelectorAll('[data-del]')) {
    b.onclick = function () { removeEntry(b.dataset.kind, b.dataset.del) }
  }
}
async function loadSettings() {
  try {
    const d = await api('/api/settings')
    const s = d.settings
    $('s-direct').value = s.directCooldownSeconds
    $('s-groupcd').value = s.groupCooldownSeconds
    $('s-stale').value = Math.round((s.staleSkipSeconds / 3600) * 100) / 100
    $('s-hold').value = s.backlogHoldSeconds
    $('s-age').value = s.backlogAgeSeconds
    $('s-interval').value = s.intervalSeconds
    $('s-triggers').value = (s.groupTriggers || []).join(',')
    renderList('chats', d.chats || [], 'chats')
    renderList('blocked', s.blockedChats || [], 'blocked')
  } catch (error) { toast('读取设置失败：' + error.message) }
}
async function removeEntry(kind, id) {
  const path = kind === 'blocked' ? '/api/blacklist' : '/api/chats'
  try {
    await api(path, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ op: 'remove', id: id }) })
    toast('已移除')
    loadSettings()
  } catch (error) { toast('移除失败：' + error.message) }
}
$('save-settings').onclick = async function () {
  const patch = {
    directCooldownSeconds: Number($('s-direct').value),
    groupCooldownSeconds: Number($('s-groupcd').value),
    staleSkipSeconds: Math.round(Number($('s-stale').value) * 3600),
    backlogHoldSeconds: Number($('s-hold').value),
    backlogAgeSeconds: Number($('s-age').value),
    intervalSeconds: Number($('s-interval').value),
    groupTriggers: $('s-triggers').value.split(',').map(function (x) { return x.trim() }).filter(Boolean),
  }
  try {
    await api('/api/settings', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(patch) })
    toast('参数已保存')
    loadSettings(); refresh()
  } catch (error) { toast('保存失败：' + error.message) }
}
async function addEntry(kind) {
  const id = kind === 'blocked' ? $('blk-id').value.trim() : $('chat-id').value.trim()
  const name = kind === 'blocked' ? $('blk-name').value.trim() : $('chat-name').value.trim()
  if (!id && !name) { toast('至少填一个'); return }
  const path = kind === 'blocked' ? '/api/blacklist' : '/api/chats'
  try {
    await api(path, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ op: 'add', id: id, name: name }) })
    toast('已加入')
    if (kind === 'blocked') { $('blk-id').value = ''; $('blk-name').value = '' } else { $('chat-id').value = ''; $('chat-name').value = '' }
    loadSettings()
  } catch (error) { toast('加入失败：' + error.message) }
}
$('add-chat').onclick = function () { addEntry('chats') }
$('add-blocked').onclick = function () { addEntry('blocked') }
async function loadPersona() {
  try {
    const d = await api('/api/persona')
    $('persona').value = d.text
    $('persona-path').textContent = d.path + (d.exists ? '' : '（文件还不存在，保存会新建）')
    $('persona-meta').textContent = d.text.length + ' 字符 / ' + d.bytes + ' 字节，改动于 ' + (d.mtime || '—')
  } catch (error) { $('persona-path').textContent = '读不到人设文件：' + error.message }
}
$('save-persona').onclick = async function () {
  const text = $('persona').value
  if (text.trim() === '') { toast('不允许保存空文件'); return }
  try {
    const d = await api('/api/persona', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ text: text }) })
    toast('已保存（旧版本：' + (d.backup || '无') + '）')
    loadPersona()
  } catch (error) { toast('保存失败：' + error.message) }
}
$('reload-persona').onclick = function () { toast('已重新读取'); loadPersona() }
for (const b of document.querySelectorAll('[data-mode]')) b.onclick = async () => {
  try { await api('/api/mode', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ mode: b.dataset.mode }) }); toast('已切到 ' + b.dataset.mode.toUpperCase()); refresh() }
  catch (error) { toast('切换失败：' + error.message) }
}
$('refresh').onclick = refresh
refresh(); loadStickers(); loadSettings(); loadPersona(); setInterval(refresh, 4000)
</script></body></html>`

const MIME = { '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.gif': 'image/gif', '.webp': 'image/webp' }

function json(res, code, body) {
  const payload = JSON.stringify(body)
  res.writeHead(code, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' })
  res.end(payload)
}

/** Sticker index lives beside the data dir; missing file just means "no favourites yet". */
function readStickers(cfg) {
  const file = join(cfg.wcdbDir ?? join(cfg.dataDir, 'wcdb'), 'sticker_lab', 'sticker_index.json')
  if (!existsSync(file)) return []
  try {
    const parsed = JSON.parse(readFileSync(file, 'utf8'))
    const items = Array.isArray(parsed) ? parsed : parsed.items
    return Array.isArray(items) ? items.filter((it) => it && it.file && !it.builtin) : []
  } catch {
    return []
  }
}

/**
 * @param {object} options
 * @param {object} options.cfg      resolved plugin config
 * @param {Function} options.log    log(line)
 * @param {Function} options.warn   warn(line)
 * @param {Function} options.check  () => selfCheck(cfg)
 * @param {Function} options.format (result) => string
 * @param {object} options.mode     { get(): string, set(mode): void }
 * @param {Function} options.runPs  run a .ps1 and resolve with its stdout
 * @param {Function} options.sendSticker (index) => Promise<string>
 */
export function startPanel(options) {
  const { cfg, log, warn, check, format, mode, runPs, sendSticker } = options
  // Settings/whitelist are optional so the panel still boots (read-only) if a
  // host wires it without them.
  const settings = options.settings ?? {
    get: () => ({ ...SETTINGS_DEFAULTS }),
    update: () => ({ ...SETTINGS_DEFAULTS }),
  }
  const chats = options.chats ?? {
    list: () => [],
    add: () => [],
    remove: () => [],
  }
  // 工作区人设：<cwd>/AGENTS.md（cwd 默认就是 <dataDir>/sessions）
  const personaFile = () => join(cfg.cwd ?? join(cfg.dataDir, 'sessions'), 'AGENTS.md')
  const stampForFile = () => {
    const d = new Date()
    const p = (n) => String(n).padStart(2, '0')
    return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`
  }
  const token = String(cfg.panelToken ?? '')

  const server = createServer(async (req, res) => {
    const url = new URL(req.url ?? '/', 'http://127.0.0.1')
    if (token !== '' && url.searchParams.get('token') !== token && req.headers['x-panel-token'] !== token) {
      return json(res, 401, { error: 'token required' })
    }
    try {
      if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html')) {
        res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' })
        return res.end(PAGE)
      }
      if (req.method === 'GET' && url.pathname === '/api/status') {
        const result = check()
        const s = settings.get()
        return json(res, 200, {
          mode: mode.get(),
          healthy: result.ok,
          peerName: cfg.peerName ?? '',
          chatUser: cfg.chatUser ?? '',
          checkText: format(result),
          rows: [
            ['数据目录', cfg.dataDir],
            ['脚本目录', cfg.wcdbDir ?? ''],
            ['微信库', cfg.dbDir ?? '(未配置)'],
            ['会话', cfg.conversationId ?? ''],
            ['冷却(私聊)', `${s.directCooldownSeconds} 秒`],
            ['时间闸', `${Math.round((s.staleSkipSeconds / 3600) * 100) / 100} 小时`],
            ['积压合批', `${s.backlogHoldSeconds}s / ${s.backlogAgeSeconds}s`],
            ['轮询间隔', `${s.intervalSeconds} 秒`],
            ['白名单', `${chats.list().length} 个`],
            ['黑名单', `${(s.blockedChats ?? []).length} 个`],
          ],
        })
      }
      if (req.method === 'POST' && url.pathname === '/api/mode') {
        const body = await readJson(req)
        const want = String(body?.mode ?? '').toLowerCase()
        if (want !== 'a' && want !== 'b') return json(res, 400, { error: 'mode must be a or b' })
        mode.set(want)
        log(`panel: send mode -> ${want}`)
        return json(res, 200, { ok: true, mode: want })
      }
      if (req.method === 'GET' && url.pathname === '/api/log') {
        const n = Math.min(Math.max(Number(url.searchParams.get('n') ?? 120), 10), 1000)
        const text = existsSync(cfg.logPath) ? readFileSync(cfg.logPath, 'utf8') : ''
        const lines = text.split(/\r?\n/).filter(Boolean)
        return json(res, 200, { text: lines.slice(-n).join('\n') })
      }
      if (req.method === 'GET' && url.pathname === '/api/stickers') {
        const items = readStickers(cfg).map((it) => ({ i: it.i, text: it.text ?? '', desc: it.desc ?? '', tags: it.tags ?? [] }))
        return json(res, 200, { items })
      }
      if (req.method === 'GET' && url.pathname.startsWith('/api/sticker/')) {
        const index = Number(url.pathname.slice('/api/sticker/'.length))
        const item = readStickers(cfg).find((it) => Number(it.i) === index)
        if (!item) return json(res, 404, { error: 'no such sticker' })
        const file = join(cfg.wcdbDir ?? join(cfg.dataDir, 'wcdb'), 'sticker_lab', 'fav', item.file)
        if (!existsSync(file)) return json(res, 404, { error: 'file missing' })
        const bytes = readFileSync(file)
        res.writeHead(200, { 'content-type': MIME[extname(file).toLowerCase()] ?? 'application/octet-stream', 'cache-control': 'max-age=3600' })
        return res.end(bytes)
      }
      if (req.method === 'POST' && url.pathname === '/api/sticker') {
        const body = await readJson(req)
        const index = Number(body?.index)
        if (!Number.isFinite(index)) return json(res, 400, { error: 'index required' })
        const message = await sendSticker(index)
        return json(res, 200, { ok: true, message })
      }
      if (req.method === 'GET' && url.pathname === '/api/settings') {
        return json(res, 200, { settings: settings.get(), chats: chats.list(), chatUser: cfg.chatUser ?? '' })
      }
      if (req.method === 'POST' && url.pathname === '/api/settings') {
        const body = await readJson(req)
        const next = settings.update(body)
        log(`panel: settings updated -> ${JSON.stringify(next)}`)
        return json(res, 200, { ok: true, settings: next })
      }
      if (req.method === 'POST' && url.pathname === '/api/chats') {
        const body = await readJson(req)
        const id = String(body?.id ?? '').trim()
        const chatName = String(body?.name ?? '').trim()
        const op = String(body?.op ?? 'add')
        if (op === 'add' && id === '' && chatName === '') return json(res, 400, { error: 'id or name required' })
        if (op === 'remove') {
          const rows = chats.remove(String(body?.id ?? ''))
          log(`panel: whitelist - ${body?.id}`)
          return json(res, 200, { ok: true, chats: rows })
        }
        const rows = chats.add(id, chatName)
        log(`panel: whitelist + ${id} (${chatName})`)
        return json(res, 200, { ok: true, chats: rows })
      }
      if (req.method === 'POST' && url.pathname === '/api/blacklist') {
        const body = await readJson(req)
        const current = settings.get()
        const id = String(body?.id ?? '').trim()
        const chatName = String(body?.name ?? '').trim()
        const op = String(body?.op ?? 'add')
        let blocked = Array.isArray(current.blockedChats) ? current.blockedChats.slice() : []
        if (op === 'remove') {
          blocked = blocked.filter((it) => !(id !== '' ? it.id === id : it.name === chatName))
        } else {
          if (id === '' && chatName === '') return json(res, 400, { error: 'id or name required' })
          if (!blocked.some((it) => (id !== '' && it.id === id) || (chatName !== '' && it.name === chatName))) {
            blocked.push({ id, name: chatName })
          }
        }
        const next = settings.update({ blockedChats: blocked })
        log(`panel: blacklist ${op} ${id || chatName} (${blocked.length} total)`)
        return json(res, 200, { ok: true, settings: next })
      }
      if (req.method === 'GET' && url.pathname === '/api/persona') {
        const file = personaFile()
        const exists = existsSync(file)
        const text = exists ? readFileSync(file, 'utf8') : ''
        let mtime = ''
        if (exists) {
          try { mtime = new Date(statSync(file).mtimeMs).toLocaleString('zh-CN') } catch { mtime = '' }
        }
        return json(res, 200, {
          path: file,
          exists,
          text,
          bytes: Buffer.byteLength(text, 'utf8'),
          mtime,
        })
      }
      if (req.method === 'POST' && url.pathname === '/api/persona') {
        const body = await readJson(req)
        const text = String(body?.text ?? '')
        if (text.trim() === '') return json(res, 400, { error: 'empty text' })
        if (Buffer.byteLength(text, 'utf8') > 512 * 1024) return json(res, 400, { error: 'too large (max 512KB)' })
        const file = personaFile()
        let backup = ''
        mkdirSync(dirname(file), { recursive: true })
        if (existsSync(file)) {
          backup = `${file}.bak-panel-${stampForFile()}`
          try { copyFileSync(file, backup) } catch { backup = '' }
        }
        writeFileSync(file, text, 'utf8')
        log(`panel: persona saved (${Buffer.byteLength(text, 'utf8')} bytes)${backup ? `, backup ${backup}` : ''}`)
        return json(res, 200, { ok: true, path: file, backup })
      }
      return json(res, 404, { error: 'not found' })
    } catch (error) {
      warn(`panel: ${String(error)}`)
      return json(res, 500, { error: String(error) })
    }
  })

  const port = Number(cfg.panelPort)
  server.listen(port, '127.0.0.1', () => {
    log(`panel: http://127.0.0.1:${port}${token ? `/?token=${token}` : ''}`)
  })
  server.on('error', (error) => warn(`panel: cannot listen on ${port}: ${String(error)}`))
  return server
}

function readJson(req) {
  return new Promise((resolvePromise, reject) => {
    let raw = ''
    req.setEncoding('utf8')
    req.on('data', (chunk) => {
      raw += chunk
      if (raw.length > 1_000_000) reject(new Error('body too large'))
    })
    req.on('end', () => {
      try {
        resolvePromise(raw === '' ? {} : JSON.parse(raw))
      } catch (error) {
        reject(error)
      }
    })
    req.on('error', reject)
  })
}
