// Loader for lpcore.wasm. Works in Node (ESM) and in browser/Electron Web Workers.
// Channels are passed and returned as planar Float32Array[]; every call frees its wasm memory.

const isNode = typeof process !== 'undefined' && !!process.versions?.node && typeof window === 'undefined'
    && typeof WorkerGlobalScope === 'undefined';

export async function compile(source) {
    if (source instanceof WebAssembly.Module) return source;
    if (source) return WebAssembly.compile(source);
    const url = new URL('./lpcore.wasm', import.meta.url);
    if (isNode) {
        const { readFile } = await import('node:fs/promises');
        return WebAssembly.compile(await readFile(url));
    }
    return WebAssembly.compileStreaming
        ? WebAssembly.compileStreaming(fetch(url))
        : WebAssembly.compile(await (await fetch(url)).arrayBuffer());
}

/** load(source?) → API. `source`: WebAssembly.Module (share one across workers), bytes, or nothing. */
export async function load(source) {
    const module = await compile(source);
    let mem;
    const wasi = {
        fd_write(fd, iovs, iovsLen, nwritten) {
            const dv = new DataView(mem.buffer);
            let n = 0;
            for (let i = 0; i < iovsLen; i++) n += dv.getUint32(iovs + i * 8 + 4, true);
            dv.setUint32(nwritten, n, true);
            return 0;
        },
        proc_exit(code) { throw new Error(`lpcore exited (${code})`); },
    };
    const imports = {
        wasi_snapshot_preview1: new Proxy(wasi, { get: (t, k) => t[k] ?? (() => 0) }),
    };
    const inst = await WebAssembly.instantiate(module, imports);
    const x = inst.exports;
    mem = x.memory;
    x._initialize?.();

    const f32 = () => new Float32Array(mem.buffer);
    const u32 = () => new Uint32Array(mem.buffer);
    const i32 = () => new Int32Array(mem.buffer);
    const alloc = (bytes) => {
        const p = x.lp_malloc(bytes) >>> 0;
        if (!p) throw new Error('lpcore: out of memory');
        return p;
    };

    // Copy planar channels into wasm memory; returns pointer to `const float *const *`.
    function put(chs) {
        const tbl = alloc(4 * chs.length);
        const ptrs = chs.map((ch) => {
            const p = alloc(4 * ch.length || 4);
            f32().set(ch, p >>> 2);
            return p;
        });
        u32().set(ptrs, tbl >>> 2);
        return { tbl, free() { ptrs.forEach(x.lp_free); x.lp_free(tbl); } };
    }
    function take(block, nCh, frames) {
        const view = f32();
        const out = [];
        for (let c = 0; c < nCh; c++) out.push(view.slice((block >>> 2) + c * frames, (block >>> 2) + (c + 1) * frames));
        x.lp_free(block);
        return out;
    }
    const frames = (chs) => chs[0]?.length ?? 0;

    // Runs a roundtrip-style C call: fn(tbl, scratch) where scratch holds out, out_frames, bytes.
    function roundtrip(chs, call) {
        const inp = put(chs);
        const s = alloc(12);
        try {
            const rc = call(inp.tbl, s, s + 4, s + 8);
            if (rc !== 0) throw new Error('lpcore: codec failed');
            const v = i32();
            const block = v[s >>> 2] >>> 0, n = v[(s + 4) >>> 2], bytes = v[(s + 8) >>> 2];
            return { channels: take(block, chs.length, n), bytes };
        } finally { inp.free(); x.lp_free(s); }
    }
    function scalar(chs, call) {
        const inp = put(chs);
        try { return call(inp.tbl); } finally { inp.free(); }
    }

    const api = {
        module,
        /** Ogg Vorbis VBR roundtrip. quality −0.1…1 (0.2≈96k, 0.5≈160k, 0.9≈320k). */
        vorbis: (chs, rate, quality) => roundtrip(chs, (t, o, n, b) =>
            x.lp_vorbis_roundtrip(t, chs.length, frames(chs), rate, quality, o, n, b)),
        /** Opus VBR roundtrip; input must be 48 kHz. bitrate in bit/s. */
        opus: (chs, bitrate) => roundtrip(chs, (t, o, n, b) =>
            x.lp_opus_roundtrip(t, chs.length, frames(chs), bitrate, o, n, b)),
        /** AAC-LC CBR roundtrip (fdk-aac); 1–2 channels. bitrate in bit/s. */
        aac: (chs, rate, bitrate) => roundtrip(chs, (t, o, n, b) =>
            x.lp_aac_roundtrip(t, chs.length, frames(chs), rate, bitrate, o, n, b)),
        /** Time-aligned SRC (speex quality 10); output length round(n*to/from). */
        resample(chs, from, to) {
            if (from === to) return chs.map((c) => c.slice());
            const inp = put(chs);
            const s = alloc(8);
            try {
                if (x.lp_resample(inp.tbl, chs.length, frames(chs), from, to, s, s + 4) !== 0) throw new Error('lpcore: resample failed');
                const v = i32();
                return take(v[s >>> 2] >>> 0, chs.length, v[(s + 4) >>> 2]);
            } finally { inp.free(); x.lp_free(s); }
        },
        /** Integrated loudness, LUFS (−Infinity when silent/too short). */
        integrated: (chs, rate) => scalar(chs, (t) => x.lp_integrated(t, chs.length, frames(chs), rate)),
        /** Linear sample peak. */
        samplePeak: (chs) => scalar(chs, (t) => x.lp_sample_peak(t, chs.length, frames(chs))),
        /** Linear true peak (4x below 96 kHz, 2x below 192 kHz). */
        truePeak: (chs, rate) => scalar(chs, (t) => x.lp_true_peak(t, chs.length, frames(chs), rate)),
        /** Spotify Loud limiter gain curve for gainDB of make-up gain, or null if it never engages. */
        limiterEnvelope(chs, gainDB, rate) {
            const n = frames(chs);
            return scalar(chs, (t) => {
                const p = x.lp_limiter_envelope(t, chs.length, n, gainDB, rate) >>> 0;
                if (!p) return null;
                const env = f32().slice(p >>> 2, (p >>> 2) + n);
                x.lp_free(p);
                return env;
            });
        },
        /** Max-abs per bucket across channels. */
        waveform(chs, buckets) {
            const out = alloc(4 * buckets);
            try {
                scalar(chs, (t) => x.lp_waveform(t, chs.length, frames(chs), buckets, out));
                return f32().slice(out >>> 2, (out >>> 2) + buckets);
            } finally { x.lp_free(out); }
        },
        /** Lag (frames) of x relative to ref; positive = x is late. */
        alignLag(xs, ref) {
            const a = put(xs), r = put(ref);
            try { return x.lp_align_lag(a.tbl, xs.length, frames(xs), r.tbl, ref.length, frames(ref)); }
            finally { a.free(); r.free(); }
        },
        /** Sample-align x to ref by cross-correlation, trimmed/padded to ref's length. */
        align(xs, ref) {
            const lag = api.alignLag(xs, ref);
            const n = frames(ref);
            return xs.map((ch) => {
                const out = new Float32Array(n);
                const s = Math.max(0, lag), d0 = Math.max(0, -lag);
                const count = Math.max(0, Math.min(n - d0, ch.length - s));
                if (count > 0) out.set(ch.subarray(s, s + count), d0);
                return out;
            });
        },
    };
    return api;
}
