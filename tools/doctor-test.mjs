import { DEFAULTS, resolveConfig, findBridgePath, selfCheck, formatSelfCheck } from 'file:///E:/DSH/dsh-wx-desktop/index.js'

const base = resolveConfig({
  ...DEFAULTS,
  dataDir: 'C:\\Users\\LX\\.dsh\\weixin',
  pythonPath: 'C:\\Users\\LX\\.dsh\\weixin\\asr-venv\\Scripts\\python.exe',
  nodePath: 'C:\\Users\\LX\\cmd ai\\node.exe',
  dbDir: 'D:\\LeStoreDownload\\xwechat_files\\wxid_kn207qgkufhp29_5794\\db_storage',
  chatUser: 'wxid_hmqh1bam6y3422',
  peerName: '猪葛凉',
})

console.log('bridge (autodetect) =', findBridgePath(base))
console.log('bridge (explicit)   =', findBridgePath({ ...base, bridgePath: 'D:\\x\\agent-bridge.js' }))
console.log('bridge (home-expand )=', findBridgePath({ ...base, bridgePath: '~/agent-bridge.js' }))

// Simulate a fresh install: everything under a bogus data dir.
const fresh = resolveConfig({ ...DEFAULTS, dataDir: '%TEMP%\\wx-fresh' })
const result = selfCheck(fresh)
console.log('\nfresh install ok =', result.ok)
console.log(formatSelfCheck(result))
