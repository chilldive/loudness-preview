import Foundation
func sine(_ f: Double, _ dbfs: Double, _ secs: Double, _ fs: Double, phase: Double = 0) -> [Float] {
    let a = pow(10, dbfs/20); let n = Int(secs*fs)
    return (0..<n).map { Float(a*sin(2 * .pi * f * Double($0)/fs + phase)) }
}
for fs in [44100.0, 48000.0, 96000.0] {
    let s = sine(1000, -23, 20, fs)
    print(fs, "1k -23dBFS stereo:", Loudness.integrated([s,s], sampleRate: fs))
    let g = sine(1000,-36,10,fs)+sine(1000,-23,60,fs)+sine(1000,-36,10,fs)
    print(fs, "EBU3341 #3 (-23 expected):", Loudness.integrated([g,g], sampleRate: fs))
    let g4 = sine(1000,-72,10,fs)+sine(1000,-36,10,fs)+sine(1000,-23,10,fs)+sine(1000,-36,10,fs)+sine(1000,-72,10,fs)
    print(fs, "EBU3341 #4 (-23 expected):", Loudness.integrated([g4,g4], sampleRate: fs))
}
let fs = 48000.0
let t = sine(12000, 0, 2, fs, phase: .pi/4)
print("TP fs/4 45deg (0 dBTP expected):", 20*log10(Loudness.truePeak([t,t], sampleRate: fs)), "sample:", 20*log10(Loudness.samplePeak([t])))
let t2 = sine(19000, -6, 2, fs, phase: 0.3)
print("TP 19k -6 (≈-6):", 20*log10(Loudness.truePeak([t2], sampleRate: fs)))
let quiet = sine(1000, -20, 10, fs)
let start = Date()
let (out, eng) = Processing.spotifyLimited([quiet,quiet], gainDB: 25, sampleRate: fs)
print("limiter engaged", eng, "peak dB", 20*log10(Loudness.samplePeak(out)), "time", Date().timeIntervalSince(start))
let big = (0..<(48000*240)).map { _ in Float.random(in: -0.5...0.5) }
let t0 = Date(); _ = Loudness.integrated([big,big], sampleRate: fs); let t1 = Date(); _ = Loudness.truePeak([big,big], sampleRate: fs)
print("4min stereo: lufs", t1.timeIntervalSince(t0), "s, tp", Date().timeIntervalSince(t1), "s")
let q2 = sine(1000, -20, 1, fs)
let (o2, _) = Processing.spotifyLimited([q2], gainDB: 25, sampleRate: fs)
var worst = 0; for i in 0..<o2[0].count where abs(o2[0][i]) > 0.8913 { worst = i; break }
print("first over at", worst, o2[0][worst], "max", o2[0].map{abs($0)}.max()!)
