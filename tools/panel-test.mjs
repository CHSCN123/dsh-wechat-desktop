import { DEFAULTS, resolveConfig, selfCheck, formatSelfCheck } from 'file:///E:/DSH/dsh-wx-desktop/index.js'
import { startPanel } from 'file:///E:/DSH/dsh-wx-desktop/panel.js'

const cfg = resolveConfig({
  ...DEFAULTS,
  dataDir: 'C:\\Users\\LX\\.dsh\\weixin',
  pythonPath: 'C:\\Users\\LX\\.dsh\\weixin\\asr-venv\\Scripts\\python.exe',
  nodePath: 'C:\\Users\\LX\\cmd ai\\node.exe',
  dbDir: 'D:\\LeStoreDownload\\xwechat_files\\wxid_kn207qgkufhp29_5794\\db_storage',
  chatUser: 'wxid_hmqh1bam6y3422',
  peerName: '猪葛凉',
  panelPort: 47189,
})

let mode = 'b'
const lines = []
const server = startPanel({
  cfg,
  log: (l) => { lines.push(l); console.log('LOG', l) },
  warn: (l) => { lines.push(l); console.log('WARN', l) },
  check: () => selfCheck(cfg),
  format: formatSelfCheck,
  mode: { get: () => mode, set: (m) => { mode = m } },
  runPs: async () => 'stub',
  sendSticker: async (i) => `已发送 #${i}`,
})

const base = 'http://127.0.0.1:47189'
const wait = (ms) => new Promise((r) => setTimeout(r, ms))
await wait(300)

const status = await (await fetch(base + '/api/status')).json()
console.log('mode =', status.mode, '| healthy =', status.healthy)
console.log('rows =', status.rows.length, '| checkText =', status.checkText.split('\n')[0])

const page = await (await fetch(base + '/')).text()
console.log('page bytes =', page.length, '| has grid =', page.includes('id="stickers"'))

const stickers = await (await fetch(base + '/api/stickers')).json()
console.log('stickers =', stickers.items.length, '| first =', JSON.stringify(stickers.items[0]))

const img = await fetch(base + '/api/sticker/8')
console.log('sticker/8 =', img.status, img.headers.get('content-type'), (await img.arrayBuffer()).byteLength, 'bytes')

const log = await (await fetch(base + '/api/log?n=5')).json()
console.log('log lines =', log.text.split('\n').length)

const setMode = await fetch(base + '/api/mode', {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify({ mode: 'a' }),
})
console.log('POST /api/mode =', setMode.status, '| mode now =', mode)

const send = await fetch(base + '/api/sticker', {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify({ index: 8 }),
})
console.log('POST /api/sticker =', send.status, await send.text())

server.close()
console.log('closed')
