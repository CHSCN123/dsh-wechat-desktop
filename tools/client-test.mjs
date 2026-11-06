// 离线模拟浏览器侧 __ModuleLoader__，验证 client.js 的模块形状与 apply() 行为。
import { readFileSync } from 'node:fs'
import vm from 'node:vm'

const code = readFileSync('E:/DSH/dsh-wx-desktop/client.js', 'utf8')

const registered = []
const styleTags = []
const ReactStub = {
  createElement: (type, props, ...kids) => ({ type, props, kids }),
  useState: (init) => [init, () => {}],
}

const sandbox = {
  window: {
    __ModuleLoader__: { load: (desc) => registered.push(desc) },
    open: () => {},
  },
  document: {
    createElement: () => {
      const el = { dataset: {}, textContent: '', remove() {} }
      styleTags.push(el)
      return el
    },
    head: { appendChild() {} },
  },
  console,
}

vm.createContext(sandbox)
vm.runInContext(code, sandbox, { filename: 'client.js' })

if (registered.length !== 1) {
  console.error('expected exactly one module registration, got', registered.length)
  process.exit(1)
}

const desc = registered[0]
const plugin = desc.factory((name) => {
  if (name === 'react') return ReactStub
  throw new Error('unexpected require: ' + name)
})

console.log('id =', desc.id)
console.log('inject =', plugin.inject.join(','))
if (!plugin.inject.includes('slots')) throw new Error('plugin must inject slots')

let registeredSlot = null
const ctx = {
  effect: (fn) => fn(),
  slots: {
    inject: (slot, fn) => fn(),
    register: (meta, component) => {
      registeredSlot = { meta, component }
      return () => {}
    },
  },
}

plugin.apply(ctx)
console.log('slot name =', registeredSlot.meta.name)
console.log('slot id =', registeredSlot.meta.id, '| order =', registeredSlot.meta.order, '| label =', registeredSlot.meta.label())

const card = registeredSlot.component()
console.log('card class =', card.props.className)
const iframe = find(card, (n) => n && n.type === 'iframe')
console.log('iframe src =', iframe ? iframe.props.src : '(none)')
console.log('styles injected =', styleTags.length)

function find(node, pred) {
  if (!node || typeof node !== 'object') return null
  if (pred(node)) return node
  const kids = node.kids || []
  for (const kid of kids) {
    const hit = find(kid, pred)
    if (hit) return hit
  }
  return null
}
