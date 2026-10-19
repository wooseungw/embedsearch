import SearchCore

/// Sample items for UI development until the real `SearchEngine` is wired in (see AppServices).
/// Ids, actions and icons follow the conventions in docs/DESIGN.md.
enum MockCatalog {
    static let items: [SearchItem] = apps + settings + commands + shortcuts

    // MARK: Apps

    static let apps: [SearchItem] = [
        app("com.apple.calculator", "계산기", "Calculator", "/System/Applications/Calculator.app",
            ["계산", "calc", "사칙연산", "math"]),
        app("com.apple.Safari", "Safari", "웹 브라우저", "/Applications/Safari.app",
            ["사파리", "browser", "웹", "인터넷"]),
        app("com.apple.Notes", "메모", "Notes", "/System/Applications/Notes.app", ["노트", "note"]),
        app("com.apple.iCal", "캘린더", "Calendar", "/System/Applications/Calendar.app",
            ["달력", "일정", "calendar"]),
        app("com.apple.mail", "메일", "Mail", "/System/Applications/Mail.app", ["이메일", "email"]),
        app("com.apple.MobileSMS", "메시지", "Messages", "/System/Applications/Messages.app",
            ["문자", "imessage", "sms"]),
        app("com.apple.Music", "음악", "Music", "/System/Applications/Music.app", ["뮤직", "노래"]),
        app("com.apple.Photos", "사진", "Photos", "/System/Applications/Photos.app", ["포토", "앨범"]),
        app("com.apple.Maps", "지도", "Maps", "/System/Applications/Maps.app", ["맵", "길찾기"]),
        app("com.apple.reminders", "미리 알림", "Reminders", "/System/Applications/Reminders.app",
            ["할 일", "todo", "리마인더"]),
        app("com.apple.systempreferences", "시스템 설정", "System Settings",
            "/System/Applications/System Settings.app", ["환경설정", "preferences", "설정"]),
        app("com.apple.Terminal", "터미널", "Terminal", "/System/Applications/Utilities/Terminal.app",
            ["shell", "콘솔", "zsh"]),
        app("com.apple.ActivityMonitor", "활성 상태 보기", "Activity Monitor",
            "/System/Applications/Utilities/Activity Monitor.app", ["작업 관리자", "cpu", "프로세스"]),
        app("com.apple.AppStore", "App Store", "앱 스토어", "/System/Applications/App Store.app",
            ["앱스토어", "앱 설치"]),
        app("com.apple.finder", "Finder", "파인더", "/System/Library/CoreServices/Finder.app",
            ["파일", "탐색기"]),
        app("com.apple.Preview", "미리보기", "Preview", "/System/Applications/Preview.app", ["pdf", "이미지 보기"]),
        app("com.apple.TextEdit", "텍스트 편집기", "TextEdit", "/System/Applications/TextEdit.app",
            ["텍스트", "메모장"]),
        app("com.apple.FaceTime", "FaceTime", "영상 통화", "/System/Applications/FaceTime.app", ["페이스타임"]),
        app("com.apple.weather", "날씨", "Weather", "/System/Applications/Weather.app", ["기온", "weather"]),
        app("com.apple.clock", "시계", "Clock", "/System/Applications/Clock.app", ["타이머", "알람", "스톱워치"]),
        app("com.apple.Screenshot", "스크린샷", "Screenshot", "/System/Applications/Utilities/Screenshot.app",
            ["화면 캡처", "capture"]),
        app("com.apple.shortcuts", "단축어", "Shortcuts", "/System/Applications/Shortcuts.app", ["shortcuts", "자동화"]),
    ]

    // MARK: System Settings panes

    static let settings: [SearchItem] = [
        setting("com.apple.BluetoothSettings", "root", "블루투스", "시스템 설정 › Bluetooth",
                ["블루투스", "에어팟", "airpods"]),
        setting("com.apple.wifi-settings-extension", "root", "Wi-Fi", "시스템 설정 › Wi-Fi",
                ["와이파이", "무선 네트워크", "인터넷 연결"]),
        setting("com.apple.Displays-Settings.extension", "root", "디스플레이", "시스템 설정 › 디스플레이",
                ["모니터", "해상도", "밝기"]),
        setting("com.apple.Sound-Settings.extension", "root", "사운드", "시스템 설정 › 사운드",
                ["소리", "음량", "출력"]),
        setting("com.apple.Battery-Settings.extension", "root", "배터리", "시스템 설정 › 배터리",
                ["전원", "저전력 모드"]),
        setting("com.apple.Keyboard-Settings.extension", "root", "키보드", "시스템 설정 › 키보드",
                ["입력 소스", "한영 전환", "단축키"]),
        setting("com.apple.settings.PrivacySecurity.extension", "Privacy_AllFiles", "전체 디스크 접근 권한",
                "시스템 설정 › 개인정보 보호 및 보안", ["full disk access", "권한", "개인정보"]),
        setting("com.apple.Notifications-Settings.extension", "root", "알림", "시스템 설정 › 알림",
                ["notification", "방해 금지"]),
        setting("com.apple.Desktop-Settings.extension", "root", "데스크탑 및 Dock", "시스템 설정 › 데스크탑 및 Dock",
                ["독", "dock", "핫 코너"]),
        setting("com.apple.Appearance-Settings.extension", "root", "화면 모드", "시스템 설정 › 화면 모드",
                ["다크 모드", "라이트 모드", "appearance"]),
        setting("com.apple.Trackpad-Settings.extension", "root", "트랙패드", "시스템 설정 › 트랙패드",
                ["제스처", "클릭"]),
        setting("com.apple.Wallpaper-Settings.extension", "root", "배경화면", "시스템 설정 › 배경화면",
                ["바탕화면", "wallpaper"]),
    ]

    // MARK: Built-in commands

    static let commands: [SearchItem] = [
        command("lock-screen", "화면 잠금", "Lock Screen", "lock.fill", ["잠금", "lock"]),
        command("sleep", "잠자기", "Sleep", "moon.zzz.fill", ["슬립", "절전"]),
        command("display-sleep", "디스플레이 끄기", "Turn Off Display", "display", ["화면 끄기", "모니터 끄기"]),
        command("screen-saver", "화면 보호기 시작", "Start Screen Saver", "sparkles.tv", ["스크린세이버"]),
        command("toggle-dark-mode", "다크 모드 전환", "Toggle Dark Mode", "circle.lefthalf.filled",
                ["다크 모드", "라이트 모드", "dark mode"]),
        command("toggle-mute", "음소거 전환", "Toggle Mute", "speaker.slash.fill", ["음소거", "mute"]),
        command("volume-up", "볼륨 높이기", "Volume Up", "speaker.wave.3.fill", ["소리 크게", "볼륨 업"]),
        command("volume-down", "볼륨 낮추기", "Volume Down", "speaker.wave.1.fill", ["소리 작게", "볼륨 다운"]),
        command("screenshot", "스크린샷 찍기", "Take Screenshot", "camera.viewfinder", ["캡처", "화면 캡처"]),
        command("toggle-hidden-files", "숨김 파일 보기 전환", "Toggle Hidden Files", "eye.slash",
                ["숨김 파일", "hidden files"]),
        command("open-downloads", "다운로드 폴더 열기", "Open Downloads", "arrow.down.circle", ["다운로드", "downloads"]),
        command("open-desktop", "데스크탑 폴더 열기", "Open Desktop", "menubar.dock.rectangle", ["바탕화면 폴더"]),
        command("open-documents", "문서 폴더 열기", "Open Documents", "doc.text", ["도큐먼트", "documents"]),
        command("open-home", "홈 폴더 열기", "Open Home", "house", ["홈", "home"]),
        command("restart-finder", "Finder 재시작", "Restart Finder", "arrow.clockwise", ["파인더 재시작"]),
        command("restart-dock", "Dock 재시작", "Restart Dock", "arrow.triangle.2.circlepath", ["독 재시작"]),
        command("empty-trash", "휴지통 비우기", "Empty Trash", "trash", ["휴지통", "trash"], confirm: true),
        command("eject-all", "모든 디스크 추출", "Eject All Disks", "eject.fill", ["추출", "eject"], confirm: true),
        command("restart", "재시동", "Restart", "arrow.counterclockwise", ["재부팅", "다시 시작", "reboot"], confirm: true),
        command("shut-down", "시스템 종료", "Shut Down", "power", ["전원 끄기", "shutdown"], confirm: true),
        command("log-out", "로그아웃", "Log Out", "rectangle.portrait.and.arrow.right", ["logout"], confirm: true),
    ]

    // MARK: Shortcuts (sample names; may not exist on this Mac)

    static let shortcuts: [SearchItem] = [
        shortcut("집중 모드 켜기", "Focus On", ["집중", "방해 금지 켜기"]),
        shortcut("오늘 일정 요약", "Today's Agenda", ["일정 요약", "agenda"]),
    ]

    // MARK: Builders

    private static func app(_ bundleID: String, _ title: String, _ subtitle: String, _ path: String,
                            _ keywords: [String]) -> SearchItem {
        SearchItem(
            id: "app:\(bundleID)", kind: .application, title: title, subtitle: subtitle,
            keywords: [title, subtitle] + keywords, embeddingTitle: title,
            embeddingText: "\(title) (\(subtitle)) 앱. " + keywords.joined(separator: ", "),
            action: .openApplication(path: path), icon: .filePath(path))
    }

    private static func setting(_ extensionID: String, _ anchor: String, _ title: String, _ subtitle: String,
                                _ keywords: [String]) -> SearchItem {
        let url = anchor == "root"
            ? "x-apple.systempreferences:\(extensionID)"
            : "x-apple.systempreferences:\(extensionID)?\(anchor)"
        return SearchItem(
            id: "setting:\(extensionID)#\(anchor)", kind: .systemSetting, title: title, subtitle: subtitle,
            keywords: [title] + keywords, embeddingTitle: title,
            embeddingText: "\(subtitle) 설정 패널. " + keywords.joined(separator: ", "),
            action: .openURL(url), icon: .filePath("/System/Applications/System Settings.app"))
    }

    private static func command(_ id: String, _ title: String, _ english: String, _ symbol: String,
                                _ keywords: [String], confirm: Bool = false) -> SearchItem {
        SearchItem(
            id: "cmd:\(id)", kind: .command, title: title, subtitle: english,
            keywords: [title, english] + keywords, embeddingTitle: title,
            embeddingText: "\(title) (\(english)) 명령. " + keywords.joined(separator: ", "),
            action: .builtinCommand(id: id), icon: .systemSymbol(symbol), requiresConfirmation: confirm)
    }

    private static func shortcut(_ name: String, _ english: String, _ keywords: [String]) -> SearchItem {
        SearchItem(
            id: "shortcut:\(name)", kind: .shortcut, title: name, subtitle: "단축어 · \(english)",
            keywords: [name, english] + keywords, embeddingTitle: name,
            embeddingText: "\(name) 단축어. " + keywords.joined(separator: ", "),
            action: .runShortcut(name: name), icon: .systemSymbol("square.stack.3d.up.fill"))
    }
}
