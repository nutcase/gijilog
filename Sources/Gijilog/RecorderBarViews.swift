import AppKit
import Combine
import SwiftUI

// MARK: - Recorder bar

struct RecorderBar: View {
    @EnvironmentObject var store: Store
    var body: some View {
        Group {
            if store.recording, let meeting = store.activeMeeting { live(meeting) } else { idle }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }
    // Shown only without an API key: recording starts from the toolbar or a meeting's own page.
    private var idle: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.fill").foregroundStyle(Palette.yamabuki)
            Text("録音するには、OpenAIのAPIキーを設定してください。")
            SettingsLink { Text("設定を開く") }
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
    private func live(_ meeting: Meeting) -> some View {
        VStack(spacing: 10) {
            liveControls(meeting)
            SilenceWarning()
        }
    }
    private func liveControls(_ meeting: Meeting) -> some View {
        HStack(spacing: 18) {
            RecordingLamp()
            VStack(alignment: .leading, spacing: 0) {
                TimelineView(.periodic(from: meeting.date, by: 1)) { context in
                    Text(clock(context.date.timeIntervalSince(meeting.recordingOrigin)))
                        .font(.system(size: 30, weight: .light).monospacedDigit())
                }
                Text(meeting.title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            .fixedSize()
            Spacer(minLength: 24)
            LevelMeters(meter: store.meter)
            Button {
                Task { await store.stop() }
            } label: {
                Label("録音を停止", systemImage: "stop.fill")
            }
            .buttonStyle(CapsuleButtonStyle(filled: false))
            .fixedSize()
            .disabled(store.busy)
        }
    }
}
// The pulse is a Core Animation layer animation, run by the window server rather than by SwiftUI redrawing the
// lamp every frame. (A SwiftUI phaseAnimator here cost about 25% CPU for the whole recording; this costs ~0%.)
struct RecordingLamp: NSViewRepresentable {
    func makeNSView(context: Context) -> PulsingLampView { PulsingLampView() }
    func updateNSView(_ view: PulsingLampView, context: Context) {
        view.pulses = !context.environment.accessibilityReduceMotion
        view.setAccessibilityLabel("録音中")
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PulsingLampView, context: Context) -> CGSize? {
        CGSize(width: 14, height: 14)
    }
}
final class PulsingLampView: NSView {
    var pulses = true { didSet { updatePulse() } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        guard let layer else { return }
        let red = NSColor(Palette.beni).cgColor
        layer.backgroundColor = red
        layer.shadowColor = red
        layer.shadowOpacity = 0.7
        layer.shadowRadius = 6
        layer.shadowOffset = .zero
        layer.masksToBounds = false
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.width / 2
        layer?.shadowPath = CGPath(ellipseIn: bounds, transform: nil)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePulse()
    }
    private func updatePulse() {
        guard let layer else { return }
        guard pulses, window != nil else {
            layer.removeAnimation(forKey: "pulse")
            return
        }
        guard layer.animation(forKey: "pulse") == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.3
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: "pulse")
    }
}
// The meter is not observed by SwiftUI: each waveform subscribes to its track and moves its own layers,
// so 10 Hz levels never re-render the view tree. (A SwiftUI Canvas here cost about 17% CPU while recording.)
struct LevelMeters: View {
    let meter: LevelMeter
    var body: some View {
        HStack(spacing: 22) {
            TrackWaveform(
                label: "Mac音声", systemImage: "speaker.wave.2.fill", levels: meter.$system, tint: Palette.paper)
            TrackWaveform(label: "マイク", systemImage: "mic.fill", levels: meter.$microphone, tint: Palette.asagi)
        }
        .fixedSize()
    }
}
struct TrackWaveform: View {
    let label: String
    let systemImage: String
    let levels: Published<[Float]>.Publisher
    let tint: Color
    // nil: as wide as there is room for, following the window, up to a width where the bars still read as a wave.
    var width: CGFloat? = 168
    var height: CGFloat = 30
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(label, systemImage: systemImage).font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                .accessibilityHidden(true)
            WaveformBars(label: label, levels: levels, tint: tint).frame(width: width, height: height)
        }
        .frame(maxWidth: width == nil ? 360 : nil, alignment: .leading)
    }
}
struct WaveformBars: NSViewRepresentable {
    let label: String
    let levels: Published<[Float]>.Publisher
    let tint: Color
    func makeNSView(context: Context) -> WaveformView {
        let view = WaveformView(tint: NSColor(tint))
        view.setAccessibilityLabel(label)
        view.follow(levels)
        return view
    }
    func updateNSView(_ view: WaveformView, context: Context) {}
}
// The last few seconds of a track as a mirrored bar waveform; older samples fade to the left.
// Levels are drawn on a -60...0 dBFS scale, so a microphone that is not picking up a voice stays flat.
final class WaveformView: NSView {
    private var bars: [CALayer] = []
    private var levels = [Float](repeating: 0, count: LevelMeter.length)
    private var subscription: AnyCancellable?
    init(tint: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        for i in 0..<LevelMeter.length {
            let bar = CALayer()
            let age = CGFloat(i + 1) / CGFloat(LevelMeter.length)
            bar.backgroundColor = tint.withAlphaComponent(0.25 + 0.75 * age).cgColor
            layer?.addSublayer(bar)
            bars.append(bar)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    func follow(_ publisher: Published<[Float]>.Publisher) {
        subscription = publisher.receive(on: DispatchQueue.main).sink { [weak self] levels in
            guard let self else { return }
            self.levels = levels
            self.placeBars()
            self.setAccessibilityValue("\(Int(Self.loudness(levels.last ?? 0) * 100))%")
        }
    }
    override func layout() {
        super.layout()
        placeBars()
    }
    private func placeBars() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)  // Jump to each level; implicit animations would run nonstop.
        let step = bounds.width / CGFloat(bars.count)
        for (i, bar) in bars.enumerated() {
            let level = i < levels.count ? levels[i] : 0
            let height = max(2, CGFloat(Self.loudness(level)) * bounds.height)
            bar.frame = CGRect(
                x: CGFloat(i) * step + step * 0.2, y: (bounds.height - height) / 2, width: step * 0.6, height: height)
            bar.cornerRadius = step * 0.3
        }
        CATransaction.commit()
    }
    static func loudness(_ level: Float) -> Double {
        guard level > 0 else { return 0 }
        return min(1, max(0, (20 * log10(Double(level)) + 60) / 60))
    }
}
// A secondary action beside the record button: text only, so recording stays the obvious choice.
struct QuietButtonStyle: ButtonStyle {
    var selected = false  // Marked like a chosen row in the list, for the page it opens while that page is shown.
    func makeBody(configuration: Configuration) -> some View {
        QuietLabel(configuration: configuration, selected: selected)
    }
    private struct QuietLabel: View {
        @Environment(\.isEnabled) private var isEnabled
        let configuration: ButtonStyle.Configuration
        let selected: Bool
        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.paper.opacity(configuration.isPressed ? 0.45 : selected ? 1 : 0.7))
                .padding(.horizontal, 6).frame(height: selected ? 34 : 40)
                .background(RoundedRectangle(cornerRadius: 7).fill(Palette.ai).opacity(selected ? 1 : 0))
                .padding(.vertical, selected ? 3 : 0)
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Rectangle())
        }
    }
}
// The meeting search, under the app's name and ギジログAI: the list narrows as keywords are typed. Esc or the
// clear button empties it; ⌥⌘F comes here, and ⌘F when no minutes are open.
struct SidebarSearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.paper.opacity(0.5))
            TextField("キーワードで検索", text: $text)
                .textFieldStyle(.plain).foregroundStyle(Palette.paper)
                .focused(focused)
                .onEscape { text = "" }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain).foregroundStyle(Palette.paper.opacity(0.5))
                .help("検索をやめる").accessibilityLabel("検索をやめる")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7).fill(Palette.paper.opacity(0.07)))
        .overlay(
            RoundedRectangle(cornerRadius: 7).strokeBorder(
                focused.wrappedValue ? Palette.asagi.opacity(0.7) : Palette.paper.opacity(0.14))
        )
        .contentShape(Rectangle())
        .onTapGesture { focused.wrappedValue = true }
    }
}
// Red belongs to recording; other actions use the outline style in another tint.
struct CapsuleButtonStyle: ButtonStyle {
    let filled: Bool
    var tint = Palette.beni
    var height: CGFloat = 40  // 30 fits a toolbar.
    func makeBody(configuration: Configuration) -> some View {
        CapsuleLabel(configuration: configuration, filled: filled, tint: tint, height: height)
    }
    private struct CapsuleLabel: View {
        @Environment(\.isEnabled) private var isEnabled
        let configuration: ButtonStyle.Configuration
        let filled: Bool
        let tint: Color
        let height: CGFloat
        var body: some View {
            configuration.label
                .font(.system(size: height < 40 ? 13 : 14, weight: .semibold))
                .foregroundStyle(filled ? Color.white : tint)
                .padding(.horizontal, height < 40 ? 14 : 18).frame(height: height)
                .background(Capsule().fill(filled ? tint : Color.clear))
                .overlay(Capsule().strokeBorder(tint.opacity(filled ? 0 : 0.8), lineWidth: 1.5))
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
                .contentShape(Capsule())
        }
    }
}
