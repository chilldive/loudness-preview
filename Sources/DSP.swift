import Foundation
import Accelerate
import AVFoundation

struct AudioData: @unchecked Sendable {
    var channels: [[Float]]
    let sampleRate: Double
    var frameCount: Int { channels.first?.count ?? 0 }
}

enum AudioLoader {
    struct LoadError: Error {}

    static func load(url: URL) throws -> AudioData {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        guard fmt.commonFormat == .pcmFormatFloat32, !fmt.isInterleaved else { throw LoadError() }
        let chunk: AVAudioFrameCount = 1 << 16
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { throw LoadError() }
        let nCh = Int(fmt.channelCount)
        var chs = [[Float]](repeating: [], count: nCh)
        for c in 0..<nCh { chs[c].reserveCapacity(Int(max(file.length, 0))) }
        while file.framePosition < file.length {
            do { try file.read(into: buf, frameCount: chunk) } catch { break }
            let n = Int(buf.frameLength)
            if n == 0 { break }
            for c in 0..<nCh { chs[c].append(contentsOf: UnsafeBufferPointer(start: buf.floatChannelData![c], count: n)) }
        }
        guard (chs.first?.count ?? 0) > 0 else { throw LoadError() }
        return AudioData(channels: chs, sampleRate: fmt.sampleRate)
    }
}

/// ITU-R BS.1770-4 / EBU R128
enum Loudness {
    static func integrated(_ chs: [[Float]], sampleRate fs: Double) -> Double {
        let nCh = chs.count
        guard nCh > 0 else { return -.infinity }
        let weights: [Double] = nCh == 6 ? [1, 1, 1, 0, 1.41, 1.41]
            : nCh == 5 ? [1, 1, 1, 1.41, 1.41]
            : Array(repeating: 1, count: nCh)

        // K-weighting (pre-filter shelf + RLB high-pass), sample-rate independent design
        var f0 = 1681.974450955533
        let G = 3.999843853973347
        var Q = 0.7071752369554196
        var K = tan(.pi * f0 / fs)
        let Vh = pow(10, G / 20)
        let Vb = pow(Vh, 0.4996667741545416)
        var a0 = 1 + K / Q + K * K
        let sb0 = (Vh + Vb * K / Q + K * K) / a0
        let sb1 = 2 * (K * K - Vh) / a0
        let sb2 = (Vh - Vb * K / Q + K * K) / a0
        let sa1 = 2 * (K * K - 1) / a0
        let sa2 = (1 - K / Q + K * K) / a0

        f0 = 38.13547087602444
        Q = 0.5003270373238773
        K = tan(.pi * f0 / fs)
        a0 = 1 + K / Q + K * K
        let ha1 = 2 * (K * K - 1) / a0
        let ha2 = (1 - K / Q + K * K) / a0

        let step = Int((fs * 0.1).rounded())
        let n = chs[0].count
        let segs = n / step
        guard segs >= 4 else { return -.infinity }
        var segPower = [Double](repeating: 0, count: segs)

        for c in 0..<nCh where weights[c] > 0 {
            var z1a = 0.0, z2a = 0.0, z1b = 0.0, z2b = 0.0
            let w = weights[c]
            chs[c].withUnsafeBufferPointer { x in
                for s in 0..<segs {
                    var acc = 0.0
                    let base = s * step
                    for i in base..<(base + step) {
                        let xin = Double(x[i])
                        let y1 = sb0 * xin + z1a
                        z1a = sb1 * xin - sa1 * y1 + z2a
                        z2a = sb2 * xin - sa2 * y1
                        let y2 = y1 + z1b
                        z1b = -2 * y1 - ha1 * y2 + z2b
                        z2b = y1 - ha2 * y2
                        acc += y2 * y2
                    }
                    segPower[s] += w * acc
                }
            }
        }

        // 400 ms blocks, 75 % overlap
        let blockLen = Double(step * 4)
        var blocks = [Double]()
        blocks.reserveCapacity(segs)
        for b in 0...(segs - 4) {
            blocks.append((segPower[b] + segPower[b + 1] + segPower[b + 2] + segPower[b + 3]) / blockLen)
        }
        func lk(_ z: Double) -> Double { -0.691 + 10 * log10(z) }
        let absGated = blocks.filter { $0 > 0 && lk($0) > -70 }
        guard !absGated.isEmpty else { return -.infinity }
        let relGate = lk(absGated.reduce(0, +) / Double(absGated.count)) - 10
        let relGated = absGated.filter { lk($0) > relGate }
        guard !relGated.isEmpty else { return -.infinity }
        return lk(relGated.reduce(0, +) / Double(relGated.count))
    }

    static func samplePeak(_ chs: [[Float]]) -> Float {
        var peak: Float = 0
        for ch in chs {
            var m: Float = 0
            vDSP_maxmgv(ch, 1, &m, vDSP_Length(ch.count))
            peak = max(peak, m)
        }
        return peak
    }

    /// True peak (linear) via polyphase oversampling (4x below 96 kHz, 2x up to 96 kHz).
    static func truePeak(_ chs: [[Float]], sampleRate fs: Double) -> Float {
        var peak = samplePeak(chs)
        let L = fs < 96000 ? 4 : (fs < 192000 ? 2 : 1)
        guard L > 1 else { return peak }

        let T = 48                 // taps per phase
        let total = T * L
        let beta = 8.0
        func i0(_ x: Double) -> Double {
            var sum = 1.0, term = 1.0, k = 1.0
            while term > 1e-12 * sum {
                term *= (x / (2 * k)) * (x / (2 * k)); sum += term; k += 1
            }
            return sum
        }
        let center = Double(total) / 2
        let denom = i0(beta)
        var phases = [[Float]](repeating: [Float](repeating: 0, count: T), count: L)
        for k in 0..<total {
            let t = (Double(k) - center) / Double(L)
            let sinc = t == 0 ? 1.0 : sin(.pi * t) / (.pi * t)
            let r = (Double(k) - center) / center
            let win = abs(r) <= 1 ? i0(beta * sqrt(1 - r * r)) / denom : 0
            phases[k % L][k / L] = Float(sinc * win)
        }
        // normalize each phase to unity DC gain
        for p in 0..<L {
            let s = phases[p].reduce(0, +)
            if s != 0 { phases[p] = phases[p].map { $0 / s } }
        }

        for ch in chs {
            let n = ch.count
            var padded = [Float](repeating: 0, count: n + 2 * (T - 1))
            padded.withUnsafeMutableBufferPointer { dst in
                ch.withUnsafeBufferPointer { src in
                    (dst.baseAddress! + (T - 1)).update(from: src.baseAddress!, count: n)
                }
            }
            let outCount = n + T - 1
            var out = [Float](repeating: 0, count: outCount)
            for p in 0..<L {
                phases[p].withUnsafeBufferPointer { f in
                    vDSP_conv(padded, 1, f.baseAddress! + (T - 1), -1, &out, 1,
                              vDSP_Length(outCount), vDSP_Length(T))
                }
                var m: Float = 0
                vDSP_maxmgv(out, 1, &m, vDSP_Length(outCount))
                peak = max(peak, m)
            }
        }
        return peak
    }
}

enum Processing {
    /// Spotify Loud-mode limiter gain curve (excluding the normalization gain itself):
    /// threshold -1 dB (sample values), 5 ms attack, 100 ms decay, stereo-linked.
    /// The attack ramp is look-ahead aligned so it completes on the peak (no overs).
    /// Returns nil when the limiter never engages.
    static func limiterEnvelope(_ chs: [[Float]], gainDB: Double, sampleRate fs: Double) -> [Float]? {
        let gain = Float(pow(10, gainDB / 20))
        let thr = Float(pow(10, -1.0 / 20))
        let n = chs.first?.count ?? 0
        let La = max(1, Int((0.005 * fs).rounded()))
        let rel = Float(exp(-1 / (0.100 * fs)))

        let m = n + La
        var req = [Float](repeating: 1, count: m)
        var engaged = false
        for i in 0..<n {
            var p: Float = 0
            for c in 0..<chs.count { p = max(p, abs(chs[c][i])) }
            p *= gain
            if p > thr { req[i + La] = thr / p; engaged = true }
        }
        guard engaged else { return nil }

        var hold = [Float](repeating: 1, count: m)
        var dq = [Int](repeating: 0, count: m + 1)
        var head = 0, tail = 0, j = 0
        for i in 0..<m {
            while j < m && j <= i + La {
                while tail > head && req[dq[tail - 1]] >= req[j] { tail -= 1 }
                dq[tail] = j; tail += 1; j += 1
            }
            while dq[head] < i { head += 1 }
            hold[i] = req[dq[head]]
        }
        var g: Float = 1
        for i in 0..<m {
            let h = hold[i]
            g = h < g ? h : rel * g + (1 - rel) * h
            hold[i] = g
        }
        var env = [Float](repeating: 1, count: n)
        var window = [Float](repeating: 1, count: La + 1)
        var sum = Double(La + 1)
        for i in 0..<m {
            let k = i % (La + 1)
            sum += Double(hold[i]) - Double(window[k])
            window[k] = hold[i]
            if i >= La { env[i - La] = Float(sum / Double(La + 1)) }
        }
        return env
    }

    static func apply(_ chs: [[Float]], gain: Float, envelope: [Float]?) -> [[Float]] {
        chs.map { ch in
            var out = [Float](repeating: 0, count: ch.count)
            if let env = envelope {
                vDSP_vmul(ch, 1, env, 1, &out, 1, vDSP_Length(ch.count))
                var g = gain
                vDSP_vsmul(out, 1, &g, &out, 1, vDSP_Length(ch.count))
            } else {
                var g = gain
                vDSP_vsmul(ch, 1, &g, &out, 1, vDSP_Length(ch.count))
            }
            return out
        }
    }

    static func waveform(_ chs: [[Float]], buckets: Int) -> [Float] {
        let n = chs.first?.count ?? 0
        guard n > 0 else { return [] }
        var result = [Float](repeating: 0, count: buckets)
        for b in 0..<buckets {
            let s = b * n / buckets
            let e = max(s + 1, (b + 1) * n / buckets)
            guard s < n else { break }
            var m: Float = 0
            for ch in chs {
                ch.withUnsafeBufferPointer { p in
                    var v: Float = 0
                    vDSP_maxmgv(p.baseAddress! + s, 1, &v, vDSP_Length(min(e, n) - s))
                    m = max(m, v)
                }
            }
            result[b] = m
        }
        return result
    }

    /// Mastering-quality sample-rate conversion.
    static func resample(_ chs: [[Float]], from: Double, to: Double) -> [[Float]] {
        guard from != to, let n = chs.first?.count, n > 0 else { return chs }
        let ch = AVAudioChannelCount(chs.count)
        guard let inF = AVAudioFormat(standardFormatWithSampleRate: from, channels: ch),
              let outF = AVAudioFormat(standardFormatWithSampleRate: to, channels: ch),
              let conv = AVAudioConverter(from: inF, to: outF),
              let inBuf = AVAudioPCMBuffer(pcmFormat: inF, frameCapacity: AVAudioFrameCount(n)) else { return chs }
        conv.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        conv.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
        inBuf.frameLength = AVAudioFrameCount(n)
        for c in 0..<chs.count {
            chs[c].withUnsafeBufferPointer { inBuf.floatChannelData![c].update(from: $0.baseAddress!, count: n) }
        }
        let outCap = AVAudioFrameCount(Double(n) * to / from) + 8192
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outF, frameCapacity: outCap) else { return chs }
        var given = false
        var result = [[Float]](repeating: [], count: chs.count)
        while true {
            outBuf.frameLength = 0
            var err: NSError?
            let status = conv.convert(to: outBuf, error: &err) { _, st in
                if given { st.pointee = .endOfStream; return nil }
                given = true
                st.pointee = .haveData
                return inBuf
            }
            let got = Int(outBuf.frameLength)
            for c in 0..<chs.count {
                result[c].append(contentsOf: UnsafeBufferPointer(start: outBuf.floatChannelData![c], count: got))
            }
            if status != .haveData || got == 0 { break }
        }
        return result
    }

    /// Sample-align `x` to `ref` (codec/SRC delay) by cross-correlation, then trim/pad to ref length.
    static func align(_ x: [[Float]], to ref: [[Float]]) -> [[Float]] {
        let n = ref[0].count
        let L = 8192
        let W = 32768
        var lag = 0
        if n > W + 2 * L, x[0].count > W + 2 * L {
            func mono(_ a: [[Float]]) -> [Float] {
                var m = a[0]
                for c in 1..<a.count { vDSP_vadd(m, 1, a[c], 1, &m, 1, vDSP_Length(m.count)) }
                return m
            }
            let r = mono(ref), d = mono(x)
            // pick the most energetic window among candidates
            var best = L, bestE: Float = -1
            let span = min(n, d.count) - W - 2 * L
            for k in 0..<24 {
                let s = L + span * k / 23
                var e: Float = 0
                vDSP_svesq(Array(r[s..<(s + W)]), 1, &e, vDSP_Length(W))
                if e > bestE { bestE = e; best = s }
            }
            let seg = Array(d[(best - L)..<(best + W + L)])
            let tpl = Array(r[best..<(best + W)])
            var corr = [Float](repeating: 0, count: 2 * L + 1)
            vDSP_conv(seg, 1, tpl, 1, &corr, 1, vDSP_Length(2 * L + 1), vDSP_Length(W))
            var mx: Float = 0
            var idx: vDSP_Length = 0
            vDSP_maxvi(corr, 1, &mx, &idx, vDSP_Length(corr.count))
            lag = Int(idx) - L
        }
        return x.map { ch in
            var out = [Float](repeating: 0, count: n)
            let s = max(0, lag), d0 = max(0, -lag)
            let count = max(0, min(n - d0, ch.count - s))
            if count > 0 {
                out.withUnsafeMutableBufferPointer { o in
                    ch.withUnsafeBufferPointer { i in
                        (o.baseAddress! + d0).update(from: i.baseAddress! + s, count: count)
                    }
                }
            }
            return out
        }
    }
}
