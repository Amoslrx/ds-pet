# DS娘桌宠 · DSH Web 动态插件源码（参考）
# ============================================================
# 这是同款桌宠在 DeepSeek Harness Web GUI 里的动态 Cordis 插件源码
# （dspet-1 / pkg-3）。原生桌面版见 pet.ps1。
# 用法：在 DSH 中通过 cordis_define / cordis_run 动态加载，
# 或在 dsh 里对会话说「运行桌宠插件」。
# 注意：Web 插件只能存在于 DSH 页面内，跨网页常驻请用原生版 pet.ps1。
# ============================================================

===== HOST 半部（code.host）=====

return {
  apply(ctx) {
    const webServer = ctx.get('webServer')
    const fs = ctx.get('fs')
    const credentials = ctx.get('credentials')
    const subprocess = ctx.get('subprocess')
    if (webServer === undefined || fs === undefined) return

    ctx.effect(() => webServer.register({
      kind: 'exact',
      path: '/ds-pet/ds.png',
      handler: async (req, res) => {
        try {
          const target = await fs.resolve('E:/dsh workplace/ds-cutout.png')
          const bytes = await fs.readBytes(target, undefined, 8 * 1024 * 1024)
          res.writeHead(200, {
            'Content-Type': 'image/png',
            'Content-Length': String(bytes.length),
            'Cache-Control': 'no-store',
          })
          res.end(bytes)
        } catch (err) {
          console.error('ds-pet: serve cutout failed', err && err.message)
          res.writeHead(404)
          res.end()
        }
      },
    }))

    if (credentials === undefined || subprocess === undefined) return
    ctx.effect(() => harness.handle('pet-balance', async () => {
      try {
        const resolved = await credentials.resolve('DEEPSEEK_API_KEY')
        if (!resolved || !resolved.value) return { ok: false, error: '未配置 DeepSeek API Key（~/.dsh/.credentials.yaml）' }
        const script = [
          "const c=new AbortController();const t=setTimeout(()=>c.abort(),15000);",
          "fetch('https://api.deepseek.com/user/balance',{headers:{Authorization:'Bearer '+process.env.DSK_BALANCE_KEY},signal:c.signal})",
          ".then(r=>r.json()).then(j=>{clearTimeout(t);console.log(JSON.stringify(j))})",
          ".catch(e=>{clearTimeout(t);console.error(e&&e.message||String(e));process.exit(1)})",
        ].join('')
        const handle = subprocess.spawn({
          argv: ['C:/Program Files/nodejs/node.exe', '-e', script],
          cwd: 'E:/dsh workplace',
          stdio: { stdin: 'ignore', stdout: { maxBytes: 65536 }, stderr: { maxBytes: 65536 } },
          graceMs: 8000,
          env: { DSK_BALANCE_KEY: resolved.value },
        })
        const outcome = await handle.done
        const out = handle.collected.stdout ? handle.collected.stdout.finalize().text : ''
        const err = handle.collected.stderr ? handle.collected.stderr.finalize().text : ''
        if (outcome.exitCode !== 0) return { ok: false, error: (err || ('请求失败，退出码 ' + outcome.exitCode)).slice(0, 200) }
        let json
        try { json = JSON.parse(out) } catch (e) { return { ok: false, error: '余额响应解析失败' } }
        if (json && Array.isArray(json.balance_infos) && json.balance_infos.length > 0) {
          const b = json.balance_infos[0]
          return {
            ok: true,
            available: !!json.is_available,
            currency: b.currency || '',
            total: b.total_balance || '0',
            granted: b.granted_balance || '0',
            toppedUp: b.topped_up_balance || '0',
          }
        }
        return { ok: false, error: '余额接口返回异常' }
      } catch (err) {
        console.error('ds-pet: balance failed', err && err.message)
        return { ok: false, error: ((err && err.message) || String(err)).slice(0, 200) }
      }
    }))
  },
}

===== CLIENT 半部（code.client）=====

return {
  inject: ['timer'],
  apply(ctx) {
    const slots = ctx.get('slots')
    if (slots === undefined) return

    const IMG_SRC = '/ds-pet/ds.png'
    const BAL_KEY = 'F8'
    const PHRASES = [
      '唔…需要帮忙吗？(´｡• ᵕ •｡`)',
      '今天也要加油鸭！(๑•̀ㅂ•́)و✧',
      '代码写完啦吗？写完就奖励你摸摸头~',
      '本娘正在全力运转中…ヽ(･ω･｡)ﾉ',
      '喵~ 有什么心事都可以告诉我哦',
      '小心 bug 出没！(っ˘̩╭╮˘̩)っ',
      '抱抱~ 你做得已经很棒啦！',
      'DeepSeek 娘今天也很可爱呢！',
      '喝口奶茶继续战斗吧！(๑´ㅂ`๑)',
      '想听笑话吗？…其实我自己就是个笑话(≧∇≦)ﾉ',
      '认真思考中，请稍候…(｡•̀ᴗ-)✧',
      '你认真的样子真好看！',
      '累了就休息一下下嘛~',
      '叮！灵感 +1 ✨',
    ]

    styles.insert(`
      .dspet-root { position: fixed; right: 28px; bottom: 28px; z-index: 9999; pointer-events: auto; user-select: none; -webkit-user-select: none; font-family: system-ui, -apple-system, 'Segoe UI', 'PingFang SC', sans-serif; }
      .dspet-imgwrap { position: relative; width: 150px; cursor: grab; touch-action: none; transform-origin: 50% 100%; transition: transform 0.05s linear; }
      .dspet-imgwrap:active { cursor: grabbing; }
      .dspet-img { display: block; width: 150px; height: auto; pointer-events: none; animation: dspet-bob 3.4s ease-in-out infinite; filter: drop-shadow(0 6px 12px rgba(30, 40, 80, 0.28)); }
      @keyframes dspet-bob { 0%, 100% { transform: translateY(0); } 50% { transform: translateY(-9px); } }
      .dspet-bubble-anchor { position: absolute; left: 50%; bottom: calc(100% + 14px); transform: translateX(-50%); pointer-events: none; z-index: 3; white-space: nowrap; }
      .dspet-bubble-anim { animation: dspet-pop 0.28s cubic-bezier(0.34, 1.56, 0.64, 1); }
      .dspet-bubble { position: relative; max-width: 320px; background: linear-gradient(180deg, #ffffff, #f3f6ff); color: #3a4a6b; border: 2px solid #cdd9f5; border-radius: 16px; padding: 8px 14px; font-size: 13px; line-height: 1.45; box-shadow: 0 6px 18px rgba(60, 90, 180, 0.18); }
      .dspet-bubble::after { content: ''; position: absolute; top: 100%; left: 50%; transform: translateX(-50%); border: 7px solid transparent; border-top-color: #f3f6ff; margin-top: -2px; }
      .dspet-bubble-bal { border-color: #ffe3b8; background: linear-gradient(180deg, #fffdf5, #fff6e6); color: #8a5a00; }
      .dspet-bubble-bal::after { border-top-color: #fff6e6; }
      @keyframes dspet-pop { from { transform: translateY(10px) scale(0.7); opacity: 0; } to { transform: translateY(0) scale(1); opacity: 1; } }
      .dspet-zoom { position: absolute; bottom: -8px; right: -10px; display: flex; gap: 6px; z-index: 2; }
      .dspet-btn { width: 24px; height: 24px; border-radius: 50%; border: 2px solid #cdd9f5; background: rgba(255, 255, 255, 0.94); color: #4a5f8f; font-size: 14px; font-weight: 700; line-height: 1; cursor: pointer; box-shadow: 0 3px 8px rgba(60, 90, 180, 0.2); display: flex; align-items: center; justify-content: center; padding: 0; }
      .dspet-btn:hover { background: #eef3ff; transform: scale(1.12); }
    `)

    slots.inject('shell.overlay', () => slots.register(
      { name: 'shell.overlay', id: 'ds-pet' },
      () => {
        const imgRef = React.useRef(null)
        const dragRef = React.useRef(null)
        const hideRef = React.useRef(null)
        const posRef = React.useRef(null)
        const rotRef = React.useRef(0)
        const balCacheRef = React.useRef(null)
        const [pos, setPos] = React.useState(null)
        const [rot, setRot] = React.useState(0)
        const [scale, setScale] = React.useState(1)
        const [phrase, setPhrase] = React.useState(null)
        const [phraseKey, setPhraseKey] = React.useState(0)
        const [bal, setBal] = React.useState(null)
        const [balVisible, setBalVisible] = React.useState(false)

        React.useEffect(() => { posRef.current = pos }, [pos])
        React.useEffect(() => { rotRef.current = rot }, [rot])

        const showPhrase = (text, ms) => {
          setPhrase(text)
          setPhraseKey(k => k + 1)
          if (hideRef.current) hideRef.current()
          hideRef.current = ctx.timeout(() => { setPhrase(null); hideRef.current = null }, ms || 3600)
        }

        const randomPhrase = () => PHRASES[Math.floor(Math.random() * PHRASES.length)]

        const fetchBalance = async () => {
          const now = Date.now()
          const cached = balCacheRef.current
          if (cached && now - cached.at < 30000) { setBal(cached.data); return }
          try {
            const res = await host.call('pet-balance')
            balCacheRef.current = { data: res, at: Date.now() }
            setBal(res)
          } catch (e) { setBal({ ok: false, error: (e && e.message) || String(e) }) }
        }

        React.useEffect(() => {
          if (typeof document === 'undefined') return
          const down = (e) => { if (e.key !== BAL_KEY || e.repeat) return; fetchBalance(); setBalVisible(true) }
          const up = (e) => { if (e.key !== BAL_KEY) return; setBalVisible(false) }
          document.addEventListener('keydown', down)
          document.addEventListener('keyup', up)
          return () => {
            document.removeEventListener('keydown', down)
            document.removeEventListener('keyup', up)
          }
        }, [])

        const onPointerDown = (e) => {
          e.preventDefault()
          const el = imgRef.current
          if (el && el.setPointerCapture) { try { el.setPointerCapture(e.pointerId) } catch (err) {} }
          dragRef.current = {
            mode: e.button === 2 ? 'rotate' : 'drag',
            x: e.clientX, y: e.clientY,
            left: posRef.current ? posRef.current.left : null,
            top: posRef.current ? posRef.current.top : null,
            rot: rotRef.current,
            moved: false,
          }
        }

        const onPointerMove = (e) => {
          const d = dragRef.current
          if (!d) return
          const dx = e.clientX - d.x
          const dy = e.clientY - d.y
          if (Math.abs(dx) + Math.abs(dy) > 4) d.moved = true
          if (d.mode === 'drag') {
            if (d.left === null || d.top === null) {
              const r = imgRef.current ? imgRef.current.getBoundingClientRect() : null
              if (r) { d.left = r.left; d.top = r.top }
            }
            if (d.left !== null && d.top !== null) setPos({ left: d.left + dx, top: d.top + dy })
          } else {
            const el = imgRef.current
            if (!el) return
            const r = el.getBoundingClientRect()
            const cx = r.left + r.width / 2
            const cy = r.top + r.height / 2
            const a0 = Math.atan2(d.y - cy, d.x - cx)
            const a1 = Math.atan2(e.clientY - cy, e.clientX - cx)
            setRot(d.rot + (a1 - a0) * 180 / Math.PI)
          }
        }

        const endDrag = (e) => {
          const d = dragRef.current
          dragRef.current = null
          const el = imgRef.current
          if (el && el.releasePointerCapture) { try { el.releasePointerCapture(e.pointerId) } catch (err) {} }
          if (d && d.mode === 'drag' && !d.moved) showPhrase(randomPhrase())
        }

        React.useEffect(() => {
          showPhrase('点我说话~ 右键转圈圈，滚轮缩放，按住 F8 看余额哦！', 6500)
          return () => { if (hideRef.current) hideRef.current() }
        }, [])

        React.useEffect(() => {
          const el = imgRef.current
          if (!el) return
          const onWheel = (e) => {
            e.preventDefault()
            const factor = e.deltaY < 0 ? 1.12 : 0.89
            setScale(s => Math.min(3, Math.max(0.35, s * factor)))
          }
          el.addEventListener('wheel', onWheel, { passive: false })
          return () => el.removeEventListener('wheel', onWheel)
        }, [])

        const posStyle = pos ? { left: pos.left + 'px', top: pos.top + 'px', right: 'auto', bottom: 'auto' } : {}
        const counterRot = 'rotate(' + (-rot) + 'deg)'
        const balText = balVisible && bal
          ? (bal.ok ? '💰 DeepSeek 余额 ' + bal.total + ' ' + (bal.currency || '') + (bal.granted ? '（充值 ' + bal.toppedUp + ' · 赠送 ' + bal.granted + '）' : '') : '😿 ' + ((bal.error || '余额获取失败').slice(0, 60)))
          : null

        return React.createElement('div', { className: 'dspet-root', style: posStyle },
          React.createElement('div', {
            ref: imgRef,
            className: 'dspet-imgwrap',
            style: { transform: 'rotate(' + rot + 'deg) scale(' + scale + ')' },
            onPointerDown, onPointerMove, onPointerUp: endDrag,
            onContextMenu: (e) => e.preventDefault(),
            onDoubleClick: () => { setRot(0); setScale(1) },
          },
            React.createElement('img', { className: 'dspet-img', src: IMG_SRC, draggable: false, alt: 'DS娘桌宠', onError: (e) => { e.target.style.opacity = '0.25' } }),
            balText
              ? React.createElement('div', { className: 'dspet-bubble-anchor' },
                  React.createElement('div', { className: 'dspet-bubble-anim' },
                    React.createElement('div', { className: 'dspet-bubble dspet-bubble-bal', style: { transform: counterRot } }, balText),
                  ),
                )
              : null,
            phrase
              ? React.createElement('div', { className: 'dspet-bubble-anchor' },
                  React.createElement('div', { key: phraseKey, className: 'dspet-bubble-anim' },
                    React.createElement('div', { className: 'dspet-bubble', style: { transform: counterRot } }, phrase),
                  ),
                )
              : null,
          ),
          React.createElement('div', { className: 'dspet-zoom' },
            React.createElement('button', { className: 'dspet-btn', onPointerDown: (e) => e.stopPropagation(), onClick: () => setScale(s => Math.min(3, s * 1.2)) }, '+'),
            React.createElement('button', { className: 'dspet-btn', onPointerDown: (e) => e.stopPropagation(), onClick: () => setScale(s => Math.max(0.35, s * 0.83)) }, '−'),
          ),
        )
      },
    ))
  },
}
