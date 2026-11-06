import { readFileSync } from 'node:fs'
import { DEFAULTS, resolveConfig, selfCheck, formatSelfCheck, findBridgePath } from 'file:///E:/DSH/dsh-wx-desktop/index.js'

const ymlPath = 'C:/Users/LX/AppData/Roaming/dsh-desktop/harness/profiles/web/cordis.patch.yml'
const { load } = await import('file:///C:/Users/LX/AppData/Roaming/dsh-desktop/harness/profiles/web/node_modules/js-yaml/index.js')
const doc = load(readFileSync(ymlPath, 'utf8'))
const entry = doc.find((e) => e && e.id === 'dsh-wx-desktop')
if (!entry) throw new Error('dsh-wx-desktop entry missing from cordis.patch.yml')

const cfg = resolveConfig({ ...DEFAULTS, ...(entry.config ?? {}) })
console.log('conversationId =', cfg.conversationId)
console.log('dataDir        =', cfg.dataDir)
console.log('wcdbDir        =', cfg.wcdbDir)
console.log('watcherScript  =', cfg.watcherScript)
console.log('sayScript      =', cfg.sayScript)
console.log('logPath        =', cfg.logPath)
console.log('dbDir          =', cfg.dbDir)
console.log('bridgePath     =', findBridgePath(cfg))
console.log('')
const result = selfCheck(cfg)
console.log('selfCheck ok =', result.ok)
console.log(formatSelfCheck(result))
