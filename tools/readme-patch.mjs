import { readFileSync, writeFileSync } from 'node:fs'

const p = 'E:/DSH/dsh-wx-desktop/README.md'
let t = readFileSync(p, 'utf8')

const anchor = '---\n\n## 常用配置'
const add = `---

## 本地面板（可选）

配置里写 \`panelPort: 47180\` 并重启，浏览器打开 http://127.0.0.1:47180 就能看到：

- 当前发送方案（A/B）与一键切换
- 自检结果、配置摘要、日志尾巴（不用去翻 plugin.log）
- 收藏表情墙，点一下就把那张表情发出去

只绑 127.0.0.1；要转发端口就设 \`panelToken\`，访问时带 \`?token=...\`。

---

## 常用配置`

if (!t.includes(anchor)) {
  console.error('anchor missing')
  process.exit(1)
}
t = t.replace(anchor, add)

const rowAnchor = '| `autoSend` | `true` | 关掉只记账不发 |'
if (t.includes(rowAnchor)) {
  t = t.replace(rowAnchor, rowAnchor + '\n| `panelPort` | `0` | 本地面板端口，0 = 关闭 |')
} else {
  console.warn('row anchor missing')
}

writeFileSync(p, t, 'utf8')
console.log('README updated, bytes =', Buffer.byteLength(t))
