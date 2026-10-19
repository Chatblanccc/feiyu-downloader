import AppKit
import SwiftUI
import SubtitleCore

// Keep the property wrapper implementation available with the bundled CLT SDK.
private typealias SubtitleLocalState<Value> = SwiftUI.State<Value>

@available(macOS 26.0, *)
struct SubtitleStyleEditor: View {
    @Binding var style: SubtitleStyle
    let textMode: SubtitleTextMode
    let isEnabled: Bool
    let appliesToVideo: Bool
    @SubtitleLocalState<Bool> private var customColorPresented = false
    @SubtitleLocalState<Double> private var customHue = 0.0
    @SubtitleLocalState<Double> private var customSaturation = 0.0
    @SubtitleLocalState<Double> private var customBrightness = 100.0
    private let colors: [(String, String)] = [
        ("白色", "FFFFFF"), ("暖黄", "FFE066"), ("天蓝", "73E0FF"),
        ("浅绿", "82F5A3"), ("粉色", "FFB6D5"), ("橙色", "FFB366")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("字幕样式").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("恢复默认") { change { $0 = .default } }.buttonStyle(.borderless).font(.system(size: 11)).disabled(!isEnabled)
            }
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("字号").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int((style.fontScale * 100).rounded()))%")
                            .font(.system(size: 11)).monospacedDigit()
                    }
                    Slider(value: Binding(get: { style.fontScale * 100 }, set: { percent in
                        change { $0.fontScale = min(2, max(0.6, percent / 100)) }
                    }), in: 60...200, step: 10)
                        .accessibilityLabel("字幕字号")
                        .accessibilityValue("\(Int((style.fontScale * 100).rounded()))%")
                    HStack(spacing: 8) {
                        Text("文字颜色").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        ForEach(colors, id: \.1) { name, hex in
                            Button {
                                change { $0.colorHex = hex }
                            } label: {
                                Circle().fill(Color(nsColor: Self.color(hex)))
                                    .overlay(Circle().stroke(Color.black.opacity(0.14), lineWidth: 1))
                                    .overlay {
                                        if style.colorHex.uppercased() == hex {
                                            Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.black.opacity(0.8))
                                        }
                                    }
                                    .frame(width: 18, height: 18)
                            }.buttonStyle(.plain).help(name).accessibilityLabel("字幕文字\(name)")
                        }
                    }
                    HStack {
                        Button("自定义颜色…") {
                            DispatchQueue.main.async {
                                let color = Self.color(style.colorHex)
                                customHue = Double(color.hueComponent) * 360
                                customSaturation = Double(color.saturationComponent) * 100
                                customBrightness = Double(color.brightnessComponent) * 100
                                customColorPresented = true
                            }
                        }.font(.system(size: 11)).accessibilityLabel("自定义字幕文字颜色")
                            .popover(isPresented: $customColorPresented, arrowEdge: .bottom) { customColorEditor }
                        RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: Self.color(style.colorHex)))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.15)))
                            .frame(width: 32, height: 17)
                        Spacer(minLength: 0)
                    }
                    Picker("字幕位置", selection: Binding(get: { style.position }, set: { position in
                        change { $0.position = position }
                    })) {
                        ForEach(SubtitlePosition.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).accessibilityLabel("字幕位置")
                }.disabled(!isEnabled).frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 5) {
                    Text("样式预览").font(.system(size: 9)).foregroundStyle(.secondary)
                    ZStack(alignment: .topLeading) {
                        LinearGradient(colors: [Color(white: 0.29), Color(white: 0.13)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: "play.rectangle").font(.system(size: 32, weight: .ultraLight))
                            .foregroundStyle(.white.opacity(0.14)).frame(maxWidth: .infinity, maxHeight: .infinity)
                        SubtitleStylePreview(style: style, text: previewText)
                    }.frame(width: 230, height: 130).clipShape(RoundedRectangle(cornerRadius: 7))
                    Text("透明底色 · 黑色细描边")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            Text(appliesToVideo
                 ? "样式将直接绘制到视频画面中；预览用于观察字号、颜色和位置。"
                 : "这些样式仅用于字幕直接显示在画面中的视频。SRT 和可开关字幕的显示样式由播放器控制。")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(3)
        }.padding(14).background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
    }

    private var previewText: String {
        switch textMode {
        case .original: return "Every story deserves to be understood."
        case .translated: return "让每一段故事都听得懂。"
        case .bilingual: return "Every story deserves to be understood.\n让每一段故事都听得懂。"
        }
    }

    private var customColorEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("自定义文字颜色").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(hue: customHue / 360, saturation: customSaturation / 100, brightness: customBrightness / 100))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.black.opacity(0.15)))
                    .frame(width: 52, height: 36)
                Text("#" + customHex).font(.system(size: 12, design: .monospaced))
            }
            colorSlider("色调", value: customHue, range: 0...360, suffix: "°") { value in
                customHue = value
                applyCustomColor(hue: value, saturation: customSaturation, brightness: customBrightness)
            }
            colorSlider("饱和度", value: customSaturation, range: 0...100, suffix: "%") { value in
                customSaturation = value
                applyCustomColor(hue: customHue, saturation: value, brightness: customBrightness)
            }
            colorSlider("明暗", value: customBrightness, range: 0...100, suffix: "%") { value in
                customBrightness = value
                applyCustomColor(hue: customHue, saturation: customSaturation, brightness: value)
            }
            HStack {
                Text("拖动即可预览颜色").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("完成") { DispatchQueue.main.async { customColorPresented = false } }
                    .buttonStyle(.borderedProminent)
            }
        }.padding(17).frame(width: 280)
    }

    private func colorSlider(_ title: String, value: Double, range: ClosedRange<Double>, suffix: String,
                             update: @escaping (Double) -> Void) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.rounded()))" + suffix).monospacedDigit().foregroundStyle(.secondary)
            }.font(.system(size: 11))
            Slider(value: Binding(get: { value }, set: update), in: range, step: 1)
                .accessibilityLabel("自定义字幕颜色\(title)")
                .accessibilityValue("\(Int(value.rounded()))" + suffix)
        }
    }

    private var customHex: String {
        Self.hex(hue: customHue, saturation: customSaturation, brightness: customBrightness)
    }

    private func applyCustomColor(hue: Double, saturation: Double, brightness: Double) {
        let hex = Self.hex(hue: hue, saturation: saturation, brightness: brightness)
        change { $0.colorHex = hex }
    }

    private static func hex(hue: Double, saturation: Double, brightness: Double) -> String {
        let sector = (hue / 60).truncatingRemainder(dividingBy: 6)
        let value = brightness / 100
        let chroma = value * saturation / 100
        let cross = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let offset = value - chroma
        let rgb: [Double]
        switch Int(sector) {
        case 0: rgb = [chroma, cross, 0]
        case 1: rgb = [cross, chroma, 0]
        case 2: rgb = [0, chroma, cross]
        case 3: rgb = [0, cross, chroma]
        case 4: rgb = [cross, 0, chroma]
        default: rgb = [chroma, 0, cross]
        }
        return rgb.map { $0 + offset }
            .map { String(format: "%02X", Int((min(1, max(0, $0)) * 255).rounded())) }.joined()
    }

    private func change(_ mutation: @escaping (inout SubtitleStyle) -> Void) {
        guard isEnabled else { return }
        DispatchQueue.main.async {
            var updated = style
            mutation(&updated)
            if let validated = try? updated.validated() { style = validated }
        }
    }

    fileprivate static func color(_ hex: String) -> NSColor {
        let value = UInt32(hex, radix: 16) ?? 0xFFFFFF
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

@available(macOS 26.0, *)
private struct SubtitleStylePreview: NSViewRepresentable {
    let style: SubtitleStyle
    let text: String
    func makeNSView(context: Context) -> SubtitlePreviewDrawing { SubtitlePreviewDrawing() }
    func updateNSView(_ view: SubtitlePreviewDrawing, context: Context) {
        view.style = style; view.text = text; view.needsDisplay = true
        view.setAccessibilityLabel("字幕预览，\(style.position.title)，字号 \(Int((style.fontScale * 100).rounded()))%")
    }
}

@available(macOS 26.0, *)
private final class SubtitlePreviewDrawing: NSView {
    var style = SubtitleStyle.default
    var text = ""
    override var isOpaque: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let scale = style.fontScale.isFinite ? min(2, max(0.6, style.fontScale)) : 1
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(10, bounds.width * 0.045) * scale, weight: .semibold),
            .foregroundColor: SubtitleStyleEditor.color(style.colorHex),
            .paragraphStyle: paragraph
        ]
        let value = NSAttributedString(string: text, attributes: attributes)
        let width = bounds.width * 0.91
        let size = value.boundingRect(with: NSSize(width: width, height: bounds.height * 0.84),
                                      options: [.usesLineFragmentOrigin, .usesFontLeading]).size
        let height = min(ceil(size.height) + 2, bounds.height * 0.84)
        let margin = bounds.height * 0.065
        let y: CGFloat
        switch style.position {
        case .bottom: y = margin
        case .center: y = (bounds.height - height) / 2
        case .top: y = max(margin, bounds.height - margin - height)
        }
        let rectangle = NSRect(x: (bounds.width - width) / 2, y: y, width: width, height: height)
        var outline = attributes
        outline[.strokeColor] = NSColor.black.withAlphaComponent(0.95)
        outline[.strokeWidth] = 3.0
        NSAttributedString(string: text, attributes: outline).draw(with: rectangle, options: [.usesLineFragmentOrigin, .usesFontLeading])
        // Refill after outlining so small Chinese strokes keep their full weight.
        value.draw(with: rectangle, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}
