// sticker_resolve.mjs — turn an inbound WeChat sticker (local_type 47) into
// something the agent can actually look at.
//
// Why this exists: the message_content of a sticker is zstd-compressed XML, and
// the python that ships with the harness has no `compression.zstd`, so watch.py
// hands the plugin mojibake and the agent used to see only
// "[对方发来一个表情]". Node 24 has node:sqlite + zlib.zstdDecompressSync, so we
// re-read the row here, pull the md5 out of the XML, and map it to a downloaded
// PNG (favourites) or an on-demand CDN download (everything else).
//
// Usage:
//   node sticker_resolve.mjs --chat <wxid|chatroom> --local-id 12345
//   node sticker_resolve.mjs --chat wxid_xxx --md5 <md5>
//   node sticker_resolve.mjs --chat wxid_xxx --last 1        # newest sticker in that chat
// Prints one JSON line: {ok, md5, index, file, text, tags, builtin, source, error}
import { DatabaseSync } from 'node:sqlite'
import { createHash } from 'node:crypto'
import zlib from 'node:zlib'
import fs from 'node:fs'
import path from 'node:path'
import https from 'node:https'
import http from 'node:http'

const HERE = path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'))
const DB_DIR = path.join(HERE, 'decrypted')
const MSG_DB = path.join(DB_DIR, 'message', 'message_0.db')
const LAB = path.join(HERE, 'sticker_lab')
const FAV = path.join(LAB, 'fav')
const INCOMING = path.join(LAB, 'incoming')
const INDEX = path.join(LAB, 'sticker_index.json')

const args = {}
for (let i = 2; i < process.argv.length; i += 2) {
  const k = process.argv[i]
  if (!k.startsWith('--')) break
  args[k.slice(2)] = process.argv[i + 1]
}

const emit = (obj) => {
  process.stdout.write(JSON.stringify(obj) + '\n')
}

const tableFor = (chat) => 'Msg_' + createHash('md5').update(String(chat)).digest('hex')

const textOf = (value, ct) => {
  if (value === null || value === undefined) return ''
  if (typeof value === 'string') return value
  const buf = Buffer.from(value)
  if (ct === 4) {
    try {
      return zlib.zstdDecompressSync(buf).toString('utf8')
    } catch {
      /* fall through */
    }
  }
  return buf.toString('utf8')
}

const loadIndex = () => {
  try {
    const doc = JSON.parse(fs.readFileSync(INDEX, 'utf8'))
    const byMd5 = new Map()
    for (const item of doc.items ?? []) byMd5.set(item.md5, item)
    return byMd5
  } catch {
    return new Map()
  }
}

const download = (url, dest) =>
  new Promise((resolve, reject) => {
    const mod = url.startsWith('http://') ? http : https
    const req = mod.get(
      url,
      { headers: { 'User-Agent': 'MicroMessenger Client', Referer: 'https://weixin.qq.com/' } },
      (res) => {
        if (res.statusCode !== 200) {
          res.resume()
          reject(new Error('http ' + res.statusCode))
          return
        }
        const chunks = []
        res.on('data', (c) => chunks.push(c))
        res.on('end', () => {
          const buf = Buffer.concat(chunks)
          if (buf.length < 200) {
            reject(new Error('too small: ' + buf.length))
            return
          }
          fs.mkdirSync(path.dirname(dest), { recursive: true })
          fs.writeFileSync(dest, buf)
          resolve(buf.length)
        })
      },
    )
    req.on('error', reject)
    req.setTimeout(15000, () => req.destroy(new Error('timeout')))
  })

const main = async () => {
  const chat = args.chat
  if (!chat) {
    emit({ ok: false, error: 'need --chat' })
    return
  }
  const table = tableFor(chat)
  let xml = ''
  let md5 = args.md5 ?? ''
  let localId = args['local-id'] ? Number(args['local-id']) : null
  try {
    const db = new DatabaseSync(MSG_DB, { readOnly: true })
    const tables = new Set(
      db.prepare("select name from sqlite_master where type='table'").all().map((r) => r.name),
    )
    if (!tables.has(table)) {
      emit({ ok: false, error: 'no table ' + table, md5 })
      return
    }
    // Prefer the explicit row; otherwise fall back to the newest sticker.
    const row = localId
      ? db
          .prepare(`select local_id, message_content, WCDB_CT_message_content from "${table}" where local_id = ?`)
          .get(localId)
      : db
          .prepare(
            `select local_id, message_content, WCDB_CT_message_content from "${table}" where local_type = 47 order by sort_seq desc limit 1`,
          )
          .get()
    db.close()
    if (!row) {
      emit({ ok: false, error: 'row not found', md5 })
      return
    }
    localId = row.local_id
    xml = textOf(row.message_content, row.WCDB_CT_message_content)
    if (!md5) {
      const m = /md5\s*=\s*"([0-9a-f]{16,64})"/i.exec(xml) ?? /md5="([^"]+)"/i.exec(xml)
      md5 = m ? m[1] : ''
    }
  } catch (error) {
    emit({ ok: false, error: 'db: ' + String(error), md5 })
    return
  }

  const byMd5 = loadIndex()
  const hit = md5 ? byMd5.get(md5) : undefined
  if (hit?.file) {
    const file = path.join(FAV, hit.file)
    if (fs.existsSync(file)) {
      emit({ ok: true, local_id: localId, md5, index: hit.i, file, text: hit.text, tags: hit.tags, desc: hit.desc, builtin: false, source: 'favourite' })
      return
    }
  }
  if (hit?.builtin) {
    emit({ ok: true, local_id: localId, md5, index: hit.i, file: null, text: hit.text, tags: hit.tags, builtin: true, source: 'favourite' })
    return
  }

  // Not a favourite: try the plain CDN url from the XML.
  const url = /cdnurl\s*=\s*"([^"]+)"/i.exec(xml)?.[1] ?? ''
  if (url && md5) {
    const dest = path.join(INCOMING, md5 + '.png')
    if (fs.existsSync(dest)) {
      emit({ ok: true, local_id: localId, md5, index: null, file: dest, text: '', tags: [], source: 'incoming-cache' })
      return
    }
    try {
      const bytes = await download(url.replace(/&amp;/g, '&'), dest)
      emit({ ok: true, local_id: localId, md5, index: null, file: dest, text: '', tags: [], source: 'incoming-cdn', bytes })
      return
    } catch (error) {
      emit({ ok: false, local_id: localId, md5, error: 'download: ' + String(error) })
      return
    }
  }
  emit({ ok: false, local_id: localId, md5, error: 'unknown sticker (no favourite match, no cdnurl)' })
}

main().catch((error) => emit({ ok: false, error: String(error) }))
