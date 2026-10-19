import Testing
@testable import SearchCore

@Suite("Text normalization")
struct TextNormalizerTests {
    @Test func nfcLowercaseAndSeparators() {
        // NFD "사파리" (as Spotlight returns it) becomes NFC.
        let nfd = "\u{1109}\u{1161}\u{1111}\u{1161}\u{1105}\u{1175}"
        #expect(TextNormalizer.normalize(nfd) == "사파리")
        #expect(TextNormalizer.normalize("  Wi‑Fi  Settings ") == "wi fi settings")
        #expect(TextNormalizer.compact("Wi‑Fi") == "wifi")
        #expect(TextNormalizer.normalize("Touch\u{00A0}ID 및 암호") == "touch id 및 암호")
        #expect(TextNormalizer.normalize("스크롤 속도(마우스)") == "스크롤 속도 마우스")
        #expect(TextNormalizer.normalize("ＡＢＣ１２") == "abc12")
        #expect(TextNormalizer.words("AirDrop & Handoff") == ["airdrop", "handoff"])
    }
}

@Suite("Hangul")
struct HangulTests {
    @Test func choseong() {
        #expect(Hangul.choseongString("계산기") == "ㄱㅅㄱ")
        #expect(Hangul.choseongString("시스템 설정") == "ㅅㅅㅌ ㅅㅈ")
        #expect(Hangul.choseongString("카카오톡") == "ㅋㅋㅇㅌ")
        #expect(Hangul.choseongString("Wi-Fi 연결") == "Wi-Fi ㅇㄱ")
    }

    @Test func choseongQueryDetection() {
        #expect(Hangul.isChoseongQuery("ㄱㅅㄱ"))
        #expect(Hangul.isChoseongQuery("ㅅㅅㅌ ㅅㅈ"))
        #expect(!Hangul.isChoseongQuery("ㄱㅅ기"))
        #expect(!Hangul.isChoseongQuery("abc"))
        #expect(!Hangul.isChoseongQuery(" "))
    }

    @Test func keystrokeJamo() {
        #expect(Hangul.keystrokeJamo("계산기") == "ㄱㅖㅅㅏㄴㄱㅣ")
        #expect(Hangul.keystrokeJamo("값") == "ㄱㅏㅂㅅ")         // compound final split
        #expect(Hangul.keystrokeJamo("와") == "ㅇㅗㅏ")          // compound vowel split
        #expect(Hangul.keystrokeJamo("ㄳ") == "ㄱㅅ")
        #expect(Hangul.keystrokeJamo("Mac 앱") == "Mac ㅇㅐㅂ")
        // A partially typed last syllable is a jamo prefix of the full word.
        #expect(Hangul.keystrokeJamo("계산기").hasPrefix(Hangul.keystrokeJamo("계사")))
        #expect(Hangul.keystrokeJamo("갑시다").hasPrefix(Hangul.keystrokeJamo("값")))
    }
}

@Suite("Query analysis")
struct QueryAnalyzerTests {
    @Test func kindWordsRouteAndAreStripped() {
        let a = QueryAnalyzer.analyze("블루투스 설정")
        #expect(a.contentTokens.map { $0[0] } == ["블루투스"])
        #expect(a.intents[.systemSetting] == 1.0)

        let app = QueryAnalyzer.analyze("메모 앱")
        #expect(app.contentTokens.map { $0[0] } == ["메모"])
        #expect(app.intents[.application] == 1.0)
    }

    @Test func loneKindWordIsSearchedLiterally() {
        let a = QueryAnalyzer.analyze("설정")
        #expect(a.contentTokens == [["설정"]])
        #expect(a.intents.isEmpty)
    }

    @Test func verbsHintWithoutStripping() {
        let a = QueryAnalyzer.analyze("화면 잠금")
        #expect(a.contentTokens.map { $0[0] } == ["화면", "잠금"])
        #expect(a.intents[.command] == 0.5)
    }

    @Test func particlesAndStopwords() {
        let a = QueryAnalyzer.analyze("how to turn off the bluetooth")
        #expect(a.contentTokens.map { $0[0] } == ["turn", "off", "bluetooth"])
        #expect(QueryAnalyzer.variants(of: "설정을") == ["설정을", "설정"])
        #expect(QueryAnalyzer.variants(of: "앱에서") == ["앱에서", "앱"])
        #expect(QueryAnalyzer.variants(of: "디스플레이") == ["디스플레이", "디스플레"])  // ambiguous → both kept
        #expect(QueryAnalyzer.variants(of: "메모") == ["메모"])
    }
}
