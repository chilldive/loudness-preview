// Real-time renderer: port of RenderCore (Sources/Engine.swift).
// All versions are sample-aligned at the context rate; switching crossfades 12 ms, play/pause ramps 6 ms.

class Renderer extends AudioWorkletProcessor {
  constructor(options) {
    super()
    this.state = new Int32Array(options.processorOptions.state) // [position, endCount]
    this.tracks = new Map()
    this.playing = false
    this.cur = null
    this.prev = null
    this.fade = 0
    this.level = 0
    this.fadeLength = Math.max(1, Math.round(sampleRate * 0.012))
    this.levelStep = 1 / (sampleRate * 0.006)
    this.port.onmessage = (e) => this.message(e.data)
  }

  message(m) {
    if (m.type === 'add') {
      this.tracks.set(m.id, m)
    } else if (m.type === 'remove') {
      this.tracks.delete(m.id)
      if (this.prev && this.prev.track.id === m.id) this.prev = null
      if (this.cur && this.cur.track.id === m.id) this.cur = null
    } else if (m.type === 'control') {
      this.playing = m.playing
      const r = m.route
      const track = r && this.tracks.get(r.id)
      if (track) {
        const route = { codec: r.codec, gain: r.gain, limiter: r.limiter }
        const pos = m.seek != null ? m.seek : (this.cur && this.cur.track === track ? this.cur.pos : 0)
        const old = this.cur
        if (old && this.level > 0 && (old.track !== track || old.route.codec !== route.codec ||
            old.route.gain !== route.gain || old.route.limiter !== route.limiter || old.pos !== pos)) {
          this.prev = old
          this.fade = this.fadeLength
        }
        this.cur = { track, route, pos }
      } else {
        this.cur = null
        this.prev = null
      }
    }
  }

  static sample(v, ch) {
    const t = v.track
    if (v.pos < 0 || v.pos >= t.frames) return 0
    const ver = t.versions[v.route.codec] || t.versions[0]
    let x = ver[Math.min(ch, ver.length - 1)][v.pos] * v.route.gain
    if (v.route.limiter) {
      const env = t.envelopes[v.route.codec]
      if (env) x *= env[v.pos]
    }
    return x
  }

  process(_inputs, outputs) {
    const out = outputs[0]
    const n = out[0].length
    const v = this.cur
    if (!v) { for (const o of out) o.fill(0); return true }
    for (let i = 0; i < n; i++) {
      const target = this.playing ? 1 : 0
      if (this.level < target) this.level = Math.min(target, this.level + this.levelStep)
      else if (this.level > target) this.level = Math.max(target, this.level - this.levelStep)
      if (this.level === 0 && !this.playing) {
        for (const o of out) o.fill(0, i)
        break
      }
      const p = this.prev
      if (this.fade > 0 && p) {
        const w = 1 - this.fade / this.fadeLength
        this.fade--
        for (let c = 0; c < out.length; c++) out[c][i] = (Renderer.sample(v, c) * w + Renderer.sample(p, c) * (1 - w)) * this.level
        p.pos++
      } else {
        this.prev = null
        for (let c = 0; c < out.length; c++) out[c][i] = Renderer.sample(v, c) * this.level
      }
      if (this.playing) {
        v.pos++
        if (v.pos >= v.track.frames) {
          this.playing = false
          Atomics.add(this.state, 1, 1)
        }
      }
    }
    Atomics.store(this.state, 0, v.pos)
    return true
  }
}

registerProcessor('lp-renderer', Renderer)
