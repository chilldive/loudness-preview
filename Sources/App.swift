import SwiftUI
import AppKit

@main
struct LoudnessPreviewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = Model()

    var body: some Scene {
        Window("Loudness Preview", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 680, idealWidth: 820, minHeight: 520, idealHeight: 640)
                .ignoresSafeArea(.container, edges: .top)
                .onReceive(NotificationCenter.default.publisher(for: .openAudio)) { n in
                    if let urls = n.object as? [URL] { model.add(urls) }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.open() }.keyboardShortcut("o")
            }
        }
    }
}

final class Flag: ObservableObject { @Published var on = false }

extension Notification.Name { static let openAudio = Notification.Name("openAudio") }

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        NotificationCenter.default.post(name: .openAudio, object: urls)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum Fmt {
    static func db(_ v: Double, signed: Bool = true) -> String {
        guard v.isFinite else { return "–" }
        let r = (v * 10).rounded() / 10
        if r == 0 { return "0.0" }
        let s = String(format: "%.1f", abs(r))
        return r > 0 ? (signed ? "+" + s : s) : "−" + s
    }
    static func time(_ t: Double) -> String {
        let s = Int(max(t, 0))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var model: Model
    @StateObject private var drop = Flag()

    var body: some View {
        VStack(spacing: 0) {
            if model.tracks.isEmpty {
                EmptyStateView(targeted: drop.on).padding(.top, 36)
            } else {
                MainView(dropTargeted: drop.on)
            }
            Text("Loudness Preview")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.quaternary)
                .padding(.top, 12)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            model.add(urls)
            return true
        } isTargeted: { drop.on = $0 }
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var model: Model
    let targeted: Bool

    var body: some View {
        Button { model.open() } label: {
            VStack(spacing: 14) {
                Image(systemName: "waveform")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(targeted ? Color.accentColor : .secondary)
                Text("Drop audio files")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(targeted ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 6]))
                    .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.35))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct MainView: View {
    @EnvironmentObject var model: Model
    let dropTargeted: Bool

    var body: some View {
        VStack(spacing: 14) {
            TopBar()
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.tracks) { TrackRow(track: $0) }
                }
                .padding(.vertical, 2)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .opacity(dropTargeted ? 1 : 0)
                    .allowsHitTesting(false)
            }
            ModeBar()
        }
        .background(shortcuts)
    }

    private var shortcuts: some View {
        ZStack {
            Button("") { model.toggle() }.keyboardShortcut(.space, modifiers: [])
            Button("") { model.nudge(-5) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { model.nudge(5) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { model.step(-1) }.keyboardShortcut(.upArrow, modifiers: [])
            Button("") { model.step(1) }.keyboardShortcut(.downArrow, modifiers: [])
            Button("") { if let t = model.active { model.remove(t) } }.keyboardShortcut(.delete, modifiers: [])
            Button("") { model.platform = .original }.keyboardShortcut("1", modifiers: [])
            Button("") { model.spotifyKey() }.keyboardShortcut("2", modifiers: [])
            Button("") { model.platform = .youtube }.keyboardShortcut("3", modifiers: [])
        }
        .opacity(0)
        .allowsHitTesting(false)
    }
}

struct TopBar: View {
    @EnvironmentObject var model: Model

    var body: some View {
        HStack(spacing: 12) {
            Button { model.toggle() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            Text("\(Fmt.time(model.time)) / \(Fmt.time(model.active?.info?.duration ?? 0))")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer()
            Button { model.open() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .frame(height: 28)
        .padding(.leading, 62)
    }
}

// MARK: - Tracks

struct WaveformShape: Shape {
    let peaks: [Float]
    var scale: Double

    var animatableData: Double {
        get { scale }
        set { scale = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard !peaks.isEmpty else {
            p.addRect(CGRect(x: rect.minX, y: rect.midY - 0.5, width: rect.width, height: 1))
            return p
        }
        let mid = rect.midY
        let half = rect.height / 2
        let count = max(1, Int(rect.width / 2))
        let barW = rect.width / CGFloat(count)
        for i in 0..<count {
            let s = i * peaks.count / count
            let e = max(s + 1, (i + 1) * peaks.count / count)
            var m: Float = 0
            for j in s..<min(e, peaks.count) { m = max(m, peaks[j]) }
            let h = max(0.5, min(1, CGFloat(m) * scale) * half)
            p.addRect(CGRect(x: rect.minX + CGFloat(i) * barW, y: mid - h,
                             width: max(1, barW - 0.6), height: h * 2))
        }
        return p
    }
}

struct TrackRow: View {
    @EnvironmentObject var model: Model
    @ObservedObject var track: Track
    @StateObject private var hover = Flag()

    private var isActive: Bool { model.activeID == track.id }

    var body: some View {
        let info = track.info
        let setting = info.map { model.setting($0) }
        let peaks: [Float] = {
            if let info, let s = setting, s.limiter, let w = info.loudWaveform { return w }
            return info?.waveform ?? track.preview
        }()
        let scale = setting.map { pow(10, $0.gainDB / 20) } ?? 1
        let progress: Double = {
            guard let info, info.frames > 0 else { return 0 }
            let pos = isActive ? model.time * model.engine.sampleRate : Double(track.position)
            return min(1, pos / Double(info.frames))
        }()
        let tint = model.platform.tint

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(track.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .lineLimit(1).truncationMode(.middle)
                if info == nil {
                    if track.failed {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                    } else {
                        ProgressView(value: track.progress).progressViewStyle(.linear).controlSize(.mini).frame(width: 64)
                    }
                }
                Spacer(minLength: 8)
                if let info {
                    if let s = setting, model.platform != .original {
                        Text("\(Fmt.db(s.gainDB)) dB")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(tint)
                    }
                    Text("\(Fmt.db(info.lufs)) LUFS")
                        .font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text("\(Fmt.db(info.truePeakDB)) dBTP")
                        .font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
                        .foregroundStyle(info.truePeakDB > -1 ? Color.orange : .secondary)
                }
                Button { model.remove(track) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hover.on ? 1 : 0)
            }
            .frame(height: 16)

            GeometryReader { geo in
                let shape = WaveformShape(peaks: peaks, scale: scale)
                ZStack(alignment: .leading) {
                    shape.fill(Color.secondary.opacity(isActive ? 0.35 : 0.25))
                    shape.fill(isActive ? tint : Color.secondary.opacity(0.45))
                        .mask(alignment: .leading) { Rectangle().frame(width: geo.size.width * progress) }
                    if info != nil {
                        Rectangle()
                            .fill(isActive ? Color.primary : Color.secondary.opacity(0.6))
                            .frame(width: isActive ? 1.5 : 1)
                            .offset(x: geo.size.width * progress - 0.75)
                    }
                }
                .animation(.easeOut(duration: 0.25), value: scale)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    model.scrub(track, fraction: v.location.x / geo.size.width)
                })
            }
            .frame(height: isActive ? 72 : 52)
            .opacity(info == nil ? 0.5 : 1)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(isActive ? 0.05 : (hover.on ? 0.03 : 0.015)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isActive ? tint.opacity(0.55) : .clear, lineWidth: 1)
        )
        .onHover { hover.on = $0 }
        .animation(.easeOut(duration: 0.18), value: isActive)
    }
}

// MARK: - Modes

struct ModeBar: View {
    @EnvironmentObject var model: Model

    var body: some View {
        let info = model.active?.info
        HStack(spacing: 10) {
            ModeCard(title: "Original", key: "1", platform: .original,
                     readout: info.map { model.readout($0, platform: .original) }) { EmptyView() }
            ModeCard(title: "Spotify", key: "2", platform: .spotify,
                     readout: info.map { model.readout($0, platform: .spotify) }) { SpotifyMenu() }
            ModeCard(title: "YouTube", key: "3", platform: .youtube,
                     readout: info.map { model.readout($0, platform: .youtube) }) { YouTubeMenu() }
        }
    }
}

struct Chip: View {
    let text: String
    var highlight = false

    var body: some View {
        HStack(spacing: 3) {
            Text(text)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 7, weight: .bold))
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(highlight ? Color.orange : Color.secondary)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(highlight ? Color.orange.opacity(0.15) : Color.primary.opacity(0.06)))
        .lineLimit(1)
        .fixedSize()
    }
}

struct SpotifyMenu: View {
    @EnvironmentObject var model: Model

    var body: some View {
        Menu {
            Picker("", selection: Binding(get: { model.spotifyLevel },
                                          set: { model.spotifyLevel = $0; model.platform = .spotify })) {
                ForEach(SpotifyLevel.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline).labelsHidden()
            Divider()
            Picker("", selection: Binding(get: { model.spotifyCodec },
                                          set: { model.spotifyCodec = $0; model.platform = .spotify })) {
                ForEach(Codec.spotify) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            Chip(text: "\(model.spotifyLevel.label) · \(model.spotifyCodec.label)",
                 highlight: model.spotifyLevel != .normal)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

struct YouTubeMenu: View {
    @EnvironmentObject var model: Model

    var body: some View {
        Menu {
            Picker("", selection: Binding(get: { model.youtubeCodec },
                                          set: { model.youtubeCodec = $0; model.platform = .youtube })) {
                ForEach(Codec.youtube) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            Chip(text: model.youtubeCodec.label)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

struct ModeCard<Accessory: View>: View {
    @EnvironmentObject var model: Model
    let title: String
    let key: String
    let platform: Platform
    let readout: Readout?
    @ViewBuilder var accessory: () -> Accessory
    @StateObject private var hover = Flag()

    private var selected: Bool { model.platform == platform }

    var body: some View {
        let tint = platform.tint
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if platform != .original { Circle().fill(tint).frame(width: 7, height: 7) }
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? .primary : .secondary)
                accessory()
                Spacer(minLength: 4)
                if readout?.limited == true {
                    Text("LIM")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.2)))
                        .foregroundStyle(Color.orange)
                }
                Text(key)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            .frame(height: 20)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(readout.map { Fmt.db($0.gainDB) } ?? "–")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("dB").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Text("\(readout.map { Fmt.db($0.lufs) } ?? "–") LUFS")
                Text("\(readout.map { Fmt.db($0.truePeakDB) } ?? "–") dBTP")
                    .foregroundStyle((readout?.truePeakDB ?? -100) > 0 ? Color.orange : .secondary)
            }
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? tint.opacity(0.13) : Color.primary.opacity(hover.on ? 0.06 : 0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? tint.opacity(0.9) : Color.clear, lineWidth: 1.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { model.platform = platform }
        .onHover { hover.on = $0 }
        .animation(.easeOut(duration: 0.15), value: selected)
        .animation(.easeOut(duration: 0.2), value: readout?.gainDB)
    }
}
