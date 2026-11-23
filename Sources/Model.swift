import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum Platform: Int { case original, spotify, youtube, soundcloud
    var tint: Color {
        switch self {
        case .original: .accentColor
        case .spotify: Color(red: 0.12, green: 0.80, blue: 0.38)
        case .youtube: Color(red: 1, green: 0.22, blue: 0.22)
        case .soundcloud: Color(red: 1, green: 0.42, blue: 0.0)
        }
    }
}

enum SpotifyLevel: Int, CaseIterable, Identifiable {
    case loud, normal, quiet
    var id: Int { rawValue }
    var target: Double { [-11.0, -14.0, -19.0][rawValue] }
    var label: String { ["Loud", "Normal", "Quiet"][rawValue] }
}

struct TrackInfo {
    let lufs: Double
    let truePeakDB: Double
    let sourceRate: Double
    let frames: Int
    let duration: Double
    let waveform: [Float]
    let loudWaveform: [Float]?          // with Spotify Loud limiter (lossless)
    let spotifyGain: [Double]           // per SpotifyLevel
    let youtubeGain: Double
    let soundcloudGain: Double
    let codecTP: [Double]               // decoded true peak per codec, before gain
    let loudTP: [Double?]               // after Loud gain + limiter, per codec
    let loudLUFS: [Double?]
    let limiterCodecs: Set<Int>
}

struct Setting {
    let codec: Codec
    let gainDB: Double
    let limiter: Bool
}

struct Readout {
    let gainDB: Double
    let lufs: Double
    let truePeakDB: Double
    let limited: Bool
}

@MainActor
final class Track: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    @Published var progress: Double = 0
    @Published var preview: [Float] = []
    @Published var info: TrackInfo?
    @Published var failed = false
    var audio: TrackAudio?
    var position = 0

    init(url: URL) {
        self.url = url
        self.name = url.deletingPathExtension().lastPathComponent
    }
}

private struct Processed: @unchecked Sendable {
    let info: TrackInfo
    let audio: TrackAudio
}

@MainActor
final class Model: ObservableObject {
    @Published var tracks: [Track] = []
    @Published var activeID: UUID?
    @Published var platform: Platform = .spotify { didSet { push() } }
    @Published var spotifyLevel: SpotifyLevel = .normal { didSet { push() } }
    @Published var spotifyCodec: Codec = .vorbis160 { didSet { push() } }
    @Published var youtubeCodec: Codec = .opus { didSet { push() } }
    @Published var soundcloudCodec: Codec = .aac160 { didSet { push() } }
    @Published var isPlaying = false
    @Published var time: Double = 0

    let engine = AudioEngine()
    private var ticker: Task<Void, Never>?
    private var lastEnd = 0

    static let audioTypes: [UTType] = [.audio]

    var active: Track? { tracks.first { $0.id == activeID } }

    // MARK: settings → numbers

    func setting(_ info: TrackInfo) -> Setting {
        switch platform {
        case .original:
            return Setting(codec: .lossless, gainDB: 0, limiter: false)
        case .spotify:
            let g = info.spotifyGain[spotifyLevel.rawValue]
            return Setting(codec: spotifyCodec, gainDB: g,
                           limiter: spotifyLevel == .loud && info.limiterCodecs.contains(spotifyCodec.rawValue))
        case .youtube:
            return Setting(codec: youtubeCodec, gainDB: info.youtubeGain, limiter: false)
        case .soundcloud:
            return Setting(codec: soundcloudCodec, gainDB: info.soundcloudGain, limiter: false)
        }
    }

    func readout(_ info: TrackInfo, platform p: Platform) -> Readout {
        switch p {
        case .original:
            return Readout(gainDB: 0, lufs: info.lufs, truePeakDB: info.truePeakDB, limited: false)
        case .spotify:
            let c = spotifyCodec.rawValue
            let g = info.spotifyGain[spotifyLevel.rawValue]
            if spotifyLevel == .loud, info.limiterCodecs.contains(c) {
                return Readout(gainDB: g, lufs: info.loudLUFS[c] ?? info.lufs + g,
                               truePeakDB: info.loudTP[c] ?? info.codecTP[c] + g, limited: true)
            }
            return Readout(gainDB: g, lufs: info.lufs + g, truePeakDB: info.codecTP[c] + g, limited: false)
        case .youtube:
            let g = info.youtubeGain
            return Readout(gainDB: g, lufs: info.lufs + g,
                           truePeakDB: info.codecTP[youtubeCodec.rawValue] + g, limited: false)
        case .soundcloud:
            let g = info.soundcloudGain
            return Readout(gainDB: g, lufs: info.lufs + g,
                           truePeakDB: info.codecTP[soundcloudCodec.rawValue] + g, limited: false)
        }
    }

    private func route(_ t: Track) -> Route? {
        guard let a = t.audio, let info = t.info else { return nil }
        let s = setting(info)
        return Route(audio: a, codec: s.codec.rawValue, gain: Float(pow(10, s.gainDB / 20)), limiter: s.limiter)
    }

    private func push(seek: Int? = nil) {
        let r = active.flatMap(route)
        if r == nil { isPlaying = false }
        engine.send(playing: isPlaying, route: r, seek: seek)
    }

    // MARK: files

    func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.audioTypes
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func add(_ urls: [URL]) {
        let rate = engine.sampleRate
        for url in urls {
            let t = Track(url: url)
            tracks.append(t)
            if activeID == nil { activeID = t.id }
            Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let result = try? await Self.process(url: url, playRate: rate,
                    preview: { w in Task { @MainActor in t.preview = w } },
                    progress: { p in Task { @MainActor in t.progress = p } })
                await MainActor.run {
                    guard let r = result else { t.failed = true; return }
                    t.audio = r.audio
                    t.info = r.info
                    t.progress = 1
                    self.objectWillChange.send()
                    if self.activeID == t.id { self.push(seek: t.position) }
                }
            }
        }
    }

    func remove(_ t: Track) {
        guard let i = tracks.firstIndex(where: { $0.id == t.id }) else { return }
        let wasActive = t.id == activeID
        tracks.remove(at: i)
        if wasActive {
            let next = tracks.isEmpty ? nil : tracks[min(i, tracks.count - 1)]
            activeID = next?.id
            if next == nil { isPlaying = false; stopTicker() }
            push(seek: next?.position ?? 0)
            time = Double(next?.position ?? 0) / engine.sampleRate
        }
    }

    nonisolated private static func process(url: URL, playRate: Double,
                                            preview: @escaping @Sendable ([Float]) -> Void,
                                            progress: @escaping @Sendable (Double) -> Void) async throws -> Processed {
        let src = try AudioLoader.load(url: url)
        let fs = src.sampleRate
        let chs = src.channels
        preview(Processing.waveform(chs, buckets: 1600))

        let L = Loudness.integrated(chs, sampleRate: fs)
        let tp = 20 * log10(Double(max(Loudness.truePeak(chs, sampleRate: fs), 1e-10)))
        let base = Processing.resample(chs, from: fs, to: playRate)
        let frames = base[0].count

        // Spotify: Normal/Quiet raise only up to -1 dBTP; Loud raises through the limiter
        let finite = L.isFinite
        let spotifyGain: [Double] = SpotifyLevel.allCases.map { lvl in
            guard finite else { return 0 }
            var g = lvl.target - L
            if g > 0, lvl != .loud { g = max(0, min(g, -1 - tp)) }
            return g
        }
        // YouTube: -14 LUFS, attenuation only
        let youtubeGain = finite ? min(0, -14 - L) : 0
        // SoundCloud: -14 LUFS; quiet masters raised only up to -1 dBTP
        let soundcloudGain: Double = {
            guard finite else { return 0 }
            let g = -14 - L
            return g > 0 ? max(0, min(g, -1 - tp)) : g
        }()
        let gLoud = spotifyGain[SpotifyLevel.loud.rawValue]

        // Encode → decode every codec in parallel
        let lossy = Codec.allCases.filter { $0 != .lossless }
        let steps = Double(lossy.count + 1)
        var versions = [[[Float]]?](repeating: nil, count: Codec.allCases.count)
        versions[Codec.lossless.rawValue] = base
        try await withThrowingTaskGroup(of: (Int, [[Float]]?).self) { group in
            for c in lossy {
                group.addTask {
                    guard let (dec, rate) = try? CodecEngine.roundtrip(c, chs, sampleRate: fs) else { return (c.rawValue, nil) }
                    let atPlay = Processing.resample(dec, from: rate, to: playRate)
                    return (c.rawValue, Processing.align(atPlay, to: base))
                }
            }
            var done = 0.0
            for try await (i, v) in group {
                versions[i] = v
                done += 1
                progress(done / steps)
            }
        }

        // Per-codec peaks and Loud limiter curves, in parallel
        let n = Codec.allCases.count
        var codecTP = [Double](repeating: tp, count: n)
        var loudTP = [Double?](repeating: nil, count: n)
        var loudLUFS = [Double?](repeating: nil, count: n)
        var envelopes = [[Float]?](repeating: nil, count: n)
        let vs = versions
        let results = await withTaskGroup(of: (Int, Double, [Float]?, Double?, Double?).self) { group in
            for i in 0..<n {
                group.addTask {
                    guard let v = vs[i] else { return (i, tp, nil, nil, nil) }
                    let ctp = 20 * log10(Double(max(Loudness.truePeak(v, sampleRate: playRate), 1e-10)))
                    guard gLoud > 0, let env = Processing.limiterEnvelope(v, gainDB: gLoud, sampleRate: playRate) else {
                        return (i, ctp, nil, nil, nil)
                    }
                    let limited = Processing.apply(v, gain: Float(pow(10, gLoud / 20)), envelope: env)
                    let ltp = 20 * log10(Double(max(Loudness.truePeak(limited, sampleRate: playRate), 1e-10)))
                    return (i, ctp, env, ltp, Loudness.integrated(limited, sampleRate: playRate))
                }
            }
            var out: [(Int, Double, [Float]?, Double?, Double?)] = []
            for await r in group { out.append(r) }
            return out
        }
        for (i, ctp, env, ltp, llufs) in results {
            codecTP[i] = ctp
            envelopes[i] = env
            loudTP[i] = ltp
            loudLUFS[i] = llufs
        }
        codecTP[Codec.lossless.rawValue] = tp

        let wave = Processing.waveform(base, buckets: 1600)
        let loudWave = envelopes[0].map { Processing.waveform(Processing.apply(base, gain: 1, envelope: $0), buckets: 1600) }
        let limiterCodecs = Set(envelopes.indices.filter { envelopes[$0] != nil })

        let info = TrackInfo(lufs: L, truePeakDB: tp, sourceRate: fs, frames: frames, duration: Double(frames) / playRate,
                             waveform: wave, loudWaveform: loudWave, spotifyGain: spotifyGain,
                             youtubeGain: youtubeGain, soundcloudGain: soundcloudGain, codecTP: codecTP, loudTP: loudTP,
                             loudLUFS: loudLUFS, limiterCodecs: limiterCodecs)
        return Processed(info: info, audio: TrackAudio(frames: frames, versions: versions, envelopes: envelopes))
    }

    // MARK: transport

    func toggle() {
        guard active?.info != nil else { return }
        isPlaying.toggle()
        push()
        isPlaying ? startTicker() : stopTicker()
    }

    /// Click/drag on a track's waveform. Another track: stop the current one, play this from there.
    func scrub(_ t: Track, fraction: Double) {
        guard let info = t.info else { return }
        let frame = Int(min(max(fraction, 0), 1) * Double(info.frames - 1))
        if t.id != activeID {
            active?.position = engine.position
            activeID = t.id
            isPlaying = true
            startTicker()
        }
        t.position = frame
        time = Double(frame) / engine.sampleRate
        push(seek: frame)
    }

    func step(_ delta: Int) {
        guard let i = tracks.firstIndex(where: { $0.id == activeID }) else { return }
        let j = i + delta
        guard tracks.indices.contains(j) else { return }
        active?.position = engine.position
        let t = tracks[j]
        activeID = t.id
        time = Double(t.position) / engine.sampleRate
        push(seek: t.position)
    }

    func nudge(_ seconds: Double) {
        guard let t = active, let info = t.info else { return }
        scrub(t, fraction: (time + seconds) / info.duration)
    }

    func spotifyKey() {
        if platform == .spotify {
            spotifyLevel = [.normal: SpotifyLevel.loud, .loud: .quiet, .quiet: .normal][spotifyLevel]!
        } else {
            platform = .spotify
        }
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(30))
                self?.tick()
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    private func tick() {
        let pos = engine.position
        time = Double(pos) / engine.sampleRate
        active?.position = pos
        let ends = engine.endCount
        if ends != lastEnd {
            lastEnd = ends
            isPlaying = false
            stopTicker()
            active?.position = 0
            time = 0
            push(seek: 0)
        }
    }
}
