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
 */
import { createServer } from 'node:http'
import { existsSync, readFileSync } from 'node:fs'
import { extname, join } from 'node:path'

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
for (const b of document.querySelectorAll('[data-mode]')) b.onclick = async () => {
  try { await api('/api/mode', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ mode: b.dataset.mode }) }); toast('已切到 ' + b.dataset.mode.toUpperCase()); refresh() }
  catch (error) { toast('切换失败：' + error.message) }
}
$('refresh').onclick = refresh
refresh(); loadStickers(); setInterval(refresh, 4000)
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
            ['冷却(私聊)', `${Math.round((cfg.directCooldownMs ?? 0) / 1000)} 秒`],
            ['时间闸', `${Math.round((cfg.staleSkipSeconds ?? 0) / 3600)} 小时`],
            ['积压合批', `${cfg.backlogHoldSeconds}s / ${cfg.backlogAgeSeconds}s`],
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
