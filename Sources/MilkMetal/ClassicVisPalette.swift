import Foundation

/// The 24 colours of a `ClassicVisualizer`, laid out like a Winamp 2 skin's `viscolor.txt`:
///
/// | Index | Colour |
/// |---|---|
/// | 0 | Background |
/// | 1 | The background's grid of dots |
/// | 2–17 | Spectrum analyzer, from the top row to the bottom row |
/// | 18–22 | Oscilloscope, from brightest (the outer rows) to dimmest (the rows by the centre line) |
/// | 23 | Analyzer peak markers |
///
/// A skin's palette goes straight in with `init(viscolorText:fallback:)`. `default` is MilkMetal's own palette: a
/// green analyzer over a near-black grid, with a cool silver scope.
public struct ClassicVisPalette: Sendable, Hashable {
    /// One opaque colour, 8 bits per channel, in sRGB as a skin gives it.
    public struct Color: Sendable, Hashable {
        public var red: UInt8
        public var green: UInt8
        public var blue: UInt8

        public init(red: UInt8, green: UInt8, blue: UInt8) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    /// The number of colours in a palette (and lines that matter in a `viscolor.txt`).
    public static let count = 24
    /// Index of the background colour.
    public static let backgroundIndex = 0
    /// Index of the colour of the background's grid of dots.
    public static let gridIndex = 1
    /// Indices of the 16 analyzer colours, from the top row down.
    public static let analyzerIndices = 2...17
    /// Indices of the 5 oscilloscope colours, from brightest to dimmest.
    public static let oscilloscopeIndices = 18...22
    /// Index of the peak markers' colour.
    public static let peakIndex = 23

    /// Always `count` colours.
    public private(set) var colors: [Color]

    /// A palette of `colors`, in `viscolor.txt` order. Entries past the 24th are ignored, and missing ones come from
    /// `default`.
    public init(colors: [Color]) {
        var all = Array(colors.prefix(Self.count))
        if all.count < Self.count { all += Self.defaultColors[all.count...] }
        self.colors = all
    }

    /// Parses the text of a skin's `viscolor.txt`. Never fails: whatever can't be read keeps `fallback`'s colour.
    ///
    /// Each line is one entry, in order, as `r,g,b` (decimal, 0–255). Parsing is as forgiving as skins need:
    /// - Anything after `//` is a comment. Lines with no number on them (blank, comment-only or junk) are skipped
    ///   and don't use up an entry.
    /// - The first three numbers on a line are the colour, whatever separates them (commas, spaces, tabs) and
    ///   whatever follows. Values over 255 are clamped to 255; a `-` sign is ignored, as in a `viscolor.txt` reader
    ///   that only looks for digits.
    /// - A line with only one or two numbers uses up its entry but keeps `fallback`'s colour, so later lines still
    ///   land on the right index.
    /// - Lines past the 24th entry are ignored; a short file keeps `fallback` for the rest.
    /// - CRLF, CR and LF line endings and a leading byte-order mark are all fine.
    public init(viscolorText text: String, fallback: ClassicVisPalette = .default) {
        var colors = fallback.colors
        var entry = 0
        let lines = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }
        for line in lines where entry < Self.count {
            let content = line.range(of: "//").map { line[..<$0.lowerBound] } ?? line[...]
            let numbers = Self.numbers(in: content, limit: 3)
            guard !numbers.isEmpty else { continue }
            if numbers.count == 3 {
                colors[entry] = Color(red: numbers[0], green: numbers[1], blue: numbers[2])
            }
            entry += 1
        }
        self.colors = colors
    }

    /// Parses the bytes of a skin's `viscolor.txt`: UTF-8 if they are valid UTF-8, otherwise Windows Latin-1 (old
    /// skins' comments often aren't UTF-8). See `init(viscolorText:fallback:)`.
    public init(viscolorData data: Data, fallback: ClassicVisPalette = .default) {
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
            ?? String(decoding: data, as: UTF8.self)
        self.init(viscolorText: text, fallback: fallback)
    }

    /// The colour at `index`, 0–23 (see the table above).
    public subscript(index: Int) -> Color {
        get { colors[index] }
        set { colors[index] = newValue }
    }

    /// Up to `limit` runs of decimal digits in `text`, each clamped to 0–255.
    private static func numbers(in text: Substring, limit: Int) -> [UInt8] {
        var result: [UInt8] = []
        var value: Int?
        for scalar in text.unicodeScalars {
            if (48...57).contains(scalar.value) {
                value = min((value ?? 0) * 10 + Int(scalar.value) - 48, 255)
            } else if let v = value {
                result.append(UInt8(v))
                value = nil
                if result.count == limit { return result }
            }
        }
        if let v = value, result.count < limit { result.append(UInt8(v)) }
        return result
    }

    /// MilkMetal's palette: a near-black background with a dim blue-grey grid, an analyzer from a pale lime top
    /// row down to deep green, a scope from near-white to slate, and pale peaks.
    public static let `default` = ClassicVisPalette(validated: defaultColors)

    private init(validated colors: [Color]) {
        self.colors = colors
    }

    private static let defaultColors: [Color] = {
        func c(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Color { Color(red: r, green: g, blue: b) }
        var colors = [c(6, 8, 10), c(34, 42, 50)]
        // Analyzer: top (pale lime) to bottom (deep green), eased so the upper rows stay bright.
        let top = (r: 226.0, g: 255.0, b: 128.0), bottom = (r: 12.0, g: 104.0, b: 34.0)
        for row in 0..<16 {
            let t = pow(Double(row) / 15, 0.8)
            func mix(_ a: Double, _ b: Double) -> UInt8 { UInt8((a + (b - a) * t).rounded()) }
            colors.append(c(mix(top.r, bottom.r), mix(top.g, bottom.g), mix(top.b, bottom.b)))
        }
        // Scope: brightest at the outer rows, dimmest by the centre line.
        colors += [c(236, 244, 252), c(196, 210, 224), c(160, 178, 196), c(128, 146, 166), c(100, 118, 140)]
        colors.append(c(232, 236, 244))
        return colors
    }()
}
