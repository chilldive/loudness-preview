// Processing worker: decoding, analysis and codec round-trips on the WebAssembly core.
import { load } from './lpcore.js'
import { CODECS } from './codecs.js'

let core = null
const ready = load().then((x) => { core = x })

const shared = (n) => new Float32Array(new SharedArrayBuffer(Math.max(1, n) * 4))
const toShared = (chs) => chs.map((c) => {
  if (c.buffer instanceof SharedArrayBuffer) return c
  const s = shared(c.length)
  s.set(c)
  return s
})
const db = (x) => 20 * Math.log10(Math.max(x, 1e-10))

// MARK: PCM file parsing (WAV / AIFF); other formats are decoded by the browser

function parseWAV(buf) {
  const d = new DataView(buf)
  const tag = (o) => String.fromCharCode(d.getUint8(o), d.getUint8(o + 1), d.getUint8(o + 2), d.getUint8(o + 3))
  if (buf.byteLength < 12 || !['RIFF', 'RF64'].includes(tag(0)) || tag(8) !== 'WAVE') return null
  let o = 12, fmt = null, data = null, ds64 = 0
  while (o + 8 <= buf.byteLength) {
    const id = tag(o)
    let size = d.getUint32(o + 4, true)
    if (id === 'ds64') ds64 = Number(d.getBigUint64(o + 16, true))
    if (id === 'data' && size === 0xFFFFFFFF && ds64) size = ds64
    if (id === 'fmt ') {
      let format = d.getUint16(o + 8, true)
      const channels = d.getUint16(o + 10, true)
      const rate = d.getUint32(o + 12, true)
      const bits = d.getUint16(o + 22, true)
      if (format === 0xFFFE && size >= 40) format = d.getUint16(o + 32, true)
      fmt = { format, channels, rate, bits }
    } else if (id === 'data') {
      data = { offset: o + 8, size: Math.min(size, buf.byteLength - o - 8) }
      if (fmt) break
    }
    o += 8 + size + (size & 1)
  }
  if (!fmt || !data) return null
  return pcm(d, data.offset, data.size, fmt.channels, fmt.rate, fmt.bits, fmt.format === 3, true)
}

function parseAIFF(buf) {
  const d = new DataView(buf)
  const tag = (o) => String.fromCharCode(d.getUint8(o), d.getUint8(o + 1), d.getUint8(o + 2), d.getUint8(o + 3))
  if (buf.byteLength < 12 || tag(0) !== 'FORM' || !['AIFF', 'AIFC'].includes(tag(8))) return null
  let o = 12, comm = null, ssnd = null
  while (o + 8 <= buf.byteLength) {
    const id = tag(o)
    const size = d.getUint32(o + 4, false)
    if (id === 'COMM') {
      const channels = d.getUint16(o + 8, false)
      const bits = d.getUint16(o + 14, false)
      // 80-bit extended sample rate
      const exp = d.getUint16(o + 16, false) & 0x7FFF
      const hi = d.getUint32(o + 18, false), lo = d.getUint32(o + 22, false)
      const rate = Math.round((hi * 2 ** 32 + lo) * 2 ** (exp - 16383 - 63))
      let comp = 'NONE'
      if (tag(8) === 'AIFC' && size >= 22) comp = tag(o + 26)
      comm = { channels, bits, rate, comp }
    } else if (id === 'SSND') {
      const off = d.getUint32(o + 8, false)
      ssnd = { offset: o + 16 + off, size: Math.min(size - 8 - off, buf.byteLength - o - 16 - off) }
    }
    o += 8 + size + (size & 1)
  }
  if (!comm || !ssnd) return null
  const c = comm.comp
  if (c === 'NONE' || c === 'twos') return pcm(d, ssnd.offset, ssnd.size, comm.channels, comm.rate, comm.bits, false, false)
  if (c === 'sowt') return pcm(d, ssnd.offset, ssnd.size, comm.channels, comm.rate, comm.bits, false, true)
  if (c === 'fl32' || c === 'FL32') return pcm(d, ssnd.offset, ssnd.size, comm.channels, comm.rate, 32, true, false)
  if (c === 'fl64' || c === 'FL64') return pcm(d, ssnd.offset, ssnd.size, comm.channels, comm.rate, 64, true, false)
  return null
}

function pcm(d, offset, size, nch, rate, bits, float, le) {
  const bps = Math.ceil(bits / 8)
  const frames = Math.floor(size / (bps * nch))
  if (!frames || !rate || !nch) return null
  const chs = Array.from({ length: nch }, () => shared(frames))
  let p = offset
  for (let i = 0; i < frames; i++) {
    for (let c = 0; c < nch; c++) {
      let v
      if (float) v = bps === 8 ? d.getFloat64(p, le) : d.getFloat32(p, le)
      else if (bps === 1) v = (d.getUint8(p) - 128) / 128
      else if (bps === 2) v = d.getInt16(p, le) / 32768
      else if (bps === 3) {
        const b0 = d.getUint8(p), b1 = d.getUint8(p + 1), b2 = d.getUint8(p + 2)
        let x = le ? (b0 | (b1 << 8) | (b2 << 16)) : (b2 | (b1 << 8) | (b0 << 16))
        if (x & 0x800000) x -= 0x1000000
        v = x / 8388608
      } else v = d.getInt32(p, le) / 2147483648
      chs[c][i] = v
      p += bps
    }
  }
  return { rate, channels: chs }
}

// MARK: ops

function roundtrip(codec, chs, rate) {
  const c = CODECS[codec]
  if (c.kind === 'vorbis') {
    const x = rate === 44100 ? chs : core.resample(chs, rate, 44100)
    return { chs: core.vorbis(x, 44100, c.q).channels, rate: 44100 }
  }
  if (c.kind === 'opus') {
    const x = rate === 48000 ? chs : core.resample(chs, rate, 48000)
    return { chs: core.opus(x, c.bitrate).channels, rate: 48000 }
  }
  if (c.kind === 'aac') {
    const x = rate === 44100 ? chs : core.resample(chs, rate, 44100)
    return { chs: core.aac(x, 44100, c.bitrate).channels, rate: 44100 }
  }
  return { chs, rate }
}

const ops = {
  decode({ buffer }) {
    const r = parseWAV(buffer) || parseAIFF(buffer)
    return r
  },

  analyze({ chs, rate, playRate }) {
    const lufs = core.integrated(chs, rate)
    const tp = db(core.truePeak(chs, rate))
    const base = rate === playRate ? chs : core.resample(chs, rate, playRate)
    return { lufs, tp, base: toShared(base) }
  },

  waveform({ chs, buckets }) {
    return core.waveform(chs, buckets)
  },

  codec({ codec, chs, rate, playRate, base }) {
    const r = roundtrip(codec, chs, rate)
    const atPlay = r.rate === playRate ? r.chs : core.resample(r.chs, r.rate, playRate)
    return toShared(core.align(atPlay, base))
  },

  post({ v, playRate, gLoud, wave }) {
    const ctp = db(core.truePeak(v, playRate))
    let env = null, loudTP = null, loudLUFS = null, loudWave = null
    if (gLoud > 0) {
      env = core.limiterEnvelope(v, gLoud, playRate)
      if (env) {
        const g = 10 ** (gLoud / 20)
        const limited = v.map((ch) => { const o = new Float32Array(ch.length); for (let i = 0; i < ch.length; i++) o[i] = ch[i] * g * env[i]; return o })
        loudTP = db(core.truePeak(limited, playRate))
        loudLUFS = core.integrated(limited, playRate)
        if (wave) {
          const shaped = v.map((ch) => { const o = new Float32Array(ch.length); for (let i = 0; i < ch.length; i++) o[i] = ch[i] * env[i]; return o })
          loudWave = core.waveform(shaped, 1600)
        }
        env = toShared([env])[0]
      }
    }
    return { ctp, env, loudTP, loudLUFS, loudWave }
  },
}

self.onmessage = async (e) => {
  const { id, op, args } = e.data
  try {
    await ready
    const result = ops[op](args)
    self.postMessage({ id, result })
  } catch (err) {
    self.postMessage({ id, error: String(err && err.stack || err) })
  }
}
