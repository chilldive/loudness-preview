// Reference values from Sources/DSP.swift for test.mjs. Args: <dir> <channels> <rate> <gainDB>
import Foundation
@main struct Compare {
    static func read(_ p: String) -> [Float] {
        let d = FileManager.default.contents(atPath: p)!
        return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
    static func main() {
        let a = CommandLine.arguments
        let dir = a[1], nCh = Int(a[2])!, fs = Double(a[3])!, g = Double(a[4])!
        let chs = (0..<nCh).map { read("\(dir)/ch\($0).f32") }
        let xs = (0..<nCh).map { read("\(dir)/x\($0).f32") }
        let lufs = Loudness.integrated(chs, sampleRate: fs)
        let sp = Loudness.samplePeak(chs)
        let tp = Loudness.truePeak(chs, sampleRate: fs)
        let env = Processing.limiterEnvelope(chs, gainDB: g, sampleRate: fs)
        let wf = Processing.waveform(chs, buckets: 1000)
        let al = Processing.align(xs, to: chs)
        // recover lag: first index where aligned equals some shifted source
        var lag = 0
        for l in -9000...9000 {
            let i = 100000
            if i + l >= 0, i + l < xs[0].count, al[0][i] == xs[0][i + l], al[0][i + 1] == xs[0][i + l + 1], al[0][i+7] == xs[0][i+l+7] { lag = l; break }
        }
        let envMin = env?.min() ?? 1
        let envSum = env.map { $0.reduce(0.0) { $0 + Double($1) } } ?? -1
        let wfSum = wf.reduce(0.0) { $0 + Double($1) }
        print("{\"lufs\":\(lufs),\"samplePeak\":\(sp),\"truePeak\":\(tp),\"envMin\":\(envMin),\"envSum\":\(envSum),\"wfSum\":\(wfSum),\"lag\":\(lag)}")
    }
}
