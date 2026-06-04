import SwiftUI

public enum BrandLogo: String, Sendable, Hashable, CaseIterable, Identifiable {
    case apple
    case openAI
    case anthropic
    case google
    case mistral
    case deepSeek
    case meta
    case ollama
    case openRouter
    case voyage
    case groq
    case deepgram
    case assemblyAI
    case rev
    case speechmatics
    case soniox
    case elevenLabs
    case fireworks
    case volcengine
    case huggingface
    case nvidia
    case qwen

    public var id: String { rawValue }

    /// Lowercased filename stem for the bundled logo PNGs (`<slug>-light.png` /
    /// `<slug>-dark.png` under Resources/Logos).
    ///
    /// The raw case names lowercase to
    /// exactly the downloaded filenames (openAI → openai, deepSeek → deepseek, …).
    public var slug: String { rawValue.lowercased() }

    public var displayName: String {
        switch self {
        case .apple: return "Apple"
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .google: return "Google"
        case .mistral: return "Mistral"
        case .deepSeek: return "DeepSeek"
        case .meta: return "Meta"
        case .ollama: return "Ollama"
        case .openRouter: return "OpenRouter"
        case .voyage: return "Voyage"
        case .groq: return "Groq"
        case .deepgram: return "Deepgram"
        case .assemblyAI: return "AssemblyAI"
        case .rev: return "Rev"
        case .speechmatics: return "Speechmatics"
        case .soniox: return "Soniox"
        case .elevenLabs: return "ElevenLabs"
        case .fireworks: return "Fireworks"
        case .volcengine: return "Volcengine"
        case .huggingface: return "Hugging Face"
        case .nvidia: return "NVIDIA"
        case .qwen: return "Qwen"
        }
    }

    public var monogram: String {
        switch self {
        case .apple: return ""
        case .openAI: return "O"
        case .anthropic: return "A"
        case .google: return "G"
        case .mistral: return "M"
        case .deepSeek: return "D"
        case .meta: return "M"
        case .ollama: return "Ol"
        case .openRouter: return "OR"
        case .voyage: return "V"
        case .groq: return "Gq"
        case .deepgram: return "Dg"
        case .assemblyAI: return "Ai"
        case .rev: return "Rv"
        case .speechmatics: return "Sm"
        case .soniox: return "Sx"
        case .elevenLabs: return "11"
        case .fireworks: return "Fw"
        case .volcengine: return "Vo"
        case .huggingface: return "Hf"
        case .nvidia: return "Nv"
        case .qwen: return "Qw"
        }
    }
}

public struct BrandLogoView: View {
    @Environment(\.brutalistPalette) private var palette
    public let logo: BrandLogo
    public let size: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    public init(_ logo: BrandLogo, size: CGFloat = 16) {
        self.logo = logo
        self.size = size
    }

    public var body: some View {
        Group {
            if let image = Self.logoImage(slug: logo.slug, dark: colorScheme == .dark) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                shape  // drawn fallback until the PNG exists / for unmapped brands
            }
        }
        .frame(width: size, height: size)
    }

    /// Bundled `<slug>-<light|dark>.png` from Resources/Logos, cached.
    ///
    /// The dark
    /// variant is used in dark mode (light-on-dark) and the light one in light
    /// mode, so monochrome marks (OpenAI, Apple) stay visible either way. nil →
    /// the caller falls back to the drawn `shape`.
    @MainActor private static var cache: [String: NSImage?] = [:]
    @MainActor private static func logoImage(slug: String, dark: Bool) -> NSImage? {
        let name = "\(slug)-\(dark ? "dark" : "light")"
        if let cached = cache[name] { return cached }
        let url =
            Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Resources/Logos")
            ?? Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Logos")
            ?? Bundle.module.url(forResource: name, withExtension: "png")
        let image = url.flatMap { NSImage(contentsOf: $0) }
        cache[name] = image
        return image
    }

    @ViewBuilder
    private var shape: some View {
        switch logo {
        case .apple:
            Image(systemName: "apple.logo")
                .font(.system(size: size * 0.9))
                .foregroundStyle(palette.fg.color)
        case .openAI:
            OpenAIHexagon()
                .stroke(palette.fg.color, lineWidth: max(size * 0.06, 1))
                .frame(width: size, height: size)
        case .anthropic:
            AnthropicMark()
                .fill(palette.fg.color)
                .frame(width: size, height: size)
        case .google:
            GoogleG()
                .stroke(palette.fg.color, lineWidth: max(size * 0.06, 1))
                .frame(width: size, height: size)
        case .mistral:
            MistralStripes()
                .fill(palette.fg.color)
                .frame(width: size, height: size)
        case .deepSeek:
            DeepSeekWhale()
                .fill(palette.fg.color)
                .frame(width: size, height: size)
        case .meta:
            MetaInfinity()
                .stroke(palette.fg.color, lineWidth: max(size * 0.08, 1.2))
                .frame(width: size, height: size)
        case .ollama:
            OllamaLlama()
                .fill(palette.fg.color)
                .frame(width: size, height: size)
        case .openRouter:
            OpenRouterArrow()
                .stroke(palette.fg.color, lineWidth: max(size * 0.08, 1.2))
                .frame(width: size, height: size)
        case .voyage:
            VoyageDiamond()
                .stroke(palette.fg.color, lineWidth: max(size * 0.08, 1.2))
                .frame(width: size, height: size)
        case .groq:
            GroqArrow()
                .fill(palette.fg.color)
                .frame(width: size, height: size)
        case .deepgram:
            DeepgramWave()
                .stroke(palette.fg.color, lineWidth: max(size * 0.08, 1.2))
                .frame(width: size, height: size)
        case .assemblyAI:
            AssemblyMark()
                .fill(palette.fg.color)
                .frame(width: size, height: size)
        case .rev:
            RevR()
                .fill(palette.fg.color)
                .frame(width: size, height: size)
        case .speechmatics:
            SpeechmaticsBar()
                .fill(palette.fg.color)
                .frame(width: size, height: size)
        case .soniox:
            SonioxDot()
                .fill(palette.fg.color)
                .frame(width: size, height: size)
        case .elevenLabs:
            ElevenLabsPipes()
                .fill(palette.fg.color)
                .frame(width: size, height: size)
        case .fireworks:
            FireworksBurst()
                .fill(palette.fg.color)
                .frame(width: size, height: size)
        case .volcengine:
            VolcengineV()
                .fill(palette.fg.color)
                .frame(width: size, height: size)
        case .huggingface:
            HuggingfaceFace()
                .fill(palette.fg.color)
                .frame(width: size, height: size)
        case .nvidia, .qwen:
            Text(logo.monogram)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(palette.fg.color)
        }
    }
}

private struct OpenAIHexagon: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let cx = rect.midX
        let cy = rect.midY
        let r = min(rect.width, rect.height) * 0.42
        for i in 0..<6 {
            let angle = (Double(i) * .pi / 3.0) - .pi / 2
            let x = cx + CGFloat(cos(angle)) * r
            let y = cy + CGFloat(sin(angle)) * r
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        p.closeSubpath()
        return p
    }
}

private struct AnthropicMark: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height
        p.move(to: CGPoint(x: w * 0.25, y: h * 0.85))
        p.addLine(to: CGPoint(x: w * 0.5, y: h * 0.15))
        p.addLine(to: CGPoint(x: w * 0.75, y: h * 0.85))
        p.addLine(to: CGPoint(x: w * 0.62, y: h * 0.85))
        p.addLine(to: CGPoint(x: w * 0.5, y: h * 0.55))
        p.addLine(to: CGPoint(x: w * 0.38, y: h * 0.85))
        p.closeSubpath()
        return p
    }
}

private struct GoogleG: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(rect.width, rect.height) * 0.4
        let c = CGPoint(x: rect.midX, y: rect.midY)
        p.addArc(center: c, radius: r, startAngle: .degrees(-30), endAngle: .degrees(260), clockwise: false)
        p.move(to: CGPoint(x: c.x + r, y: c.y))
        p.addLine(to: CGPoint(x: c.x, y: c.y))
        return p
    }
}

private struct MistralStripes: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let stripeH = rect.height / 7
        for i in stride(from: 0, to: 7, by: 2) {
            p.addRect(CGRect(x: 0, y: CGFloat(i) * stripeH, width: rect.width, height: stripeH))
        }
        return p
    }
}

private struct DeepSeekWhale: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let cx = rect.midX
        let cy = rect.midY
        let r = min(rect.width, rect.height) * 0.4
        p.addEllipse(in: CGRect(x: cx - r, y: cy - r * 0.7, width: r * 2, height: r * 1.4))
        return p.intersection(Path(CGRect(x: 0, y: 0, width: rect.width, height: rect.height * 0.7)))
    }
}

private struct MetaInfinity: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(rect.width, rect.height) * 0.22
        p.addArc(
            center: CGPoint(x: rect.midX - r, y: rect.midY), radius: r, startAngle: .zero, endAngle: .degrees(360),
            clockwise: false)
        p.addArc(
            center: CGPoint(x: rect.midX + r, y: rect.midY), radius: r, startAngle: .zero, endAngle: .degrees(360),
            clockwise: false)
        return p
    }
}

private struct OllamaLlama: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height
        p.move(to: CGPoint(x: w * 0.5, y: h * 0.1))
        p.addLine(to: CGPoint(x: w * 0.75, y: h * 0.4))
        p.addLine(to: CGPoint(x: w * 0.7, y: h * 0.9))
        p.addLine(to: CGPoint(x: w * 0.3, y: h * 0.9))
        p.addLine(to: CGPoint(x: w * 0.25, y: h * 0.4))
        p.closeSubpath()
        return p
    }
}

private struct OpenRouterArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height
        p.move(to: CGPoint(x: w * 0.15, y: h * 0.5))
        p.addLine(to: CGPoint(x: w * 0.85, y: h * 0.5))
        p.move(to: CGPoint(x: w * 0.6, y: h * 0.25))
        p.addLine(to: CGPoint(x: w * 0.85, y: h * 0.5))
        p.addLine(to: CGPoint(x: w * 0.6, y: h * 0.75))
        return p
    }
}

private struct VoyageDiamond: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.1))
        p.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.1, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.1))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.1, y: rect.midY))
        p.closeSubpath()
        return p
    }
}

private struct GroqArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + rect.width * 0.2, y: rect.midY - rect.height * 0.15))
        p.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.2, y: rect.minY + rect.height * 0.15))
        p.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.2, y: rect.midY + rect.height * 0.15))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.2, y: rect.maxY - rect.height * 0.15))
        p.closeSubpath()
        return p
    }
}

private struct DeepgramWave: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let mid = rect.midY
        p.move(to: CGPoint(x: rect.minX, y: mid))
        p.addCurve(
            to: CGPoint(x: rect.maxX, y: mid),
            control1: CGPoint(x: rect.midX - rect.width * 0.2, y: mid - rect.height * 0.4),
            control2: CGPoint(x: rect.midX + rect.width * 0.2, y: mid + rect.height * 0.4)
        )
        return p
    }
}

private struct AssemblyMark: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addRect(
            CGRect(
                x: rect.minX + rect.width * 0.2, y: rect.minY + rect.height * 0.2, width: rect.width * 0.6,
                height: rect.height * 0.2))
        p.addRect(
            CGRect(
                x: rect.minX + rect.width * 0.2, y: rect.midY - rect.height * 0.1, width: rect.width * 0.6,
                height: rect.height * 0.2))
        p.addRect(
            CGRect(
                x: rect.minX + rect.width * 0.2, y: rect.maxY - rect.height * 0.4, width: rect.width * 0.6,
                height: rect.height * 0.2))
        return p
    }
}

private struct RevR: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height
        p.addRect(CGRect(x: w * 0.25, y: h * 0.2, width: w * 0.12, height: h * 0.6))
        p.addArc(
            center: CGPoint(x: w * 0.5, y: h * 0.35),
            radius: w * 0.18,
            startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false
        )
        p.move(to: CGPoint(x: w * 0.5, y: h * 0.55))
        p.addLine(to: CGPoint(x: w * 0.75, y: h * 0.8))
        return p
    }
}

private struct SpeechmaticsBar: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width / 5
        for i in 0..<5 {
            let scale = [0.4, 0.7, 1.0, 0.6, 0.45][i]
            let h = rect.height * scale
            let x = CGFloat(i) * w + w * 0.15
            p.addRect(CGRect(x: x, y: rect.midY - h / 2, width: w * 0.7, height: h))
        }
        return p
    }
}

private struct SonioxDot: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(rect.width, rect.height) * 0.18
        for (col, row) in [(0, 1), (1, 0), (1, 2), (2, 1)] {
            let x = rect.minX + rect.width * (CGFloat(col) + 1) / 4
            let y = rect.minY + rect.height * (CGFloat(row) + 1) / 4
            p.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
        return p
    }
}

private struct ElevenLabsPipes: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let pipeWidth = rect.width * 0.18
        p.addRect(
            CGRect(
                x: rect.minX + rect.width * 0.22, y: rect.minY + rect.height * 0.2, width: pipeWidth,
                height: rect.height * 0.6))
        p.addRect(
            CGRect(
                x: rect.minX + rect.width * 0.6, y: rect.minY + rect.height * 0.2, width: pipeWidth,
                height: rect.height * 0.6))
        return p
    }
}

private struct FireworksBurst: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let cx = rect.midX
        let cy = rect.midY
        let r = min(rect.width, rect.height) * 0.4
        for i in 0..<8 {
            let angle = Double(i) * .pi / 4
            let x = cx + CGFloat(cos(angle)) * r
            let y = cy + CGFloat(sin(angle)) * r
            p.move(to: CGPoint(x: cx, y: cy))
            p.addLine(to: CGPoint(x: x, y: y))
        }
        p.addEllipse(in: CGRect(x: cx - 2, y: cy - 2, width: 4, height: 4))
        return p
    }
}

private struct VolcengineV: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + rect.width * 0.15, y: rect.minY + rect.height * 0.2))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.15))
        p.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.15, y: rect.minY + rect.height * 0.2))
        p.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.3, y: rect.minY + rect.height * 0.2))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.4))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.3, y: rect.minY + rect.height * 0.2))
        p.closeSubpath()
        return p
    }
}

private struct HuggingfaceFace: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(rect.width, rect.height) * 0.42
        p.addEllipse(in: CGRect(x: rect.midX - r, y: rect.midY - r, width: r * 2, height: r * 2))
        let eyeR = r * 0.15
        p.addEllipse(
            in: CGRect(x: rect.midX - r * 0.45 - eyeR, y: rect.midY - r * 0.2 - eyeR, width: eyeR * 2, height: eyeR * 2)
        )
        p.addEllipse(
            in: CGRect(x: rect.midX + r * 0.45 - eyeR, y: rect.midY - r * 0.2 - eyeR, width: eyeR * 2, height: eyeR * 2)
        )
        return p
    }
}
