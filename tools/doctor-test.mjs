import { DEFAULTS, resolveConfig, findBridgePath, selfCheck, formatSelfCheck } from 'file:///E:/DSH/dsh-wx-desktop/index.js'

const base = resolveConfig({
  ...DEFAULTS,
  dataDir: process.env.WX_DATA_DIR ?? 'C:\\Users\\me\\.dsh\\weixin',
  pythonPath: process.env.WX_PYTHON ?? 'python',
  nodePath: process.env.WX_NODE ?? 'node',
  dbDir: process.env.WX_DB_DIR ?? 'D:\\WeChat\\wxid_test\\db_storage',
  chatUser: process.env.WX_CHAT_USER ?? 'wxid_test',
  peerName: process.env.WX_PEER_NAME ?? '张三',
})

console.log('bridge (autodetect) =', findBridgePath(base))
console.log('bridge (explicit)   =', findBridgePath({ ...base, bridgePath: 'D:\\x\\agent-bridge.js' }))
console.log('bridge (home-expand )=', findBridgePath({ ...base, bridgePath: '~/agent-bridge.js' }))

// Simulate a fresh install: everything under a bogus data dir.
const fresh = resolveConfig({ ...DEFAULTS, dataDir: '%TEMP%\\wx-fresh' })
const result = selfCheck(fresh)
console.log('\nfresh install ok =', result.ok)
console.log(formatSelfCheck(result))
