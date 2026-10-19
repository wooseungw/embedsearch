import Foundation

/// Canonical text form shared by item terms and queries.
///
/// `normalize` = NFC → lowercase → width/dash/space unification → punctuation and symbols become
/// word separators → whitespace collapsed. `compact` drops the separators, so "Wi‑Fi", "wi fi" and
/// "wifi" (or "시스템설정" and "시스템 설정") meet in the same form.
public enum TextNormalizer {
    public static func normalize(_ text: String) -> String {
        if let fast = normalizeASCIIAndSyllables(text) { return fast }
        let lowered = text.precomposedStringWithCanonicalMapping.lowercased()
        var out = String.UnicodeScalarView()
        out.reserveCapacity(lowered.unicodeScalars.count)
        var pendingSpace = false
        for scalar in lowered.unicodeScalars {
            if let mapped = mapScalar(scalar) {
                if pendingSpace && !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(mapped)
            } else {
                pendingSpace = true
            }
        }
        return String(out)
    }

    /// `normalize` without word separators.
    public static func compact(_ text: String) -> String {
        let norm = normalize(text)
        // Only in ASCII + syllable text is every space its own grapheme; elsewhere a space followed
        // by a combining mark is part of a character and `replacingOccurrences` keeps it.
        guard isASCIIOrSyllables(norm) else { return norm.replacingOccurrences(of: " ", with: "") }
        return String(decoding: norm.utf8.filter { $0 != 0x20 }, as: UTF8.self)
    }

    /// Words of the normalized form.
    public static func words(_ text: String) -> [String] {
        normalize(text).split(separator: " ").map(String.init)
    }

    /// True when every scalar is ASCII or a precomposed Hangul syllable.
    static func isASCIIOrSyllables(_ text: String) -> Bool {
        var text = text
        return text.withUTF8 { b in
            var i = 0
            while i < b.count {
                if b[i] < 0x80 { i += 1; continue }
                guard b[i] >= 0xEA, b[i] <= 0xED, i + 2 < b.count,
                      Hangul.isSyllable((UInt32(b[i] & 0x0F) << 12) | (UInt32(b[i + 1] & 0x3F) << 6) | UInt32(b[i + 2] & 0x3F))
                else { return false }
                i += 3
            }
            return true
        }
    }

    /// Byte-level fast path for text made only of ASCII and precomposed Hangul syllables (nearly every
    /// title, keyword and query). Such text is already NFC, only A–Z change case, letters/digits/syllables
    /// are kept and every other ASCII character is a separator — exactly what the general path does.
    /// Returns nil (general path) for anything else.
    static func normalizeASCIIAndSyllables(_ text: String) -> String? {
        guard isASCIIOrSyllables(text) else { return nil }
        var text = text
        return text.withUTF8 { src -> String? in
            let n = src.count
            // Output never outgrows the input: a separator is only written in place of a dropped byte.
            return String(unsafeUninitializedCapacity: n) { dst -> Int in
                var o = 0
                var pendingSpace = false
                var i = 0
                while i < n {
                    let b = src[i]
                    if b < 0x80 {
                        let lowered = b &- 0x41 < 26 ? b | 0x20 : b
                        if lowered &- 0x61 < 26 || lowered &- 0x30 < 10 {
                            if pendingSpace && o > 0 { dst[o] = 0x20; o += 1 }
                            pendingSpace = false
                            dst[o] = lowered
                            o += 1
                        } else {
                            pendingSpace = true
                        }
                        i += 1
                    } else {
                        if pendingSpace && o > 0 { dst[o] = 0x20; o += 1 }
                        pendingSpace = false
                        dst[o] = b
                        dst[o + 1] = src[i + 1]
                        dst[o + 2] = src[i + 2]
                        o += 3
                        i += 3
                    }
                }
                return o
            }
        }
    }

    /// Returns the scalar to keep, or nil when the scalar is a word separator.
    private static func mapScalar(_ s: Unicode.Scalar) -> Unicode.Scalar? {
        let v = s.value
        // Fullwidth ASCII → ASCII (already lowercased by `lowercased()`).
        if (0xFF01...0xFF5E).contains(v), let ascii = Unicode.Scalar(v - 0xFEE0) {
            return mapScalar(ascii)
        }
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber, .nonspacingMark, .spacingMark, .enclosingMark:
            return s
        default:
            return nil
        }
    }
}
