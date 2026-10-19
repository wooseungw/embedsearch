/// Hangul helpers for launcher-style matching: 초성 (initial consonant) extraction and
/// "keystroke jamo" decomposition, which makes a partially typed last syllable a prefix of the
/// full word ("계사" ⊂ "계산기", "값" ⊂ "갑시다").
public enum Hangul {
    static let syllableBase: UInt32 = 0xAC00
    static let syllableLast: UInt32 = 0xD7A3

    /// Compatibility jamo (U+3131…) for the 19 initial consonants.
    static let choseong: [UInt32] = [
        0x3131, 0x3132, 0x3134, 0x3137, 0x3138, 0x3139, 0x3141, 0x3142, 0x3143, 0x3145,
        0x3146, 0x3147, 0x3148, 0x3149, 0x314A, 0x314B, 0x314C, 0x314D, 0x314E,
    ]
    /// 21 medial vowels, compound vowels split into their keystrokes.
    static let jungseongKeys: [[UInt32]] = [
        [0x314F], [0x3150], [0x3151], [0x3152], [0x3153], [0x3154], [0x3155], [0x3156], [0x3157],
        [0x3157, 0x314F], [0x3157, 0x3150], [0x3157, 0x3163], [0x315B], [0x315C],
        [0x315C, 0x3153], [0x315C, 0x3154], [0x315C, 0x3163], [0x3160], [0x3161],
        [0x3161, 0x3163], [0x3163],
    ]
    /// 28 finals (index 0 = none), compound finals split into their keystrokes.
    static let jongseongKeys: [[UInt32]] = [
        [], [0x3131], [0x3132], [0x3131, 0x3145], [0x3134], [0x3134, 0x3148], [0x3134, 0x314E],
        [0x3137], [0x3139], [0x3139, 0x3131], [0x3139, 0x3141], [0x3139, 0x3142], [0x3139, 0x3145],
        [0x3139, 0x314C], [0x3139, 0x314D], [0x3139, 0x314E], [0x3141], [0x3142], [0x3142, 0x3145],
        [0x3145], [0x3146], [0x3147], [0x3148], [0x314A], [0x314B], [0x314C], [0x314D], [0x314E],
    ]
    /// Compound compatibility jamo typed on their own (e.g. a dangling "ㄳ") → keystrokes.
    static let compoundCompatibility: [UInt32: [UInt32]] = [
        0x3133: [0x3131, 0x3145], 0x3135: [0x3134, 0x3148], 0x3136: [0x3134, 0x314E],
        0x313A: [0x3139, 0x3131], 0x313B: [0x3139, 0x3141], 0x313C: [0x3139, 0x3142],
        0x313D: [0x3139, 0x3145], 0x313E: [0x3139, 0x314C], 0x313F: [0x3139, 0x314D],
        0x3140: [0x3139, 0x314E], 0x3144: [0x3142, 0x3145],
        0x3158: [0x3157, 0x314F], 0x3159: [0x3157, 0x3150], 0x315A: [0x3157, 0x3163],
        0x315D: [0x315C, 0x3153], 0x315E: [0x315C, 0x3154], 0x315F: [0x315C, 0x3163],
        0x3162: [0x3161, 0x3163],
    ]

    // The tables above packed for the per-scalar loop: up to two keystrokes per entry, low 32 bits
    // first, 0 = none. Compound compatibility jamo are indexed by `scalar - 0x3131`.
    private static func pack(_ keys: [UInt32]) -> UInt64 {
        keys.enumerated().reduce(0) { $0 | UInt64($1.element) << (32 * UInt64($1.offset)) }
    }
    private static let jungPacked: [UInt64] = jungseongKeys.map(pack)
    private static let jongPacked: [UInt64] = jongseongKeys.map(pack)
    private static let compoundPacked: [UInt64] = (0x3131...0x3163).map { pack(compoundCompatibility[UInt32($0)] ?? []) }

    @inline(__always)
    static func isSyllable(_ v: UInt32) -> Bool { v >= syllableBase && v <= syllableLast }

    /// Compatibility consonants ㄱ…ㅎ (U+3131–U+314E).
    @inline(__always)
    public static func isCompatibilityConsonant(_ v: UInt32) -> Bool { v >= 0x3131 && v <= 0x314E }

    /// Compatibility jamo block U+3131–U+318E.
    @inline(__always)
    static func isCompatibilityJamo(_ v: UInt32) -> Bool { v >= 0x3131 && v <= 0x318E }

    public static func containsHangul(_ text: String) -> Bool {
        text.unicodeScalars.contains { isSyllable($0.value) || isCompatibilityJamo($0.value) }
    }

    /// True when `text` (ignoring spaces) is non-empty and made only of compatibility consonants,
    /// i.e. a 초성 query such as "ㄱㅅㄱ".
    public static func isChoseongQuery(_ text: String) -> Bool {
        var sawConsonant = false
        for s in text.unicodeScalars where s != " " {
            guard isCompatibilityConsonant(s.value) else { return false }
            sawConsonant = true
        }
        return sawConsonant
    }

    /// 초성 string: each syllable becomes its initial consonant; other characters are kept.
    /// "계산기" → "ㄱㅅㄱ", "시스템 설정" → "ㅅㅅㅌ ㅅㅈ".
    public static func choseongString(_ text: String) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(text.utf8.count)
        for s in text.unicodeScalars { appendUTF8(choseongScalar(s.value), to: &out) }
        return String(decoding: out, as: UTF8.self)
    }

    /// Keystroke-level jamo decomposition (2-set keyboard order); non-Hangul passes through.
    /// "계산기" → "ㄱㅖㅅㅏㄴㄱㅣ", "값" → "ㄱㅏㅂㅅ", "와" → "ㅇㅗㅏ".
    public static func keystrokeJamo(_ text: String) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(text.utf8.count * 2)
        for s in text.unicodeScalars { appendKeystrokeJamo(s.value, to: &out) }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: Byte-level building blocks (UTF-8 output, no intermediate Strings)

    /// The 초성 of a syllable, any other scalar unchanged.
    @inline(__always)
    static func choseongScalar(_ v: UInt32) -> UInt32 {
        isSyllable(v) ? choseong[Int((v - syllableBase) / 588)] : v
    }

    /// Appends the keystroke jamo of one scalar.
    @inline(__always)
    static func appendKeystrokeJamo(_ v: UInt32, to out: inout [UInt8]) {
        if isSyllable(v) {
            let index = Int(v - syllableBase)
            appendUTF8(choseong[index / 588], to: &out)
            appendPacked(jungPacked[(index % 588) / 28], to: &out)
            appendPacked(jongPacked[index % 28], to: &out)
        } else if v >= 0x3131, v <= 0x3163, case let keys = compoundPacked[Int(v - 0x3131)], keys != 0 {
            appendPacked(keys, to: &out)
        } else {
            appendUTF8(v, to: &out)
        }
    }

    /// Keystrokes of a syllable as `PackedJamo` bytes (compatibility jamo U+3131… → 0x80…).
    @inline(__always)
    static func appendPackedKeystrokes(ofSyllable v: UInt32, to out: inout [UInt8]) {
        let index = Int(v - syllableBase)
        out.append(UInt8(0x80 + choseong[index / 588] - 0x3131))
        appendPackedBytes(jungPacked[(index % 588) / 28], to: &out)
        appendPackedBytes(jongPacked[index % 28], to: &out)
    }

    @inline(__always)
    private static func appendPackedBytes(_ keys: UInt64, to out: inout [UInt8]) {
        let first = UInt32(truncatingIfNeeded: keys), second = UInt32(truncatingIfNeeded: keys >> 32)
        if first != 0 { out.append(UInt8(0x80 + first - 0x3131)) }
        if second != 0 { out.append(UInt8(0x80 + second - 0x3131)) }
    }

    /// The 초성 of a syllable as a `PackedJamo` byte.
    @inline(__always)
    static func packedChoseong(ofSyllable v: UInt32) -> UInt8 {
        UInt8(0x80 + choseong[Int((v - syllableBase) / 588)] - 0x3131)
    }

    @inline(__always)
    private static func appendPacked(_ keys: UInt64, to out: inout [UInt8]) {
        let first = UInt32(truncatingIfNeeded: keys), second = UInt32(truncatingIfNeeded: keys >> 32)
        if first != 0 { appendUTF8(first, to: &out) }
        if second != 0 { appendUTF8(second, to: &out) }
    }

    @inline(__always)
    static func appendUTF8(_ v: UInt32, to out: inout [UInt8]) {
        switch v {
        case ..<0x80:
            out.append(UInt8(v))
        case ..<0x800:
            out.append(UInt8(0xC0 | v >> 6))
            out.append(UInt8(0x80 | v & 0x3F))
        case ..<0x10000:
            out.append(UInt8(0xE0 | v >> 12))
            out.append(UInt8(0x80 | v >> 6 & 0x3F))
            out.append(UInt8(0x80 | v & 0x3F))
        default:
            out.append(UInt8(0xF0 | v >> 18))
            out.append(UInt8(0x80 | v >> 12 & 0x3F))
            out.append(UInt8(0x80 | v >> 6 & 0x3F))
            out.append(UInt8(0x80 | v & 0x3F))
        }
    }
}
