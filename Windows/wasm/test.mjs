// node test.mjs — exercises every lpcore.js function; compares DSP with the Swift app when swiftc exists.
import { load } from './lpcore.js';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const lp = await load();
let failed = 0;
const db = (v) => 20 * Math.log10(v);
function check(name, ok, detail) {
    console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${detail ? '  ' + detail : ''}`);
    if (!ok) failed++;
}
function time(label, fn) {
    const t = performance.now();
    const r = fn();
    console.log(`     ${label}: ${((performance.now() - t) / 1000).toFixed(2)} s`);
    return r;
}

// Music-like stereo test signal: chords (saw), bass, kick, hats, snare noise, with sections.
function music(seconds, fs, seed = 1) {
    const n = Math.round(seconds * fs);
    const L = new Float32Array(n), R = new Float32Array(n);
    let s = seed >>> 0;
    const rnd = () => ((s = (Math.imul(s, 1664525) + 1013904223) >>> 0) / 4294967296) * 2 - 1;
    const beat = 60 / 124, roots = [55, 43.65, 49, 41.2];
    let lpL = 0, lpR = 0;
    for (let i = 0; i < n; i++) {
        const t = i / fs, bar = Math.floor(t / (beat * 4)), b = t % beat;
        const sec = Math.floor(bar / 8) % 4, energy = [0.35, 0.7, 1, 0.5][sec];
        const root = roots[bar % 4];
        const kick = sec === 0 ? 0 : Math.sin(2 * Math.PI * (50 * b + (400 * (1 - Math.exp(-b * 30))) / 30)) * Math.exp(-b * 8);
        const bass = Math.sin(2 * Math.PI * root * t) * 0.5;
        let pad = 0;
        [1, 1.5, 2, 2.52, 3.01].forEach((m, k) => { pad += ((root * 4 * m * t + k * 0.3) % 1) * 2 - 1; });
        lpL += 0.15 * (pad * 0.12 - lpL); lpR += 0.13 * (pad * 0.12 - lpR);
        const hb = t % (beat / 2), hat = rnd() * Math.exp(-hb * 50) * 0.25;
        const st = (t + beat) % (beat * 2), snare = rnd() * Math.exp(-st * 15) * 0.4;
        const fade = Math.min(1, t / 0.5, (seconds - t) / 0.5);
        const l = (kick * 0.8 + bass + lpL * 1.3 + hat * 0.8 + snare) * energy;
        const r = (kick * 0.8 + bass + lpR * 1.3 + hat * 1.1 + snare * 0.9) * energy;
        L[i] = Math.tanh(l * 1.6) * 0.8 * fade; R[i] = Math.tanh(r * 1.6) * 0.8 * fade;
    }
    return [L, R];
}
function snr(ref, x) {
    let s = 0, e = 0;
    for (let c = 0; c < ref.length; c++) for (let i = 0; i < ref[c].length; i++) {
        s += ref[c][i] ** 2; e += (ref[c][i] - x[c][i]) ** 2;
    }
    return 10 * Math.log10(s / e);
}

// --- Known values -----------------------------------------------------------------------
{
    const fs = 48000, n = fs * 10;
    const sine = (f, a, ph = 0) => Float32Array.from({ length: n }, (_, i) => a * Math.sin(2 * Math.PI * f * i / fs + ph));
    const s23 = [sine(1000, 10 ** (-23 / 20)), sine(1000, 10 ** (-23 / 20))];
    const l = lp.integrated(s23, fs);
    check('LUFS 1 kHz −23 dBFS stereo = −23.0', Math.abs(l + 23) < 0.05, l.toFixed(3));
    const s441 = lp.resample(s23, 48000, 44100);
    const l441 = lp.integrated(s441, 44100);
    check('LUFS at 44.1 kHz after SRC = −23.0', Math.abs(l441 + 23) < 0.05, l441.toFixed(3));
    const tpSig = [sine(12000, 0.5, Math.PI / 4)];
    const sp = lp.samplePeak(tpSig), tp = lp.truePeak(tpSig, fs);
    check('sample peak fs/4 @45° = −9.03 dBFS', Math.abs(db(sp) + 9.03) < 0.01, db(sp).toFixed(3));
    // Same filter as DSP.swift: reads ~+0.09 dB high on this worst-case 12 kHz tone (BS.1770 allows more).
    check('true peak fs/4 @45° = −6.02 dBTP (±0.1)', Math.abs(db(tp) + 6.02) < 0.1, db(tp).toFixed(3));
    const sweep = [Float32Array.from({ length: n }, (_, i) => { const t = i / fs; return 0.5 * Math.sin(2 * Math.PI * (20 * t + (18000 - 20) * t * t / 20)); })];
    const sw = lp.resample(lp.resample(sweep, 48000, 44100), 44100, 48000);
    const swSnr = snr(sweep.map((c) => c.subarray(4800, -4800)), sw.map((c) => c.subarray(4800, -4800)));
    check('resample 48→44.1→48 sweep 20 Hz–18 kHz SNR > 80 dB', swSnr > 80, `${swSnr.toFixed(1)} dB`);
    const wf = lp.waveform(s23, 100);
    check('waveform buckets', wf.length === 100 && Math.abs(wf[50] - 10 ** (-23 / 20)) < 1e-3);
}

// --- Full-length song: codecs, alignment, timings -------------------------------------------
const fs = 48000;
const song = time('generate 4-min stereo 48 kHz', () => music(240, fs));
const lufs = time('integrated', () => lp.integrated(song, fs));
const tp = time('truePeak', () => lp.truePeak(song, fs));
console.log(`     song: ${lufs.toFixed(2)} LUFS, ${db(tp).toFixed(2)} dBTP`);

const s441 = time('resample 48k→44.1k', () => lp.resample(song, 48000, 44100));
const back = lp.resample(s441, 44100, 48000);
check('resample roundtrip aligned (lag 0)', lp.alignLag(back, song) === 0, `lag ${lp.alignLag(back, song)}`);
check('resample length', s441[0].length === Math.round(song[0].length * 44100 / 48000));

const ref441 = s441;
const kbps = (bytes, n, rate) => (bytes * 8 / (n / rate) / 1000).toFixed(0);
const jobs = [
    ['Ogg 96 (q0.2)', () => lp.vorbis(ref441, 44100, 0.2), ref441, 44100],
    ['Ogg 160 (q0.5)', () => lp.vorbis(ref441, 44100, 0.5), ref441, 44100],
    ['Ogg 320 (q0.9)', () => lp.vorbis(ref441, 44100, 0.9), ref441, 44100],
    ['Opus 64', () => lp.opus(song, 64000), song, 48000],
    ['Opus 128', () => lp.opus(song, 128000), song, 48000],
    ['AAC 128', () => lp.aac(ref441, 44100, 128000), ref441, 44100],
    ['AAC 160', () => lp.aac(ref441, 44100, 160000), ref441, 44100],
    ['AAC 256', () => lp.aac(ref441, 44100, 256000), ref441, 44100],
];
const expect = { 'Ogg 96 (q0.2)': 18, 'Ogg 160 (q0.5)': 22, 'Ogg 320 (q0.9)': 30, 'Opus 64': 10, 'Opus 128': 15,
    'AAC 128': 18, 'AAC 160': 20, 'AAC 256': 25 };
for (const [name, fn, ref, rate] of jobs) {
    const r = time(name, fn);
    const lag = lp.alignLag(r.channels, ref);
    const s = snr(ref, lp.align(r.channels, ref));
    const pk = db(lp.truePeak(r.channels, rate));
    check(`${name}: len ok, lag ${lag}, SNR ${s.toFixed(1)} dB, ${kbps(r.bytes, ref[0].length, rate)} kbps, ${pk.toFixed(2)} dBTP`,
        r.channels[0].length === ref[0].length && Math.abs(lag) <= (name.startsWith('Ogg') ? 0 : 0) && s > expect[name]);
}
// AAC mono + headroom above 0 dBFS survives
{
    const hot = [ref441[0].map((v) => v * 1.4)];
    const r = lp.aac(hot, 44100, 160000);
    check('AAC keeps overs above 0 dBFS', lp.samplePeak(r.channels) > 1.2, `peak ${db(lp.samplePeak(r.channels)).toFixed(2)} dBFS`);
}

// Limiter: +6 dB on a song peaking near 0 dBFS → output ≤ −1 dBFS
{
    const g = 6;
    const env = time('limiterEnvelope', () => lp.limiterEnvelope(song, g, fs));
    let pk = 0;
    const gl = 10 ** (g / 20);
    for (const ch of song) for (let i = 0; i < ch.length; i++) pk = Math.max(pk, Math.abs(ch[i] * env[i] * gl));
    check('limiter output ≤ −1 dBFS', db(pk) <= -0.999, `${db(pk).toFixed(3)} dBFS`);
    check('limiter null when not engaged', lp.limiterEnvelope(song, -20, fs) === null);
}

// --- Compare DSP with Sources/DSP.swift ----------------------------------------------------
const swiftSrc = join(here, '../../Sources/DSP.swift');
let hasSwift = false;
try { execFileSync('swiftc', ['--version'], { stdio: 'ignore' }); hasSwift = existsSync(swiftSrc); } catch {}
if (hasSwift) {
    const dir = mkdtempSync(join(tmpdir(), 'lpcmp-'));
    try {
        const bin = join(dir, 'compare');
        execFileSync('swiftc', ['-O', '-parse-as-library', join(here, 'compare.swift'), swiftSrc, '-o', bin], { stdio: 'ignore' });
        for (const [rate, sig] of [[48000, song.map((c) => c.subarray(0, 48000 * 60))], [44100, s441.map((c) => c.subarray(0, 44100 * 60))]]) {
            const shift = 1234;
            const xs = sig.map((c) => { const o = new Float32Array(c.length + shift); o.set(c, shift); return o; });
            sig.forEach((c, i) => writeFileSync(join(dir, `ch${i}.f32`), Buffer.from(c.slice().buffer)));
            xs.forEach((c, i) => writeFileSync(join(dir, `x${i}.f32`), Buffer.from(c.buffer)));
            const ref = JSON.parse(execFileSync(bin, [dir, String(sig.length), String(rate), '6']).toString());
            const env = lp.limiterEnvelope(sig, 6, rate);
            let envMin = 1, envSum = 0;
            for (const v of env) { envMin = Math.min(envMin, v); envSum += v; }
            const wfSum = lp.waveform(sig, 1000).reduce((a, b) => a + b, 0);
            const ours = { lufs: lp.integrated(sig, rate), samplePeak: lp.samplePeak(sig), truePeak: lp.truePeak(sig, rate), lag: lp.alignLag(xs, sig) };
            check(`[${rate}] LUFS matches Swift`, Math.abs(ours.lufs - ref.lufs) < 0.01, `${ours.lufs.toFixed(4)} vs ${ref.lufs.toFixed(4)}`);
            check(`[${rate}] sample peak matches Swift`, Math.abs(db(ours.samplePeak) - db(ref.samplePeak)) < 0.001);
            check(`[${rate}] true peak matches Swift`, Math.abs(db(ours.truePeak) - db(ref.truePeak)) < 0.01, `${db(ours.truePeak).toFixed(4)} vs ${db(ref.truePeak).toFixed(4)}`);
            check(`[${rate}] limiter envelope matches Swift`, Math.abs(envMin - ref.envMin) < 1e-5 && Math.abs(envSum - ref.envSum) / ref.envSum < 1e-6,
                `min ${envMin.toFixed(6)} vs ${ref.envMin.toFixed(6)}`);
            check(`[${rate}] waveform matches Swift`, Math.abs(wfSum - ref.wfSum) < 1e-3);
            check(`[${rate}] align lag matches Swift`, ours.lag === shift && ref.lag === shift, `${ours.lag} vs ${ref.lag}`);
        }
    } finally { rmSync(dir, { recursive: true, force: true }); }
} else console.log('     (swiftc not found: skipped Swift comparison)');

console.log(failed ? `\n${failed} FAILED` : '\nall passed');
process.exit(failed ? 1 : 0);
