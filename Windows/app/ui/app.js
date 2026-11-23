import { CODECS, SPOTIFY, YOUTUBE, SOUNDCLOUD } from './codecs.js'

// MARK: platform model (same rules as Sources/Model.swift)

const PLATFORMS = [
  { key: 'original', title: 'Original', tint: 'var(--accent)' },
  { key: 'spotify', title: 'Spotify', tint: 'rgb(31,204,97)' },
  { key: 'youtube', title: 'YouTube', tint: 'rgb(255,56,56)' },
  { key: 'soundcloud', title: 'SoundCloud', tint: 'rgb(255,107,0)' },
]
const LEVELS = [
  { label: 'Loud', target: -11 },
  { label: 'Normal', target: -14 },
  { label: 'Quiet', target: -19 },
]
const LOUD = 0, NORMAL = 1

const state = {
  tracks: [],
  activeID: null,
  platform: 1,
  level: NORMAL,
  spotifyCodec: 2,
  youtubeCodec: 4,
  soundcloudCodec: 6,
  playing: false,
  time: 0,
}

let nextID = 1
const active = () => state.tracks.find((t) => t.id === state.activeID)

function setting(info) {
  switch (state.platform) {
    case 0: return { codec: 0, gainDB: 0, limiter: false }
    case 1: {
      const g = info.spotifyGain[state.level]
      return { codec: state.spotifyCodec, gainDB: g, limiter: state.level === LOUD && info.limiterCodecs.has(state.spotifyCodec) }
    }
    case 2: return { codec: state.youtubeCodec, gainDB: info.youtubeGain, limiter: false }
    case 3: return { codec: state.soundcloudCodec, gainDB: info.soundcloudGain, limiter: false }
  }
}

function readout(info, p) {
  switch (p) {
    case 0: return { gainDB: 0, lufs: info.lufs, tp: info.tp, limited: false }
    case 1: {
      const c = state.spotifyCodec, g = info.spotifyGain[state.level]
      if (state.level === LOUD && info.limiterCodecs.has(c)) {
        return { gainDB: g, lufs: info.loudLUFS[c] ?? info.lufs + g, tp: info.loudTP[c] ?? info.codecTP[c] + g, limited: true }
      }
      return { gainDB: g, lufs: info.lufs + g, tp: info.codecTP[c] + g, limited: false }
    }
    case 2: { const g = info.youtubeGain; return { gainDB: g, lufs: info.lufs + g, tp: info.codecTP[state.youtubeCodec] + g, limited: false } }
    case 3: { const g = info.soundcloudGain; return { gainDB: g, lufs: info.lufs + g, tp: info.codecTP[state.soundcloudCodec] + g, limited: false } }
  }
}

// MARK: audio engine

const ctx = new AudioContext({ latencyHint: 'interactive' })
const playRate = ctx.sampleRate
const engineState = new Int32Array(new SharedArrayBuffer(8))
let node = null
let generation = 0
let lastEnd = 0
const engineReady = ctx.audioWorklet.addModule('worklet.js').then(() => {
  node = new AudioWorkletNode(ctx, 'lp-renderer', {
    numberOfInputs: 0, numberOfOutputs: 1, outputChannelCount: [2],
    processorOptions: { state: engineState.buffer },
  })
  node.connect(ctx.destination)
})

const enginePosition = () => Atomics.load(engineState, 0)

function push(seek = null) {
  const t = active()
  const ready = t && t.info && t.loaded
  if (!ready) state.playing = false
  let route = null
  if (ready) {
    const s = setting(t.info)
    route = { id: t.id, codec: s.codec, gain: 10 ** (s.gainDB / 20), limiter: s.limiter }
  }
  if (state.playing && ctx.state !== 'running') ctx.resume()
  generation++
  node?.port.postMessage({ type: 'control', generation, playing: state.playing, route, seek })
}

// MARK: worker pool

const POOL = Math.max(2, Math.min((navigator.hardwareConcurrency || 4) - 1, 8))
const workers = []
const queue = []
let jobID = 0
const pendingJobs = new Map()

let idleTimer = null

function makeWorker() {
  const w = new Worker('worker.js', { type: 'module' })
  w.busy = false
  w.onmessage = (e) => {
    const { id, result, error } = e.data
    const job = pendingJobs.get(id)
    pendingJobs.delete(id)
    w.busy = false
    error ? job.reject(new Error(error)) : job.resolve(result)
    pump()
  }
  w.onerror = (e) => console.error('worker', e.message)
  return w
}

// Workers start on demand; wasm memory never shrinks, so idle workers are released.
function pump() {
  clearTimeout(idleTimer)
  while (queue.length) {
    let w = workers.find((x) => !x.busy)
    if (!w && workers.length < POOL) { w = makeWorker(); workers.push(w) }
    if (!w) break
    const job = queue.shift()
    w.busy = true
    pendingJobs.set(job.id, job)
    w.postMessage({ id: job.id, op: job.op, args: job.args }, job.transfer || [])
  }
  if (!queue.length && workers.every((w) => !w.busy)) {
    idleTimer = setTimeout(() => { workers.splice(0).forEach((w) => w.terminate()) }, 4000)
  }
}

function run(op, args, transfer) {
  return new Promise((resolve, reject) => {
    queue.push({ id: ++jobID, op, args, transfer, resolve, reject })
    pump()
  })
}

// MARK: files

async function decode(buffer) {
  const pcm = await run('decode', { buffer })
  if (pcm) return pcm
  const off = new OfflineAudioContext(2, 1, 48000)
  const ab = await off.decodeAudioData(buffer)
  const channels = []
  for (let c = 0; c < Math.min(2, ab.numberOfChannels); c++) {
    const s = new Float32Array(new SharedArrayBuffer(ab.length * 4))
    s.set(ab.getChannelData(c))
    channels.push(s)
  }
  return { rate: ab.sampleRate, channels }
}

function addFiles(items) {
  for (const it of items) {
    const name = it.name.replace(/\.[^.]+$/, '')
    const ext = (it.name.match(/\.([^.]+)$/)?.[1] || '').toUpperCase()
    const t = { id: nextID++, name, ext, progress: 0, preview: [], info: null, failed: false, loaded: false, position: 0, scale: null }
    state.tracks.push(t)
    if (state.activeID == null) state.activeID = t.id
    render()
    process(t, it.read).catch((err) => { console.error(err); t.failed = true; render() })
  }
}

async function process(t, read) {
  const buffer = await read()
  const src = await decode(buffer)
  let chs = src.channels.slice(0, 2)
  const fs = src.rate
  t.sourceRate = fs
  run('waveform', { chs, buckets: 1600 }).then((w) => { if (!t.info) { t.preview = w; render() } })

  const { lufs: L, tp, base } = await run('analyze', { chs, rate: fs, playRate })
  const frames = base[0].length
  const finite = Number.isFinite(L) && L > -70

  const spotifyGain = LEVELS.map((lvl, i) => {
    if (!finite) return 0
    let g = lvl.target - L
    if (g > 0 && i !== LOUD) g = Math.max(0, Math.min(g, -1 - tp))
    return g
  })
  const youtubeGain = finite ? Math.min(0, -14 - L) : 0
  const soundcloudGain = (() => {
    if (!finite) return 0
    const g = -14 - L
    return g > 0 ? Math.max(0, Math.min(g, -1 - tp)) : g
  })()
  const gLoud = spotifyGain[LOUD]

  const n = CODECS.length
  const steps = n
  let done = 0
  const versions = new Array(n).fill(null)
  versions[0] = base
  await Promise.all(CODECS.map((_, i) => i === 0 ? null : run('codec', { codec: i, chs, rate: fs, playRate, base })
    .then((v) => { versions[i] = v })
    .catch((e) => console.error(CODECS[i].label, e))
    .finally(() => { done++; t.progress = done / steps; render() })))

  const post = await Promise.all(versions.map((v, i) => v ? run('post', { v, playRate, gLoud, wave: i === 0 }) : null))
  const codecTP = post.map((p) => p ? p.ctp : tp)
  codecTP[0] = tp
  const envelopes = post.map((p) => p?.env || null)
  const wave = await run('waveform', { chs: base, buckets: 1600 })

  t.info = {
    lufs: L, tp, frames, duration: frames / playRate, waveform: wave,
    loudWaveform: post[0]?.loudWave || null, spotifyGain, youtubeGain, soundcloudGain,
    codecTP, loudTP: post.map((p) => p?.loudTP ?? null), loudLUFS: post.map((p) => p?.loudLUFS ?? null),
    limiterCodecs: new Set(envelopes.map((e, i) => e ? i : -1).filter((i) => i >= 0)),
  }
  t.progress = 1
  await engineReady
  node.port.postMessage({ type: 'add', id: t.id, frames, versions, envelopes })
  t.loaded = true
  chs = null
  render()
  if (state.activeID === t.id) push(t.position)
}

async function openDialog() {
  const paths = await window.host.openDialog()
  addPaths(paths)
}

function addPaths(paths) {
  addFiles(paths.map((p) => ({ name: p.split(/[\\/]/).pop(), read: () => window.host.readFile(p) })))
}

window.host?.onOpenPaths(addPaths)

// MARK: transport

function toggle() {
  if (!active()?.loaded) return
  state.playing = !state.playing
  push()
  render()
}

function scrub(t, fraction) {
  if (!t.info) return
  const frame = Math.floor(Math.min(Math.max(fraction, 0), 1) * (t.info.frames - 1))
  if (t.id !== state.activeID) {
    const cur = active()
    if (cur) cur.position = enginePosition()
    state.activeID = t.id
    state.playing = true
  }
  t.position = frame
  state.time = frame / playRate
  push(frame)
  render()
}

function step(delta) {
  const i = state.tracks.findIndex((t) => t.id === state.activeID)
  const j = i + delta
  if (i < 0 || j < 0 || j >= state.tracks.length) return
  const cur = active()
  if (cur) cur.position = enginePosition()
  const t = state.tracks[j]
  state.activeID = t.id
  state.time = t.position / playRate
  push(t.position)
  render()
}

function nudge(seconds) {
  const t = active()
  if (!t?.info) return
  scrub(t, (state.time + seconds) / t.info.duration)
}

function remove(t) {
  const i = state.tracks.findIndex((x) => x.id === t.id)
  if (i < 0) return
  const wasActive = t.id === state.activeID
  state.tracks.splice(i, 1)
  if (wasActive) {
    const next = state.tracks.length ? state.tracks[Math.min(i, state.tracks.length - 1)] : null
    state.activeID = next?.id ?? null
    if (!next) state.playing = false
    push(next?.position ?? 0)
    state.time = (next?.position ?? 0) / playRate
  }
  node?.port.postMessage({ type: 'remove', id: t.id })
  render()
}

function setPlatform(p) { state.platform = p; push(); render() }

function spotifyKey() {
  if (state.platform === 1) state.level = [2, 0, 1][state.level] // Normal → Loud → Quiet → Normal
  else state.platform = 1
  push()
  render()
}

function tick() {
  const t = active()
  if (state.playing && t) {
    const pos = enginePosition()
    state.time = pos / playRate
    t.position = pos
    const ends = Atomics.load(engineState, 1)
    if (ends !== lastEnd) {
      lastEnd = ends
      state.playing = false
      t.position = 0
      state.time = 0
      push(0)
      render()
    }
  } else {
    lastEnd = Atomics.load(engineState, 1)
  }
  updateFrame()
  requestAnimationFrame(tick)
}

// MARK: formatting

const fmtDB = (v) => {
  if (!Number.isFinite(v)) return '–'
  const r = Math.round(v * 10) / 10
  if (r === 0) return '0.0'
  const s = Math.abs(r).toFixed(1)
  return r > 0 ? '+' + s : '−' + s
}
const fmtTime = (t) => { const s = Math.floor(Math.max(t, 0)); return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}` }
const fmtKHz = (r) => { const k = r / 1000; return (Number.isInteger(k) ? k.toFixed(0) : k.toFixed(1)) + ' kHz' }
const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e }

// MARK: view

const root = document.getElementById('root')
const ICON_PLAY = '<svg viewBox="0 0 12 12"><path d="M3 1.6v8.8c0 .5.5.8.9.5l7-4.4c.4-.2.4-.8 0-1L3.9 1.1C3.5.8 3 1.1 3 1.6z"/></svg>'
const ICON_PAUSE = '<svg viewBox="0 0 12 12"><rect x="2.2" y="1.2" width="2.8" height="9.6" rx=".7"/><rect x="7" y="1.2" width="2.8" height="9.6" rx=".7"/></svg>'
const ICON_PLUS = '<svg viewBox="0 0 12 12"><path d="M6 1.5v9M1.5 6h9" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" fill="none"/></svg>'
const ICON_X = '<svg viewBox="0 0 10 10"><path d="M2 2l6 6M8 2l-6 6" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>'
const ICON_UPDOWN = '<svg viewBox="0 0 8 10"><path d="M1.5 3.8L4 1.3l2.5 2.5M1.5 6.2L4 8.7l2.5-2.5" stroke="currentColor" stroke-width="1.3" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg>'
const ICON_WAVE = '<svg viewBox="0 0 40 40"><g stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="M5 17v6M10 12v16M15 7v26M20 14v12M25 9v22M30 15v10M35 18v4"/></g></svg>'

const rows = new Map() // track id → { el, canvas, ... }
let dropTarget = false

function render() {
  root.classList.toggle('mac', window.host?.platform === 'darwin')
  if (!state.tracks.length) { renderEmpty(); return }
  if (!root.querySelector('.main')) {
    root.innerHTML = ''
    rows.clear()
    const main = el('div', 'main')
    main.append(renderTop(), el('div', 'list'), el('div', 'modes'))
    root.append(main, el('div', 'footer', 'Loudness Preview'))
  }
  const main = root.querySelector('.main')
  main.querySelector('.top .play').innerHTML = state.playing ? ICON_PAUSE : ICON_PLAY
  renderList(main.querySelector('.list'))
  renderModes(main.querySelector('.modes'))
  updateFrame()
}

function renderEmpty() {
  root.innerHTML = ''
  rows.clear()
  const drag = el('div', 'drag-strip')
  const box = el('button', 'empty' + (dropTarget ? ' targeted' : ''))
  box.innerHTML = ICON_WAVE
  box.append(el('div', 'empty-label', 'Drop audio files'))
  box.onclick = openDialog
  root.append(drag, box, el('div', 'footer', 'Loudness Preview'))
}

function renderTop() {
  const top = el('div', 'top')
  const play = el('button', 'round play')
  play.onclick = toggle
  const time = el('div', 'time')
  const add = el('button', 'round add')
  add.innerHTML = ICON_PLUS
  add.onclick = openDialog
  top.append(play, time, el('div', 'spacer'), add)
  return top
}

function renderList(list) {
  list.classList.toggle('targeted', dropTarget)
  const ids = new Set(state.tracks.map((t) => t.id))
  for (const [id, r] of rows) if (!ids.has(id)) { r.el.remove(); rows.delete(id) }
  state.tracks.forEach((t, i) => {
    let r = rows.get(t.id)
    if (!r) { r = makeRow(t); rows.set(t.id, r) }
    if (list.children[i] !== r.el) list.insertBefore(r.el, list.children[i] || null)
    updateRow(t, r)
  })
}

function makeRow(t) {
  const e = el('div', 'row')
  const head = el('div', 'row-head')
  const name = el('div', 'name', t.name)
  const bar = el('div', 'bar'); bar.append(el('div', 'bar-fill'))
  const spacer = el('div', 'spacer')
  const gain = el('div', 'num gain')
  const lufs = el('div', 'num lufs')
  const tp = el('div', 'num tp')
  const x = el('button', 'x'); x.innerHTML = ICON_X
  x.onclick = (ev) => { ev.stopPropagation(); remove(t) }
  head.append(name, bar, spacer, gain, lufs, tp, x)
  const wave = el('div', 'wave')
  const canvas = el('canvas')
  wave.append(canvas)
  let down = false
  const at = (ev) => { const b = wave.getBoundingClientRect(); scrub(t, (ev.clientX - b.left) / b.width) }
  wave.onpointerdown = (ev) => { if (!t.info) return; down = true; wave.setPointerCapture(ev.pointerId); at(ev) }
  wave.onpointermove = (ev) => { if (down) at(ev) }
  wave.onpointerup = wave.onpointercancel = () => { down = false }
  e.append(head, wave)
  return { el: e, name, bar, gain, lufs, tp, wave, canvas, scale: 1, from: 1, to: 1, start: 0 }
}

function rowSetting(t) { return t.info ? setting(t.info) : null }

function updateRow(t, r) {
  const isActive = t.id === state.activeID
  const tint = PLATFORMS[state.platform].tint
  r.el.classList.toggle('active', isActive)
  r.el.style.setProperty('--tint', tint)
  r.bar.style.display = t.info || t.failed ? 'none' : ''
  r.bar.firstChild.style.width = `${Math.round(t.progress * 100)}%`
  r.name.classList.toggle('failed', t.failed)
  const s = rowSetting(t)
  if (t.info) {
    r.gain.textContent = s && state.platform !== 0 ? `${fmtDB(s.gainDB)} dB` : ''
    r.lufs.textContent = `${fmtDB(t.info.lufs)} LUFS`
    r.tp.textContent = `${fmtDB(t.info.tp)} dBTP`
    r.tp.classList.toggle('hot', t.info.tp > -1)
  }
  const target = s ? 10 ** (s.gainDB / 20) : 1
  if (target !== r.to) { r.from = r.scale; r.to = target; r.start = performance.now() }
  r.wave.style.opacity = t.info ? 1 : 0.5
  drawRow(t, r)
}

function drawRow(t, r) {
  const now = performance.now()
  const k = Math.min(1, (now - r.start) / 250)
  const ease = 1 - (1 - k) ** 3
  r.scale = r.from + (r.to - r.from) * ease
  const animating = k < 1

  const isActive = t.id === state.activeID
  const s = rowSetting(t)
  const peaks = t.info ? (s?.limiter && t.info.loudWaveform ? t.info.loudWaveform : t.info.waveform) : t.preview
  const c = r.canvas
  const dpr = window.devicePixelRatio || 1
  const w = r.wave.clientWidth, h = r.wave.clientHeight
  if (!w || !h) return animating
  if (c.width !== Math.round(w * dpr) || c.height !== Math.round(h * dpr)) { c.width = Math.round(w * dpr); c.height = Math.round(h * dpr) }
  const g = c.getContext('2d')
  g.setTransform(dpr, 0, 0, dpr, 0, 0)
  g.clearRect(0, 0, w, h)
  const cs = getComputedStyle(r.el)
  const muted = cs.getPropertyValue('--wave').trim()
  const mutedActive = cs.getPropertyValue('--wave-active').trim()
  const played = isActive ? cs.getPropertyValue('--tint').trim() : cs.getPropertyValue('--wave-played').trim()
  const pos = isActive ? state.time * playRate : t.position
  const progress = t.info && t.info.frames > 0 ? Math.min(1, pos / t.info.frames) : 0

  const path = new Path2D()
  const mid = h / 2, half = h / 2
  if (!peaks.length) {
    path.rect(0, mid - 0.5, w, 1)
  } else {
    const count = Math.max(1, Math.floor(w / 2))
    const barW = w / count
    for (let i = 0; i < count; i++) {
      const a = Math.floor(i * peaks.length / count)
      const b = Math.max(a + 1, Math.floor((i + 1) * peaks.length / count))
      let m = 0
      for (let j = a; j < Math.min(b, peaks.length); j++) m = Math.max(m, peaks[j])
      const hh = Math.max(0.5, Math.min(1, m * r.scale) * half)
      path.rect(i * barW, mid - hh, Math.max(1, barW - 0.6), hh * 2)
    }
  }
  g.fillStyle = isActive ? mutedActive : muted
  g.fill(path)
  g.save()
  g.beginPath(); g.rect(0, 0, w * progress, h); g.clip()
  g.fillStyle = played
  g.fill(path)
  g.restore()
  if (t.info) {
    g.fillStyle = isActive ? cs.getPropertyValue('--fg').trim() : cs.getPropertyValue('--wave-played').trim()
    const lw = isActive ? 1.5 : 1
    g.fillRect(w * progress - lw / 2, 0, lw, h)
  }
  return animating
}

function chip(text, { highlight = false, menu = true } = {}) {
  const c = el('button', 'chip' + (highlight ? ' hl' : '') + (menu ? '' : ' static'))
  c.append(el('span', null, text))
  if (menu) { const i = el('span', 'updown'); i.innerHTML = ICON_UPDOWN; c.append(i) }
  return c
}

function renderModes(box) {
  box.innerHTML = ''
  const t = active()
  const info = t?.info
  PLATFORMS.forEach((p, i) => {
    const sel = state.platform === i
    const card = el('div', 'card' + (sel ? ' selected' : ''))
    card.style.setProperty('--tint', p.tint)
    card.onclick = () => setPlatform(i)
    const ro = info ? readout(info, i) : null

    const head = el('div', 'card-head')
    if (i !== 0) head.append(el('span', 'dot'))
    head.append(el('span', 'card-title', p.title), el('span', 'spacer'))
    if (ro?.limited) head.append(el('span', 'lim', 'LIM'))
    head.append(el('span', 'key', String(i + 1)))

    const acc = el('div', 'card-acc')
    if (i === 0) {
      if (info) acc.append(chip(`${t.ext || 'PCM'} · ${fmtKHz(t.sourceRate)}`, { menu: false }))
    } else if (i === 1) {
      const c = chip(`${LEVELS[state.level].label} · ${CODECS[state.spotifyCodec].label}`, { highlight: state.level !== NORMAL })
      c.onclick = (ev) => { ev.stopPropagation(); openMenu(c, [
        LEVELS.map((l, k) => ({ label: l.label, checked: state.level === k, pick: () => { state.level = k; state.platform = 1 } })),
        SPOTIFY.map((k) => ({ label: CODECS[k].label, checked: state.spotifyCodec === k, pick: () => { state.spotifyCodec = k; state.platform = 1 } })),
      ]) }
      acc.append(c)
    } else {
      const list = i === 2 ? YOUTUBE : SOUNDCLOUD
      const keyName = i === 2 ? 'youtubeCodec' : 'soundcloudCodec'
      const c = chip(CODECS[state[keyName]].label)
      c.onclick = (ev) => { ev.stopPropagation(); openMenu(c, [
        list.map((k) => ({ label: CODECS[k].label, checked: state[keyName] === k, pick: () => { state[keyName] = k; state.platform = i } })),
      ]) }
      acc.append(c)
    }

    const big = el('div', 'big')
    big.append(el('span', 'big-num', ro ? fmtDB(ro.gainDB) : '–'), el('span', 'big-unit', 'dB'))
    const small = el('div', 'small')
    const tpEl = el('span', null, `${ro ? fmtDB(ro.tp) : '–'} dBTP`)
    if (ro && ro.tp > 0) tpEl.className = 'hot'
    small.append(el('span', null, `${ro ? fmtDB(ro.lufs) : '–'} LUFS`), tpEl)
    card.append(head, acc, big, small)
    box.append(card)
  })
}

// MARK: menu

let menuEl = null
function closeMenu() { menuEl?.remove(); menuEl = null }
function openMenu(anchor, sections) {
  closeMenu()
  const m = el('div', 'menu')
  sections.forEach((items, si) => {
    if (si) m.append(el('div', 'menu-sep'))
    for (const it of items) {
      const b = el('button', 'menu-item' + (it.checked ? ' checked' : ''))
      b.append(el('span', 'check', it.checked ? '✓' : ''), el('span', null, it.label))
      b.onclick = (ev) => { ev.stopPropagation(); it.pick(); closeMenu(); push(); render() }
      m.append(b)
    }
  })
  document.body.append(m)
  const a = anchor.getBoundingClientRect()
  const mh = m.offsetHeight, mw = m.offsetWidth
  let top = a.bottom + 4
  if (top + mh > window.innerHeight - 8) top = a.top - mh - 4
  m.style.top = `${Math.max(8, top)}px`
  m.style.left = `${Math.min(a.left, window.innerWidth - mw - 8)}px`
  menuEl = m
}
window.addEventListener('pointerdown', (e) => { if (menuEl && !menuEl.contains(e.target)) closeMenu() }, true)
window.addEventListener('blur', closeMenu)
window.addEventListener('resize', () => { closeMenu(); render() })

// MARK: per-frame

function updateFrame() {
  const t = active()
  const time = root.querySelector('.top .time')
  if (time) time.textContent = `${fmtTime(state.time)} / ${fmtTime(t?.info?.duration ?? 0)}`
  for (const tr of state.tracks) {
    const r = rows.get(tr.id)
    if (!r) continue
    const animating = r.start && performance.now() - r.start < 260
    if (tr.id === state.activeID || animating) drawRow(tr, r)
  }
}

// MARK: input

window.addEventListener('keydown', (e) => {
  if (e.metaKey || e.ctrlKey || e.altKey) {
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'o') { e.preventDefault(); openDialog() }
    return
  }
  if (menuEl) { if (e.key === 'Escape') closeMenu(); return }
  const k = e.key
  if (k === ' ') toggle()
  else if (k === 'ArrowLeft') nudge(-5)
  else if (k === 'ArrowRight') nudge(5)
  else if (k === 'ArrowUp') step(-1)
  else if (k === 'ArrowDown') step(1)
  else if (k === 'Delete' || k === 'Backspace') { const t = active(); if (t) remove(t) }
  else if (k === '1') setPlatform(0)
  else if (k === '2') spotifyKey()
  else if (k === '3') setPlatform(2)
  else if (k === '4') setPlatform(3)
  else return
  e.preventDefault()
})

let dragDepth = 0
const setDrop = (v) => { if (dropTarget !== v) { dropTarget = v; render() } }
window.addEventListener('dragenter', (e) => { e.preventDefault(); dragDepth++; setDrop(true) })
window.addEventListener('dragleave', () => { if (--dragDepth <= 0) { dragDepth = 0; setDrop(false) } })
window.addEventListener('dragover', (e) => e.preventDefault())
window.addEventListener('drop', (e) => {
  e.preventDefault()
  dragDepth = 0
  setDrop(false)
  const files = [...e.dataTransfer.files]
  addFiles(files.map((f) => ({ name: f.name, read: () => f.arrayBuffer() })))
})

matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => render())

render()
requestAnimationFrame(tick)
