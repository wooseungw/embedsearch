import Foundation

/// Match quality tiers, best first: exact > prefix > word-prefix > substring > 초성/initials > fuzzy.
public enum MatchTier: Int, Comparable, Sendable, CustomStringConvertible {
    case fuzzy = 1, initials, substring, wordPrefix, prefix, exact

    public static func < (lhs: MatchTier, rhs: MatchTier) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String {
        switch self {
        case .exact: "exact"
        case .prefix: "prefix"
        case .wordPrefix: "word-prefix"
        case .substring: "substring"
        case .initials: "initials"
        case .fuzzy: "fuzzy"
        }
    }
}

// MARK: - Term representations

/// Every form of one normalized string that the tiers look at (UTF-8 bytes).
///
/// "Simple" text — only ASCII and precomposed Hangul syllables, i.e. nearly every title, keyword
/// and query — has every space as its own grapheme, so compact = text without spaces, words =
/// runs between spaces, and the jamo / 초성 forms map scalar by scalar; those forms are derived
/// in one pass. Any other text uses the String APIs exactly as written (`replacingOccurrences` and
/// `split` work on graphemes: a space followed by a combining mark is not a separator) and keeps
/// every form explicitly.
private struct TermForms {
    var simple = true
    var norm: [UInt8] = []
    var compact: [UInt8] = []
    /// Keystroke jamo of `norm` (spaces kept) and of `compact`.
    var jamo: [UInt8] = []
    var jamoCompact: [UInt8] = []
    /// Keystroke jamo of each word, joined by 0xFF (non-simple multi-word text only).
    var wordJamos: [UInt8] = []
    /// 초성 of `compact` and of each word (joined by 0x20 when simple, 0xFF otherwise).
    var choseong: [UInt8] = []
    var wordChoseongs: [UInt8] = []
    var initials: [UInt8] = []
    var length = 0
    var wordCount = 0
    var hasHangul = false
    var hasCompatibilityJamo = false

    init(normalized norm: String) {
        if TextNormalizer.isASCIIOrSyllables(norm) { deriveSimple(norm) } else { computeGeneral(norm) }
        if wordCount > 1 {
            let words = norm.split(separator: " ")
            let latinWords = words.filter { $0.unicodeScalars.first.map { $0.isASCII && $0.properties.isAlphabetic } ?? false }
            if latinWords.count >= 2 && latinWords.count == words.count {
                initials = Array(String(latinWords.compactMap(\.first)).utf8)
            }
        }
    }

    private mutating func deriveSimple(_ norm: String) {
        var choseongSpaced: [UInt8] = []
        jamo.reserveCapacity(norm.utf8.count * 3)
        wordCount = norm.isEmpty ? 0 : 1
        for s in norm.unicodeScalars {
            let v = s.value
            if v == 0x20 {
                wordCount += 1
                jamo.append(0x20)
                choseongSpaced.append(0x20)
                continue
            }
            length += 1
            if Hangul.isSyllable(v) { hasHangul = true }
            Hangul.appendKeystrokeJamo(v, to: &jamo)
            Hangul.appendUTF8(Hangul.choseongScalar(v), to: &choseongSpaced)
        }
        let multiWord = wordCount > 1
        jamoCompact = multiWord ? jamo.filter { $0 != 0x20 } : jamo
        if hasHangul {
            choseong = multiWord ? choseongSpaced.filter { $0 != 0x20 } : choseongSpaced
            if multiWord { wordChoseongs = choseongSpaced }
        }
    }

    private mutating func computeGeneral(_ normString: String) {
        simple = false
        let compactString = normString.replacingOccurrences(of: " ", with: "")
        let words = normString.split(separator: " ").map(String.init)
        norm = Array(normString.utf8)
        compact = Array(compactString.utf8)
        jamo = Array(Hangul.keystrokeJamo(normString).utf8)
        jamoCompact = Array(Hangul.keystrokeJamo(compactString).utf8)
        wordCount = words.count
        length = compactString.unicodeScalars.count
        hasHangul = Hangul.containsHangul(compactString)
        hasCompatibilityJamo = normString.unicodeScalars.contains { Hangul.isCompatibilityJamo($0.value) }
        if wordCount > 1 { wordJamos = Array(words.map { Array(Hangul.keystrokeJamo($0).utf8) }.joined(separator: [0xFF])) }
        if hasHangul {
            choseong = Array(Hangul.choseongString(compactString).utf8)
            if wordCount > 1 {
                wordChoseongs = Array(words.map { Array(Hangul.choseongString($0).utf8) }.joined(separator: [0xFF]))
            }
        }
    }

    /// Non-space scalars of `jamo` (a superset of those of `jamoCompact` and of every word).
    var termMask: CharMask { CharMask(utf8: jamo) }

    /// First scalar of the compact jamo and of every word: where every typo candidate starts.
    var wordStarts: UInt64 {
        var bits: UInt64 = 0
        let words = simple || wordCount < 2 ? jamo : wordJamos
        let separator: UInt8 = simple ? 0x20 : 0xFF
        jamoCompact.withUnsafeBufferPointer { b in
            if !b.isEmpty { bits |= CharMask.startBit(Bytes.scalar(at: 0, in: b).value) }
        }
        words.withUnsafeBufferPointer { b in
            var it = WordIterator(b, separator: separator)
            while let w = it.next() {
                if !w.isEmpty { bits |= CharMask.startBit(Bytes.scalar(at: 0, in: w).value) }
            }
        }
        return bits
    }
}

/// One byte per scalar for text made of ASCII and the compatibility jamo U+3131…U+3163, which is
/// every keystroke-jamo and 초성 form of simple text: ASCII stays, jamo map to 0x80…0xB2. A third
/// of the memory of UTF-8, and prefix / substring / subsequence / edit distance work on plain bytes.
enum PackedJamo {
    /// nil when some scalar has no packed byte.
    static func encode(_ utf8: [UInt8]) -> [UInt8]? {
        var out: [UInt8] = []
        out.reserveCapacity(utf8.count)
        var ok = true
        utf8.withUnsafeBufferPointer {
            Bytes.decodeUTF8($0) { v in
                if v < 0x80 { out.append(UInt8(v)) } else if v >= 0x3131 && v <= 0x3163 { out.append(UInt8(0x80 + v - 0x3131)) } else { ok = false }
            }
        }
        return ok ? out : nil
    }

    @inline(__always)
    static func scalar(_ b: UInt8) -> UInt32 { b < 0x80 ? UInt32(b) : 0x3131 + UInt32(b &- 0x80) }

    @inline(__always)
    static func byte(_ v: UInt32) -> UInt8? {
        v < 0x80 ? UInt8(v) : v >= 0x3131 && v <= 0x3163 ? UInt8(0x80 + v - 0x3131) : nil
    }
}

// MARK: - Character-set fingerprint

/// 128-bit set of the scalars of a keystroke-jamo string: one bit per compatibility jamo, latin
/// letter and digit, everything else hashed into the remaining bits. Spaces are left out.
///
/// `q.missing(from: t)` counts distinct query scalars that certainly do not occur in the term
/// (hash collisions can only lower it). Every tier except the OSA typo check needs all scalars of
/// the query's compact jamo to occur in the term's jamo, and an OSA distance `d` leaves at most `d`
/// of them missing, so a term with `missing > allowed` provably cannot match — the index skips it
/// after one AND/popcount.
struct CharMask: Sendable, Equatable {
    var lo: UInt64 = 0
    var hi: UInt64 = 0

    init() {}

    init(utf8: [UInt8]) {
        utf8.withUnsafeBufferPointer { Bytes.decodeUTF8($0) { v in if v != 0x20 { insert(v) } } }
    }

    @inline(__always)
    mutating func insert(_ v: UInt32) {
        switch v {
        case 0x3131...0x3163: lo |= 1 &<< UInt64(v - 0x3131)            // 51 jamo → lo 0…50
        case 0x61...0x7A: hi |= 1 &<< UInt64(v - 0x61)                  // a–z → hi 0…25
        case 0x30...0x39: hi |= 1 &<< UInt64(26 + v - 0x30)             // 0–9 → hi 26…35
        default:
            let h = UInt64(v % 41)                                      // lo 51…63, hi 36…63
            if h < 13 { lo |= 1 &<< (51 + h) } else { hi |= 1 &<< (23 + h) }
        }
    }

    /// One bit per word-initial scalar: jamo exactly, anything else hashed.
    @inline(__always)
    static func startBit(_ v: UInt32) -> UInt64 {
        v >= 0x3131 && v <= 0x3163 ? 1 &<< UInt64(v - 0x3131) : 1 &<< (51 + UInt64(v % 13))
    }

    @inline(__always)
    func missing(from other: CharMask) -> Int {
        (lo & ~other.lo).nonzeroBitCount &+ (hi & ~other.hi).nonzeroBitCount
    }
}

// MARK: - Term storage

/// Every term of an index in one byte arena plus an offset and two fingerprints per term, instead
/// of a dozen small heap arrays per term.
///
/// Arena entry: flags byte, LEB128 counts, then the byte segments in this order (each only when
/// present): jamoCompact · jamo (when ≠ jamoCompact) · norm, compact (non-simple only) ·
/// word jamos (non-simple multi-word) · choseong (Hangul) · word 초성 (Hangul multi-word) · initials.
/// Simple terms store their jamo and 초성 segments as `PackedJamo`, the others as UTF-8.
struct TermStore: Sendable {
    private(set) var bytes: [UInt8] = []
    private(set) var offsets: [UInt32] = []
    private(set) var masks: [CharMask] = []
    /// `CharMask.startBit` of every word start (see `LexicalMatcher.typoScore`).
    private(set) var wordStarts: [UInt64] = []
    /// Reused while appending simple terms; emptied by `shrinkToFit`.
    private var scratch: (jamo: [UInt8], choseong: [UInt8], initials: [UInt8]) = ([], [], [])

    var count: Int { offsets.count }

    fileprivate enum Flag {
        static let multiWord: UInt8 = 1 << 0
        static let distinctJamo: UInt8 = 1 << 1
        static let general: UInt8 = 1 << 2
        static let hangul: UInt8 = 1 << 3
        static let initials: UInt8 = 1 << 4
    }

    /// Adds `text` (normalized again here, like every representation of a term).
    mutating func append(_ text: String) {
        let norm = TextNormalizer.normalize(text)
        if TextNormalizer.isASCIIOrSyllables(norm) { appendSimple(norm) } else { appendGeneral(TermForms(normalized: norm)) }
    }

    /// `TermForms` for simple text in one pass: packed jamo and 초성, fingerprints and initials are
    /// written straight into the arena (no UTF-8 forms, no intermediate arrays per term).
    private mutating func appendSimple(_ normalized: String) {
        var norm = normalized
        scratch.jamo.removeAll(keepingCapacity: true)
        scratch.choseong.removeAll(keepingCapacity: true)
        scratch.initials.removeAll(keepingCapacity: true)
        var length = 0, words = norm.isEmpty ? 0 : 1
        var hangul = false, latinStarts = true, atWordStart = true
        var mask = CharMask(), starts: UInt64 = 0
        norm.withUTF8 { b in
            var i = 0
            while i < b.count {
                let c = b[i]
                if c == 0x20 {
                    words += 1
                    scratch.jamo.append(0x20)
                    scratch.choseong.append(0x20)
                    atWordStart = true
                    i += 1
                    continue
                }
                length += 1
                if c < 0x80 {
                    if atWordStart {
                        if c &- 0x61 >= 26 { latinStarts = false }  // normalized letters are lowercase
                        scratch.initials.append(c)
                        starts |= CharMask.startBit(UInt32(c))
                    }
                    scratch.jamo.append(c)
                    scratch.choseong.append(c)
                    mask.insert(UInt32(c))
                    i += 1
                } else {
                    let v = (UInt32(c & 0x0F) << 12) | (UInt32(b[i + 1] & 0x3F) << 6) | UInt32(b[i + 2] & 0x3F)
                    hangul = true
                    let from = scratch.jamo.count
                    Hangul.appendPackedKeystrokes(ofSyllable: v, to: &scratch.jamo)
                    for k in scratch.jamo[from...] { mask.insert(PackedJamo.scalar(k)) }
                    if atWordStart {
                        latinStarts = false
                        starts |= CharMask.startBit(PackedJamo.scalar(scratch.jamo[from]))
                    }
                    scratch.choseong.append(Hangul.packedChoseong(ofSyllable: v))
                    i += 3
                }
                atWordStart = false
            }
        }
        let multiWord = words > 1
        let hasInitials = multiWord && latinStarts
        var flags: UInt8 = 0
        if multiWord { flags |= Flag.multiWord | Flag.distinctJamo }
        if hangul { flags |= Flag.hangul }
        if hasInitials { flags |= Flag.initials }

        offsets.append(UInt32(bytes.count))
        masks.append(mask)
        wordStarts.append(starts)
        bytes.append(flags)
        let gaps = words > 0 ? words - 1 : 0  // one space between words
        Self.writeVarint(length, to: &bytes)
        Self.writeVarint(scratch.jamo.count - gaps, to: &bytes)
        if multiWord { Self.writeVarint(scratch.jamo.count, to: &bytes) }
        if hangul {
            Self.writeVarint(scratch.choseong.count - gaps, to: &bytes)
            if multiWord { Self.writeVarint(scratch.choseong.count, to: &bytes) }
        }
        if hasInitials { Self.writeVarint(scratch.initials.count, to: &bytes) }
        if multiWord {
            for k in scratch.jamo where k != 0x20 { bytes.append(k) }
            bytes += scratch.jamo
        } else {
            bytes += scratch.jamo
        }
        if hangul {
            if multiWord {
                for k in scratch.choseong where k != 0x20 { bytes.append(k) }
                bytes += scratch.choseong
            } else {
                bytes += scratch.choseong
            }
        }
        if hasInitials { bytes += scratch.initials }
    }

    private mutating func appendGeneral(_ f: TermForms) {
        offsets.append(UInt32(bytes.count))
        masks.append(f.termMask)
        wordStarts.append(f.wordStarts)

        // Simple text decomposes into ASCII and U+3131…U+3163 only, so packing cannot fail.
        func form(_ utf8: [UInt8]) -> [UInt8] { f.simple ? PackedJamo.encode(utf8)! : utf8 }
        let multiWord = f.wordCount > 1
        let distinctJamo = f.jamo != f.jamoCompact
        var flags: UInt8 = 0
        if multiWord { flags |= Flag.multiWord }
        if distinctJamo { flags |= Flag.distinctJamo }
        if !f.simple { flags |= Flag.general }
        if f.hasHangul { flags |= Flag.hangul }
        if !f.initials.isEmpty { flags |= Flag.initials }
        bytes.append(flags)

        var segments: [[UInt8]] = [form(f.jamoCompact)]
        if distinctJamo { segments.append(form(f.jamo)) }
        if !f.simple {
            segments.append(f.norm)
            segments.append(f.compact)
            if multiWord { segments.append(f.wordJamos) }
        }
        if f.hasHangul {
            segments.append(form(f.choseong))
            if multiWord { segments.append(form(f.wordChoseongs)) }
        }
        if !f.initials.isEmpty { segments.append(f.initials) }

        Self.writeVarint(f.length, to: &bytes)
        for s in segments { Self.writeVarint(s.count, to: &bytes) }
        for s in segments { bytes += s }
    }

    /// Releases the slack the arrays accumulated while growing.
    mutating func shrinkToFit() {
        scratch = ([], [], [])
        bytes = Self.exact(bytes)
        offsets = Self.exact(offsets)
        masks = Self.exact(masks)
        wordStarts = Self.exact(wordStarts)
    }

    private static func exact<T>(_ a: [T]) -> [T] {
        [T](unsafeUninitializedCapacity: a.count) { buf, n in
            _ = buf.initialize(fromContentsOf: a)
            n = a.count
        }
    }

    private static func writeVarint(_ value: Int, to out: inout [UInt8]) {
        var v = UInt(value)
        while v >= 0x80 {
            out.append(UInt8(truncatingIfNeeded: v) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
    }

    @inline(__always)
    func withArena<R>(_ body: (TermArena) throws -> R) rethrows -> R {
        try bytes.withUnsafeBufferPointer { b in
            try offsets.withUnsafeBufferPointer { o in
                try masks.withUnsafeBufferPointer { m in
                    try wordStarts.withUnsafeBufferPointer { w in
                        try body(TermArena(bytes: b.baseAddress ?? UnsafePointer(bitPattern: 1)!, offsets: o,
                                           masks: m, wordStarts: w))
                    }
                }
            }
        }
    }
}

struct TermArena {
    let bytes: UnsafePointer<UInt8>
    let offsets: UnsafeBufferPointer<UInt32>
    let masks: UnsafeBufferPointer<CharMask>
    let wordStarts: UnsafeBufferPointer<UInt64>

    @inline(__always)
    func view(_ i: Int) -> TermView {
        var p = bytes + Int(offsets[i])
        let flags = p.pointee
        p += 1
        @inline(__always) func varint() -> Int {
            var v = 0, shift = 0
            while true {
                let b = p.pointee
                p += 1
                v |= Int(b & 0x7F) << shift
                if b < 0x80 { return v }
                shift += 7
            }
        }
        typealias F = TermStore.Flag
        let multiWord = flags & F.multiWord != 0, general = flags & F.general != 0
        let hangul = flags & F.hangul != 0
        let length = varint()
        let jamoCompactCount = varint()
        let jamoCount = flags & F.distinctJamo != 0 ? varint() : -1
        let normCount = general ? varint() : 0
        let compactCount = general ? varint() : 0
        let wordJamosCount = general && multiWord ? varint() : 0
        let choseongCount = hangul ? varint() : 0
        let wordChoseongsCount = hangul && multiWord ? varint() : 0
        let initialsCount = flags & F.initials != 0 ? varint() : 0
        @inline(__always) func take(_ n: Int) -> UnsafeBufferPointer<UInt8> {
            defer { p += n }
            return UnsafeBufferPointer(start: p, count: n)
        }
        let jamoCompact = take(jamoCompactCount)
        let jamo = jamoCount >= 0 ? take(jamoCount) : jamoCompact
        let norm = take(normCount)
        let compact = take(compactCount)
        let wordJamos = take(wordJamosCount)
        let choseong = take(choseongCount)
        let wordChoseongs = take(wordChoseongsCount)
        let initials = take(initialsCount)
        return TermView(jamoCompact: jamoCompact, jamo: jamo, norm: norm, compact: compact,
                        words: general ? wordJamos : jamo, choseong: choseong, wordChoseongs: wordChoseongs,
                        initials: initials, length: length, isMultiWord: multiWord, isGeneral: general,
                        hasHangul: hangul, wordStarts: wordStarts[i])
    }
}

/// Borrowed view of one term's forms. Jamo and 초성 segments are `PackedJamo` unless `isGeneral`.
struct TermView {
    let jamoCompact: UnsafeBufferPointer<UInt8>
    /// Keystroke jamo with spaces (= `jamoCompact` when they are equal).
    let jamo: UnsafeBufferPointer<UInt8>
    /// UTF-8, only stored for non-simple terms (simple terms decide exactness on jamo).
    let norm: UnsafeBufferPointer<UInt8>
    let compact: UnsafeBufferPointer<UInt8>
    /// Keystroke jamo of every word, separated by `wordSeparator`.
    let words: UnsafeBufferPointer<UInt8>
    /// 초성 of the compact form, and of every word separated by `wordSeparator` (Hangul only).
    let choseong: UnsafeBufferPointer<UInt8>
    let wordChoseongs: UnsafeBufferPointer<UInt8>
    /// First letter of each Latin word ("visual studio code" → "vsc"), empty unless ≥ 2 Latin words.
    let initials: UnsafeBufferPointer<UInt8>
    /// Scalars in the compact form (coverage denominator; also the 초성 length).
    let length: Int
    let isMultiWord: Bool
    let isGeneral: Bool
    let hasHangul: Bool
    let wordStarts: UInt64

    @inline(__always) var isPacked: Bool { !isGeneral }
    @inline(__always) var wordSeparator: UInt8 { isGeneral ? 0xFF : 0x20 }
}

/// A single term outside an index (tests, ad-hoc matching).
struct LexTerm: Sendable {
    let store: TermStore

    init(_ text: String) {
        var store = TermStore()
        store.append(text)
        self.store = store
    }
}

// MARK: - Query

/// A query (or one query token) prepared once per keystroke, in UTF-8 (for non-simple terms) and,
/// when every jamo has a packed byte, in `PackedJamo` (for simple terms).
struct LexQuery: Sendable {
    /// UTF-8 norm · compact · jamo · jamoCompact · " " + jamo, then the packed jamo · jamoCompact ·
    /// " " + jamo · 초성 query, back to back.
    private let bytes: [UInt8]
    private let counts: (norm: Int, compact: Int, jamo: Int, jamoCompact: Int,
                         packedJamo: Int, packedJamoCompact: Int, packedChoseong: Int)
    private let packable: Bool
    /// Scalars of the compact jamo (edit distance works on scalars).
    let jamoScalars: [UInt32]
    let mask: CharMask
    /// Start bits of the first two scalars: a typo candidate must begin with one of them.
    let typoStarts: UInt64
    /// For the bit-parallel edit distance against packed text: bit i of `packedMatch[b]` is set when
    /// query scalar i packs to byte b. Empty unless the query has 4…64 scalars (the typo range).
    let packedMatch: [UInt64]
    let isChoseong: Bool
    let hasSpace: Bool
    let hasCompatibilityJamo: Bool
    let length: Int
    let isEmpty: Bool

    init(_ text: String) {
        let normString = TextNormalizer.normalize(text)
        let f = TermForms(normalized: normString)
        let norm = Array(normString.utf8)
        let compact = f.simple ? norm.filter { $0 != 0x20 } : f.compact
        let isChoseong = Hangul.isChoseongQuery(String(decoding: compact, as: UTF8.self))
        var bytes = norm + compact + f.jamo + f.jamoCompact + [0x20] + f.jamo
        var packedCounts = (jamo: 0, jamoCompact: 0, choseong: 0)
        // jamoCompact's scalars are a subset of jamo's; a 초성 query's compact form is consonants.
        if let jamo = PackedJamo.encode(f.jamo), let jamoCompact = PackedJamo.encode(f.jamoCompact),
           let choseong = isChoseong ? PackedJamo.encode(compact) : [] {
            bytes += jamo + jamoCompact + [0x20] + jamo + choseong
            packedCounts = (jamo.count, jamoCompact.count, choseong.count)
            packable = true
        } else {
            packable = false
        }
        self.bytes = bytes
        counts = (norm.count, compact.count, f.jamo.count, f.jamoCompact.count,
                  packedCounts.jamo, packedCounts.jamoCompact, packedCounts.choseong)
        jamoScalars = String(decoding: f.jamoCompact, as: UTF8.self).unicodeScalars.map(\.value)
        mask = CharMask(utf8: f.jamoCompact)
        typoStarts = jamoScalars.prefix(2).reduce(0) { $0 | CharMask.startBit($1) }
        var packedMatch: [UInt64] = []
        if (4...64).contains(jamoScalars.count) {
            packedMatch = [UInt64](repeating: 0, count: 256)
            for (i, v) in jamoScalars.enumerated() {
                // A scalar without a packed byte matches no packed text.
                if let b = PackedJamo.byte(v) { packedMatch[Int(b)] |= 1 << UInt64(i) }
            }
        }
        self.packedMatch = packedMatch
        self.isChoseong = isChoseong
        hasSpace = f.jamo.contains(0x20)
        hasCompatibilityJamo = f.hasCompatibilityJamo
        length = f.length
        isEmpty = compact.isEmpty
    }

    @inline(__always)
    func withView<R>(_ body: (QueryView) throws -> R) rethrows -> R {
        try bytes.withUnsafeBufferPointer { b in
            try packedMatch.withUnsafeBufferPointer { pm in
            try jamoScalars.withUnsafeBufferPointer { s in
                var p = b.baseAddress!
                func take(_ n: Int) -> UnsafeBufferPointer<UInt8> {
                    defer { p += n }
                    return UnsafeBufferPointer(start: p, count: n)
                }
                let norm = take(counts.norm), compact = take(counts.compact)
                let utf8 = QueryForms(jamo: take(counts.jamo), jamoCompact: take(counts.jamoCompact),
                                      spacedJamo: take(counts.jamo + 1), choseong: compact)
                let packed = packable
                    ? QueryForms(jamo: take(counts.packedJamo), jamoCompact: take(counts.packedJamoCompact),
                                 spacedJamo: take(counts.packedJamo + 1), choseong: take(counts.packedChoseong))
                    : nil
                return try body(QueryView(
                    norm: norm, compact: compact, utf8: utf8, packed: packed, scalars: s, mask: mask,
                    typoStarts: typoStarts, packedMatch: pm, isChoseong: isChoseong, hasSpace: hasSpace,
                    hasCompatibilityJamo: hasCompatibilityJamo, length: length, isEmpty: isEmpty))
            }
            }
        }
    }
}

/// One encoding of a query's forms.
struct QueryForms {
    let jamo: UnsafeBufferPointer<UInt8>
    let jamoCompact: UnsafeBufferPointer<UInt8>
    /// " " + jamo: a multi-word query must start right after a space of the term.
    let spacedJamo: UnsafeBufferPointer<UInt8>
    /// The compact text, compared against 초성 forms (packed: only for a 초성 query).
    let choseong: UnsafeBufferPointer<UInt8>
}

struct QueryView {
    /// UTF-8.
    let norm: UnsafeBufferPointer<UInt8>
    let compact: UnsafeBufferPointer<UInt8>
    let utf8: QueryForms
    /// nil when some jamo has no packed byte (then the query cannot match a packed term but by typos).
    let packed: QueryForms?
    let scalars: UnsafeBufferPointer<UInt32>
    let mask: CharMask
    let typoStarts: UInt64
    let packedMatch: UnsafeBufferPointer<UInt64>
    let isChoseong: Bool
    let hasSpace: Bool
    let hasCompatibilityJamo: Bool
    let length: Int
    let isEmpty: Bool

    /// Query scalars that may be absent from a term that still matches (the OSA typo budget).
    var fuzzyMissingBudget: Int {
        guard !isChoseong, length >= 2, scalars.count >= 4 else { return 0 }
        return scalars.count >= 8 ? 2 : 1
    }
}

// MARK: - Matching

/// Scores one query against one term. Score bands never overlap across tiers:
/// exact 1.0 · prefix 0.82–0.90 · word-prefix 0.68–0.76 · substring 0.54–0.62 ·
/// initials/초성 0.38–0.53 · fuzzy 0.18–0.33. Within a band, higher coverage (query/term length) wins.
enum LexicalMatcher {
    struct Match: Sendable {
        var score: Float
        var tier: MatchTier
    }

    static func match(_ q: LexQuery, _ t: LexTerm, allowFuzzy: Bool) -> Match? {
        t.store.withArena { arena in q.withView { match($0, arena.view(0), allowFuzzy: allowFuzzy) } }
    }

    static func match(_ q: QueryView, _ t: TermView, allowFuzzy: Bool) -> Match? {
        guard !q.isEmpty, t.length > 0 else { return nil }
        // A packed term holds only ASCII and jamo: a query with any other character can only match it
        // by typos. In a packed (simple) term, every tier but the OSA typo check puts the query's
        // compact jamo in the term's compact jamo in order (equal, prefix, after a space, inside, as
        // syllable initials or word initials), so one greedy scan rules them all out for most terms.
        let e = t.isPacked ? q.packed : q.utf8
        let span = e.flatMap { subsequenceSpan($0.jamoCompact, t.jamoCompact, packed: t.isPacked) }
        guard let e, span != nil || t.isGeneral else {
            guard allowFuzzy, q.length >= 2, !q.isChoseong else { return nil }
            return matchTypos(q, t)
        }
        if isExact(q, e, t) { return Match(score: 1.0, tier: .exact) }
        let coverage = min(1, Float(q.length) / Float(t.length))

        if Bytes.hasPrefix(t.jamoCompact, e.jamoCompact) || Bytes.hasPrefix(t.jamo, e.jamo) {
            return Match(score: 0.82 + 0.08 * coverage, tier: .prefix)
        }
        if let wordMatch = wordPrefix(q, e, t) {
            return Match(score: 0.68 + 0.08 * (wordMatch ? 1 : coverage), tier: .wordPrefix)
        }
        if q.length >= 2, Bytes.contains(t.jamoCompact, e.jamoCompact) {
            return Match(score: 0.54 + 0.08 * coverage, tier: .substring)
        }
        if q.isChoseong {
            if t.hasHangul, let sub = choseongSubtier(e.choseong, t) {
                // The 초성 form has one scalar per compact scalar.
                let cov = min(1, Float(q.length) / Float(max(1, t.length)))
                return Match(score: 0.38 + 0.03 * Float(sub) + 0.06 * cov, tier: .initials)
            }
        } else if q.length >= 2, !t.initials.isEmpty, Bytes.hasPrefix(t.initials, q.compact) {
            // Initials are UTF-8 in both encodings.
            let cov = Float(q.length) / Float(t.initials.count)
            return Match(score: 0.41 + 0.06 * cov + (cov >= 1 ? 0.06 : 0), tier: .initials)
        }
        guard allowFuzzy, q.length >= 2, !q.isChoseong else { return nil }
        // Typo and in-order subsequence (tighter spans score higher).
        var best = typoScore(q, t)
        if let span {
            let tightness = Float(q.scalars.count) / Float(span.length)
            best = max(best, 0.18 + 0.10 * tightness + (span.start == 0 ? 0.02 : 0))
        }
        return best > 0 ? Match(score: best, tier: .fuzzy) : nil
    }

    /// `match` where only the typo check can succeed (the term lacks some query scalar).
    static func matchTypos(_ q: QueryView, _ t: TermView) -> Match? {
        let best = typoScore(q, t)
        return best > 0 ? Match(score: best, tier: .fuzzy) : nil
    }

    /// `norm == norm || compact == compact`. A simple term (ASCII + syllables) has no compatibility
    /// jamo, and without them keystroke decomposition is injective (each syllable is one consonant,
    /// 1–2 vowel keys and 0–2 final keys, so a jamo run parses back uniquely): equal jamo ⇔ equal
    /// text. A query with compatibility jamo cannot equal a simple term.
    @inline(__always)
    static func isExact(_ q: QueryView, _ e: QueryForms, _ t: TermView) -> Bool {
        if t.isGeneral { return Bytes.equal(q.norm, t.norm) || Bytes.equal(q.compact, t.compact) }
        return !q.hasCompatibilityJamo && Bytes.equal(e.jamoCompact, t.jamoCompact)
    }

    /// Word-boundary prefix. Returns `true` when a whole word equals the query, `false` for a plain
    /// word prefix, nil when no word (after the first) starts with the query.
    private static func wordPrefix(_ q: QueryView, _ e: QueryForms, _ t: TermView) -> Bool? {
        guard t.isMultiWord else { return nil }
        // Multi-word query: must start right after a space in the term.
        if q.hasSpace { return Bytes.contains(t.jamo, e.spacedJamo) ? false : nil }
        if t.isGeneral {
            var found: Bool? = nil
            var words = WordIterator(t.words, separator: t.wordSeparator)
            _ = words.next()
            while let w = words.next() {
                guard Bytes.hasPrefix(w, e.jamoCompact) else { continue }
                if w.count == e.jamoCompact.count { return true }
                found = false
            }
            return found
        }
        // Simple term: the words after the first are exactly the runs that follow a space, so one
        // search for " " + query (the query has no space, so its jamo is its compact jamo) finds them;
        // a whole word also ends at a space or at the end.
        let hay = t.jamo, needle = e.spacedJamo
        var found: Bool? = nil
        var from = 0
        while let at = Bytes.firstIndex(of: needle, in: hay, from: from) {
            let end = at + needle.count
            if end == hay.count || hay[end] == 0x20 { return true }
            found = false
            from = at + 1
        }
        return found
    }

    /// 3 = whole 초성 equal, 2 = 초성 prefix, 1 = a word's 초성 prefix, 0 = 초성 substring.
    private static func choseongSubtier(_ q: UnsafeBufferPointer<UInt8>, _ t: TermView) -> Int? {
        if Bytes.equal(t.choseong, q) { return 3 }
        if Bytes.hasPrefix(t.choseong, q) { return 2 }
        if t.isMultiWord {
            var words = WordIterator(t.wordChoseongs, separator: t.wordSeparator)
            _ = words.next()
            while let w = words.next() { if Bytes.hasPrefix(w, q) { return 1 } }
        }
        if Bytes.contains(t.choseong, q) { return 0 }
        return nil
    }

    /// Typos (Damerau/OSA distance) against each word and against the term prefix of similar length;
    /// 0 when none is close enough.
    private static func typoScore(_ q: QueryView, _ t: TermView) -> Float {
        let qs = q.scalars
        // Every candidate starts at a word start and must begin with the query's first or second
        // character (see `typoDistance`).
        guard qs.count >= 4, t.wordStarts & q.typoStarts != 0 else { return 0 }
        let maxEdits = qs.count >= 8 ? 2 : 1
        if t.isPacked { return packedTypoScore(q, t, maxEdits: maxEdits) }
        var best: Float = 0
        if t.isMultiWord {
            var words = WordIterator(t.words, separator: t.wordSeparator)
            while let w = words.next() {
                if let d = typoDistance(q, w, maxEdits: maxEdits) { best = max(best, 0.33 - 0.04 * Float(d)) }
            }
        }
        let tc = t.jamoCompact
        let cut = Bytes.offset(afterScalars: qs.count, in: tc)
        if cut < tc.count {
            let cut2 = cut + Bytes.scalarLength(tc[cut])
            if let d = typoDistance(q, UnsafeBufferPointer(rebasing: tc[..<cut]), maxEdits: maxEdits) {
                best = max(best, 0.33 - 0.04 * Float(d))
            }
            if let d = typoDistance(q, UnsafeBufferPointer(rebasing: tc[..<cut2]), maxEdits: maxEdits) {
                best = max(best, 0.33 - 0.04 * Float(d))
            }
        } else if let d = typoDistance(q, tc, maxEdits: maxEdits) {
            best = max(best, 0.33 - 0.04 * Float(d))
        }
        return best
    }

    /// `typoScore` for a packed term (one byte per scalar): the length and first-character checks
    /// run inline on bytes, and only candidates that pass them get the bit-parallel distance — or,
    /// for queries beyond its 64 scalars, the DP on the decoded bytes.
    private static func packedTypoScore(_ q: QueryView, _ t: TermView, maxEdits: Int) -> Float {
        let n = q.scalars.count
        let q0 = PackedJamo.byte(q.scalars[0]), q1 = PackedJamo.byte(q.scalars[1])
        // An empty buffer may still have a base address: test emptiness, not the pointer.
        let match = q.packedMatch.isEmpty ? nil : q.packedMatch.baseAddress
        var best: Float = 0
        @inline(__always) func consider(_ c: UnsafeBufferPointer<UInt8>) {
            guard abs(c.count - n) <= maxEdits, !c.isEmpty,
                  c[0] == q0 || (c.count > 1 && c[0] == q1 && c[1] == q0) else { return }
            let distance: Int?
            if let match {
                distance = EditDistance.osa(packedMatch: match, patternLength: n, c, limit: maxEdits)
            } else {
                distance = withUnsafeTemporaryAllocation(of: UInt32.self, capacity: c.count) { buf in
                    for (i, b) in c.enumerated() { buf[i] = PackedJamo.scalar(b) }
                    return EditDistance.osa(q.scalars, UnsafeBufferPointer(buf), limit: maxEdits)
                }
            }
            if let d = distance { best = max(best, 0.33 - 0.04 * Float(d)) }
        }
        if t.isMultiWord {
            var words = WordIterator(t.words, separator: 0x20)
            while let w = words.next() { consider(w) }
        }
        let tc = t.jamoCompact
        if tc.count > n {
            consider(UnsafeBufferPointer(rebasing: tc[..<n]))
            consider(UnsafeBufferPointer(rebasing: tc[..<(n + 1)]))
        } else {
            consider(tc)
        }
        return best
    }

    /// OSA distance between the query scalars and UTF-8 candidate `c`, nil when the first characters
    /// are implausible, the lengths differ by more than `maxEdits`, or the distance exceeds it. Only
    /// the candidates that pass the cheap checks are decoded.
    private static func typoDistance(_ q: QueryView, _ c: UnsafeBufferPointer<UInt8>, maxEdits: Int) -> Int? {
        let qs = q.scalars
        guard !c.isEmpty else { return nil }
        // Plausibility first (most candidates fail it): typos rarely hit the first character, so the
        // first characters must agree, or the first two be transposed.
        let (c0, n0) = Bytes.scalar(at: 0, in: c)
        if qs[0] != c0 {
            guard qs.count > 1, n0 < c.count, qs[1] == c0, Bytes.scalar(at: n0, in: c).value == qs[0] else {
                return nil
            }
        }
        let count = Bytes.scalarCount(c)
        guard abs(count - qs.count) <= maxEdits else { return nil }
        return withUnsafeTemporaryAllocation(of: UInt32.self, capacity: count) { buf in
            EditDistance.osa(qs, Bytes.decodeUTF8(c, into: buf.baseAddress!), limit: maxEdits)
        }
    }

    /// Greedy left-to-right subsequence match of the query's scalars in the term's (same encoding);
    /// returns the start and span length in scalars.
    static func subsequenceSpan(_ q: UnsafeBufferPointer<UInt8>, _ t: UnsafeBufferPointer<UInt8>,
                                packed: Bool) -> (start: Int, length: Int)? {
        guard !q.isEmpty else { return nil }
        if packed {
            var qi = 0, start = -1
            var want = q[0]
            for ti in 0..<t.count where t[ti] == want {
                if start < 0 { start = ti }
                qi += 1
                if qi == q.count { return (start, ti - start + 1) }
                want = q[qi]
            }
            return nil
        }
        var qi = 0, ql = Bytes.scalarLength(q[0])
        var ti = 0, scalar = 0, start = -1
        while ti < t.count {
            let tl = Bytes.scalarLength(t[ti])
            if tl == ql, Bytes.sameScalar(t, ti, q, qi, tl) {
                if start < 0 { start = scalar }
                qi += ql
                if qi == q.count { return (start, scalar - start + 1) }
                ql = Bytes.scalarLength(q[qi])
            }
            ti += tl
            scalar += 1
        }
        return nil
    }
}

/// Runs of a byte string between `separator` bytes (no closures: hot-loop friendly).
struct WordIterator {
    private let bytes: UnsafeBufferPointer<UInt8>
    private let separator: UInt8
    private var start = 0

    init(_ bytes: UnsafeBufferPointer<UInt8>, separator: UInt8) {
        self.bytes = bytes
        self.separator = separator
    }

    @inline(__always)
    mutating func next() -> UnsafeBufferPointer<UInt8>? {
        guard start <= bytes.count, bytes.count > 0 else { return nil }
        var end = start
        while end < bytes.count, bytes[end] != separator { end += 1 }
        defer { start = end + 1 }
        return UnsafeBufferPointer(rebasing: bytes[start..<end])
    }
}

enum Bytes {
    @inline(__always)
    static func equal(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>) -> Bool {
        a.count == b.count && (a.isEmpty || memcmp(a.baseAddress!, b.baseAddress!, a.count) == 0)
    }

    @inline(__always)
    static func hasPrefix(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>) -> Bool {
        guard b.count <= a.count else { return false }
        // Most terms already differ in the first byte.
        return b.isEmpty || (a[0] == b[0] && memcmp(a.baseAddress!, b.baseAddress!, b.count) == 0)
    }

    @inline(__always)
    static func contains(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>) -> Bool {
        b.isEmpty || firstIndex(of: b, in: a, from: 0) != nil
    }

    /// Index of the first occurrence of non-empty `needle` in `hay` at or after `from`. Terms are
    /// tens of bytes, where a plain scan beats `memmem`'s setup; checking the needle's last byte first
    /// skips the lead byte that UTF-8 jamo share.
    @inline(__always)
    static func firstIndex(of needle: UnsafeBufferPointer<UInt8>, in hay: UnsafeBufferPointer<UInt8>, from: Int) -> Int? {
        let n = needle.count
        guard n > 0, from + n <= hay.count else { return nil }
        let first = needle[0], last = needle[n - 1]
        var i = from
        while i <= hay.count - n {
            if hay[i + n - 1] == last, hay[i] == first {
                var j = 1
                while j < n - 1, hay[i + j] == needle[j] { j += 1 }
                if j >= n - 1 { return i }
            }
            i += 1
        }
        return nil
    }

    /// Equal UTF-8 sequences of length `n` (1…4) at `a[i]` and `b[j]`.
    @inline(__always)
    static func sameScalar(_ a: UnsafeBufferPointer<UInt8>, _ i: Int, _ b: UnsafeBufferPointer<UInt8>, _ j: Int, _ n: Int) -> Bool {
        // Compare the last byte first: in UTF-8 jamo the lead (E3) and middle bytes rarely differ.
        guard a[i + n - 1] == b[j + n - 1], a[i] == b[j] else { return false }
        return n < 3 || (a[i + 1] == b[j + 1] && (n < 4 || a[i + 2] == b[j + 2]))
    }

    // UTF-8 scalar helpers (packed jamo needs none: one byte per scalar).

    /// Byte length of the UTF-8 sequence that starts with `lead`.
    @inline(__always)
    static func scalarLength(_ lead: UInt8) -> Int { lead < 0x80 ? 1 : lead < 0xE0 ? 2 : lead < 0xF0 ? 3 : 4 }

    @inline(__always)
    static func scalarCount(_ a: UnsafeBufferPointer<UInt8>) -> Int {
        var n = 0
        for b in a where b & 0xC0 != 0x80 { n += 1 }
        return n
    }

    /// Byte offset just past the first `k` scalars (`a.count` when there are fewer).
    @inline(__always)
    static func offset(afterScalars k: Int, in a: UnsafeBufferPointer<UInt8>) -> Int {
        var i = 0, n = 0
        while i < a.count, n < k { i += scalarLength(a[i]); n += 1 }
        return min(i, a.count)
    }

    /// The scalar starting at byte `i` and its byte length.
    @inline(__always)
    static func scalar(at i: Int, in a: UnsafeBufferPointer<UInt8>) -> (value: UInt32, length: Int) {
        let b = UInt32(a[i])
        switch scalarLength(a[i]) {
        case 1: return (b, 1)
        case 2: return ((b & 0x1F) << 6 | UInt32(a[i + 1]) & 0x3F, 2)
        case 3: return ((b & 0x0F) << 12 | (UInt32(a[i + 1]) & 0x3F) << 6 | UInt32(a[i + 2]) & 0x3F, 3)
        default:
            return ((b & 0x07) << 18 | (UInt32(a[i + 1]) & 0x3F) << 12 | (UInt32(a[i + 2]) & 0x3F) << 6
                    | UInt32(a[i + 3]) & 0x3F, 4)
        }
    }

    /// Decodes well-formed UTF-8 (bytes of a Swift String).
    @inline(__always)
    static func decodeUTF8(_ a: UnsafeBufferPointer<UInt8>, _ body: (UInt32) -> Void) {
        var i = 0
        while i < a.count {
            let (v, n) = scalar(at: i, in: a)
            body(v)
            i += n
        }
    }

    /// Decodes into `out` (room for one scalar per byte) and returns the filled part.
    @inline(__always)
    static func decodeUTF8(_ a: UnsafeBufferPointer<UInt8>, into out: UnsafeMutablePointer<UInt32>) -> UnsafeBufferPointer<UInt32> {
        var i = 0, n = 0
        while i < a.count {
            let (v, len) = scalar(at: i, in: a)
            out[n] = v
            n += 1
            i += len
        }
        return UnsafeBufferPointer(start: out, count: n)
    }
}

enum EditDistance {
    /// Optimal-string-alignment distance (adjacent transpositions count as 1); nil when > limit.
    static func osa(_ a: ArraySlice<UInt32>, _ b: ArraySlice<UInt32>, limit: Int) -> Int? {
        a.withContiguousStorageIfAvailable { pa in
            b.withContiguousStorageIfAvailable { pb in osa(pa, pb, limit: limit) } ?? nil
        } ?? nil
    }

    /// `osa(pattern, text)` for a pattern of 1…64 scalars against packed text, bit-parallel
    /// (Hyyrö 2003: Myers' bit-vector edit distance with the transposition term): one column of the
    /// DP per text byte in a few word operations. `packedMatch[b]` has bit i set when pattern
    /// scalar i packs to byte b.
    @inline(__always)
    static func osa(packedMatch: UnsafePointer<UInt64>, patternLength m: Int, _ text: UnsafeBufferPointer<UInt8>,
                    limit: Int) -> Int? {
        var vp: UInt64 = ~0, vn: UInt64 = 0, d0: UInt64 = 0, previous: UInt64 = 0
        var distance = m
        let last: UInt64 = 1 << UInt64(m - 1)
        for b in text {
            let pm = packedMatch[Int(b)]
            let transposition = ((~d0 & pm) << 1) & previous
            d0 = (((pm & vp) &+ vp) ^ vp) | pm | vn | transposition
            var hp = vn | ~(d0 | vp)
            var hn = d0 & vp
            if hp & last != 0 { distance += 1 } else if hn & last != 0 { distance -= 1 }
            hp = (hp << 1) | 1
            hn <<= 1
            vp = hn | ~(d0 | hp)
            vn = hp & d0
            previous = pm
        }
        return distance <= limit ? distance : nil
    }

    /// Allocation-free (stack buffers) because it runs inside the per-keystroke term scan.
    static func osa(_ pa: UnsafeBufferPointer<UInt32>, _ pb: UnsafeBufferPointer<UInt32>, limit: Int) -> Int? {
        let n = pa.count, m = pb.count
        if abs(n - m) > limit { return nil }
        if n == 0 { return m <= limit ? m : nil }
        if m == 0 { return n <= limit ? n : nil }
        return withUnsafeTemporaryAllocation(of: Int.self, capacity: 3 * (m + 1)) { buf -> Int? in
            var prev2 = buf.baseAddress!
            var prev = prev2 + (m + 1)
            var cur = prev + (m + 1)
            for j in 0...m { prev[j] = j; prev2[j] = 0 }
            for i in 1...n {
                cur[0] = i
                var rowMin = i
                let ai = pa[i - 1]
                for j in 1...m {
                    let cost = ai == pb[j - 1] ? 0 : 1
                    var v = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                    if i > 1, j > 1, ai == pb[j - 2], pa[i - 2] == pb[j - 1] {
                        v = min(v, prev2[j - 2] + 1)
                    }
                    cur[j] = v
                    if v < rowMin { rowMin = v }
                }
                if rowMin > limit { return nil }
                (prev2, prev, cur) = (prev, cur, prev2)
            }
            return prev[m] <= limit ? prev[m] : nil
        }
    }
}
