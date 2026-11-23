import Foundation
import AVFoundation
import Synchronization

/// Immutable per-track audio: every codec version, sample-aligned, at the playback rate.
final class TrackAudio: @unchecked Sendable {
    let frames: Int
    let channels: Int
    let versions: [[UnsafeMutablePointer<Float>]?]      // [codec][channel]
    let envelopes: [UnsafeMutablePointer<Float>?]        // Spotify Loud limiter curve per codec

    init(frames: Int, versions: [[[Float]]?], envelopes: [[Float]?]) {
        self.frames = frames
        self.channels = versions.compactMap { $0 }.first?.count ?? 1
        func copy(_ a: [Float]) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: max(a.count, 1))
            a.withUnsafeBufferPointer { if let b = $0.baseAddress { p.initialize(from: b, count: a.count) } }
            return p
        }
        self.versions = versions.map { $0?.map(copy) }
        self.envelopes = envelopes.map { $0.map(copy) }
    }

    deinit {
        versions.forEach { $0?.forEach { $0.deallocate() } }
        envelopes.forEach { $0?.deallocate() }
    }
}

struct Route: Equatable {
    let audio: TrackAudio
    let codec: Int
    let gain: Float
    let limiter: Bool

    static func == (a: Route, b: Route) -> Bool {
        a.audio === b.audio && a.codec == b.codec && a.gain == b.gain && a.limiter == b.limiter
    }
}

struct Control {
    var generation = 0
    var playing = false
    var route: Route?
    var seek: Int?
}

private struct Voice {
    var route: Route
    var pos: Int

    @inline(__always) func sample(_ ch: Int) -> Float {
        let a = route.audio
        guard pos >= 0, pos < a.frames, let v = a.versions[route.codec] ?? a.versions[0] else { return 0 }
        var x = v[min(ch, a.channels - 1)][pos] * route.gain
        if route.limiter, let env = a.envelopes[route.codec] { x *= env[pos] }
        return x
    }
}

final class RenderCore: @unchecked Sendable {
    let control = Mutex(Control())
    let position = Atomic<Int>(0)
    let endCount = Atomic<Int>(0)

    private var generation = -1
    private var playing = false
    private var cur: Voice?
    private var prev: Voice?
    private var fade = 0
    private var level: Float = 0
    private let fadeLength: Int
    private let levelStep: Float

    init(sampleRate: Double) {
        fadeLength = max(1, Int(sampleRate * 0.012))
        levelStep = Float(1 / (sampleRate * 0.006))
    }

    func render(_ abl: UnsafeMutablePointer<AudioBufferList>, _ count: Int) {
        let outs = UnsafeMutableAudioBufferListPointer(abl).map { $0.mData!.assumingMemoryBound(to: Float.self) }

        if let c = control.withLockIfAvailable({ $0.generation != generation ? $0 : nil }) ?? nil {
            generation = c.generation
            playing = c.playing
            if let r = c.route {
                let pos: Int = c.seek ?? ((cur?.route.audio === r.audio) ? cur!.pos : 0)
                if let old = cur, (old.route != r || old.pos != pos), level > 0 {
                    prev = old
                    fade = fadeLength
                }
                cur = Voice(route: r, pos: pos)
            } else {
                cur = nil
                prev = nil
            }
        }

        guard var v = cur else {
            outs.forEach { $0.update(repeating: 0, count: count) }
            return
        }
        for i in 0..<count {
            let target: Float = playing ? 1 : 0
            if level < target { level = min(target, level + levelStep) }
            else if level > target { level = max(target, level - levelStep) }
            if level == 0 && !playing {
                for o in outs { (o + i).update(repeating: 0, count: count - i) }
                break
            }
            var w: Float = 1
            if fade > 0, let p = prev {
                w = 1 - Float(fade) / Float(fadeLength)
                fade -= 1
                for (c, o) in outs.enumerated() { o[i] = (v.sample(c) * w + p.sample(c) * (1 - w)) * level }
                prev!.pos += 1
            } else {
                prev = nil
                for (c, o) in outs.enumerated() { o[i] = v.sample(c) * level }
            }
            if playing {
                v.pos += 1
                if v.pos >= v.route.audio.frames {
                    playing = false
                    endCount.add(1, ordering: .relaxed)
                }
            }
        }
        cur = v
        position.store(v.pos, ordering: .relaxed)
    }
}

final class AudioEngine {
    let sampleRate: Double
    private let engine = AVAudioEngine()
    private let core: RenderCore

    init() {
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        sampleRate = rate > 0 ? rate : 48000
        core = RenderCore(sampleRate: sampleRate)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let c = core
        let node = AVAudioSourceNode(format: fmt) { _, _, frames, abl in
            c.render(abl, Int(frames))
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        engine.mainMixerNode.outputVolume = 1
        engine.prepare()
        try? engine.start()
    }

    var position: Int { core.position.load(ordering: .relaxed) }
    var endCount: Int { core.endCount.load(ordering: .relaxed) }

    func send(playing: Bool, route: Route?, seek: Int? = nil) {
        if playing, !engine.isRunning { try? engine.start() }
        core.control.withLock {
            $0.generation += 1
            $0.playing = playing
            $0.route = route
            $0.seek = seek
        }
    }
}
