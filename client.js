// 微信桌面桥 / dsh-wx-desktop — 设置里的入口。
// The panel itself is served by the host plugin on 127.0.0.1:<panelPort>; here we
// only draw a settings section that embeds it, so the user never has to leave DSH.
window.__ModuleLoader__.load({
  id: 'dsh-wx-desktop',
  factory: (require) => {
    const React = require('react')
    const h = React.createElement

    const PANEL_URL = 'http://127.0.0.1:47180/'

    const css =
      '.wxdbCard{border:.5px solid var(--dsw-alias-border-l4);background:var(--dsw-alias-bg-layer-3);border-radius:16px;padding:16px;display:flex;flex-direction:column;gap:12px}' +
      '.wxdbHead{display:flex;align-items:center;justify-content:space-between;gap:12px}' +
      '.wxdbTitle{font-size:15px;font-weight:600;color:var(--dsw-alias-label-primary);line-height:1.4}' +
      '.wxdbDesc{font-size:13px;line-height:1.6;color:var(--dsw-alias-label-tertiary)}' +
      '.wxdbRow{display:flex;gap:8px;align-items:center;flex-wrap:wrap}' +
      '.wxdbBtn{appearance:none;border:.5px solid var(--dsw-alias-border-l4);background:var(--dsw-alias-bg-layer-2);color:var(--dsw-alias-label-primary);border-radius:8px;padding:6px 12px;font:inherit;font-size:13px;cursor:pointer}' +
      '.wxdbBtn:hover{border-color:var(--dsw-alias-label-dimmed)}' +
      '.wxdbFrame{width:100%;height:520px;border:.5px solid var(--dsw-alias-border-l4);border-radius:12px;background:var(--dsw-alias-bg-layer-2)}' +
      '.wxdbHint{font-size:12px;line-height:1.6;color:var(--dsw-alias-label-tertiary)}' +
      '.wxdbUrl{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px}'

    function PanelCard() {
      const [show, setShow] = React.useState(true)
      return h('div', { className: 'wxdbCard' },
        h('div', { className: 'wxdbHead' },
          h('div', null,
            h('div', { className: 'wxdbTitle' }, '微信桌面桥'),
            h('div', { className: 'wxdbDesc' }, '发送方案、自检结果、日志尾巴、收藏表情，都能在这里直接看和点。')),
          h('button', {
            type: 'button',
            className: 'wxdbBtn',
            onClick: () => setShow((v) => !v),
          }, show ? '收起面板' : '展开面板')),
        h('div', { className: 'wxdbRow' },
          h('button', {
            type: 'button',
            className: 'wxdbBtn',
            onClick: () => window.open(PANEL_URL, '_blank', 'noopener'),
          }, '在新窗口打开'),
          h('span', { className: 'wxdbHint wxdbUrl' }, PANEL_URL)),
        show ? h('iframe', {
          className: 'wxdbFrame',
          src: PANEL_URL,
          title: '微信桌面桥面板',
          loading: 'lazy',
        }) : null,
        h('div', { className: 'wxdbHint' },
          '面板由插件主机开在 127.0.0.1:47180。空白说明插件没在跑或端口被改过：到 profile 的配置里看 panelPort，或发 /doctor 自查。'))
    }

    return {
      inject: ['slots'],
      apply(ctx) {
        ctx.effect(() => {
          const style = document.createElement('style')
          style.dataset.pluginCss = 'dsh-wx-desktop'
          style.textContent = css
          document.head.appendChild(style)
          return () => style.remove()
        }, 'wx-desktop styles')

        ctx.slots.inject('settings.section', () => ctx.slots.register({
          name: 'settings.section',
          id: 'wx-desktop',
          order: 45,
          label: () => '微信桌面桥',
        }, PanelCard))
      },
    }
  },
})
