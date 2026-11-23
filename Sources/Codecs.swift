import Foundation
import AVFoundation
import LPCodecs

enum Codec: Int, CaseIterable, Identifiable, Sendable {
    case lossless, vorbis320, vorbis160, vorbis96, opus, aac128, aac160, aac256, opus64
    var id: Int { rawValue }

    var label: String {
        switch self {
        case .lossless: "Lossless"
        case .vorbis320: "Ogg 320"
        case .vorbis160: "Ogg 160"
        case .vorbis96: "Ogg 96"
        case .opus: "Opus"
        case .aac128: "AAC 128"
        case .aac160: "AAC 160"
        case .aac256: "AAC 256"
        case .opus64: "Opus 64"
        }
    }

    static let spotify: [Codec] = [.lossless, .vorbis320, .vorbis160, .vorbis96]
    static let youtube: [Codec] = [.opus, .aac128]
    static let soundcloud: [Codec] = [.aac160, .aac256, .opus64]
}

enum CodecError: Error { case encode, decode }

enum CodecEngine {
    /// Encode → decode. Returns decoded PCM and its sample rate (not yet aligned).
    static func roundtrip(_ codec: Codec, _ chs: [[Float]], sampleRate fs: Double) throws -> ([[Float]], Double) {
        switch codec {
        case .lossless: return (chs, fs)
        // Spotify: Ogg Vorbis, 44.1 kHz. q2 ≈ 96, q5 ≈ 160, q9 ≈ 320 kbps
        case .vorbis320: return try vorbis(chs, fs: fs, quality: 0.9)
        case .vorbis160: return try vorbis(chs, fs: fs, quality: 0.5)
        case .vorbis96: return try vorbis(chs, fs: fs, quality: 0.2)
        // YouTube: itag 251 (Opus ~128 kbps, 48 kHz), itag 140 (AAC-LC 128 kbps, 44.1 kHz)
        case .opus: return try opus(chs, fs: fs, bitrate: 128_000)
        case .aac128: return try toolbox(chs, fs: fs, format: kAudioFormatMPEG4AAC, fileRate: 44100, bitrate: 128_000, ext: "m4a")
        // SoundCloud: HLS AAC 160 (standard), AAC 256 (Go+), legacy HLS Opus 64
        case .aac160: return try toolbox(chs, fs: fs, format: kAudioFormatMPEG4AAC, fileRate: 44100, bitrate: 160_000, ext: "m4a")
        case .aac256: return try toolbox(chs, fs: fs, format: kAudioFormatMPEG4AAC, fileRate: 44100, bitrate: 256_000, ext: "m4a")
        case .opus64: return try opus(chs, fs: fs, bitrate: 64_000)
        }
    }

    private typealias CRoundtrip = (UnsafePointer<UnsafePointer<Float>?>, Int32, Int,
                                    UnsafeMutablePointer<UnsafeMutablePointer<Float>?>,
                                    UnsafeMutablePointer<Int>, UnsafeMutablePointer<Int>) -> Int32

    private static func runC(_ input: [[Float]], _ fn: CRoundtrip) throws -> [[Float]] {
        let n = input[0].count
        let nCh = input.count
        let ptrs: [UnsafeMutablePointer<Float>] = input.map { ch in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
            ch.withUnsafeBufferPointer { p.initialize(from: $0.baseAddress!, count: n) }
            return p
        }
        defer { ptrs.forEach { $0.deallocate() } }
        var out: UnsafeMutablePointer<Float>?
        var outFrames = 0
        var bytes = 0
        let cptrs: [UnsafePointer<Float>?] = ptrs.map { UnsafePointer($0) }
        let rc = cptrs.withUnsafeBufferPointer { bp in
            fn(bp.baseAddress!, Int32(nCh), n, &out, &outFrames, &bytes)
        }
        guard rc == 0, let block = out else { throw CodecError.encode }
        defer { lp_free(block) }
        return (0..<nCh).map { c in Array(UnsafeBufferPointer(start: block + c * outFrames, count: outFrames)) }
    }

    private static func vorbis(_ chs: [[Float]], fs: Double, quality: Float) throws -> ([[Float]], Double) {
        let rate = 44100.0
        let input = Processing.resample(chs, from: fs, to: rate)
        let out = try runC(input) { lp_vorbis_roundtrip($0, $1, $2, Int(rate), quality, $3, $4, $5) }
        return (out, rate)
    }

    private static func opus(_ chs: [[Float]], fs: Double, bitrate: Int32) throws -> ([[Float]], Double) {
        let input = Processing.resample(chs, from: fs, to: 48000)
        let out = try runC(input) { lp_opus_roundtrip($0, $1, $2, bitrate, $3, $4, $5) }
        return (out, 48000)
    }

    private static func toolbox(_ chs: [[Float]], fs: Double, format: AudioFormatID, fileRate: Double,
                                bitrate: Int, ext: String) throws -> ([[Float]], Double) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lp-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: url) }
        let input = Processing.resample(chs, from: fs, to: fileRate)
        let n = input[0].count
        let settings: [String: Any] = [
            AVFormatIDKey: format,
            AVSampleRateKey: fileRate,
            AVNumberOfChannelsKey: input.count,
            AVEncoderBitRateKey: bitrate,
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            let chunk = 1 << 15
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                             frameCapacity: AVAudioFrameCount(chunk)) else { throw CodecError.encode }
            var pos = 0
            while pos < n {
                let len = min(chunk, n - pos)
                for c in 0..<input.count {
                    input[c].withUnsafeBufferPointer {
                        buf.floatChannelData![c].update(from: $0.baseAddress! + pos, count: len)
                    }
                }
                buf.frameLength = AVAudioFrameCount(len)
                try file.write(from: buf)
                pos += len
            }
            file.close()
        }
        let decoded = try AudioLoader.load(url: url)
        return (decoded.channels, decoded.sampleRate)
    }
}
