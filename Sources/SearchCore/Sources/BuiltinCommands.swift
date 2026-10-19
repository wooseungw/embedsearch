/// Built-in commands. The App's command runner executes them by `id` (`ItemAction.builtinCommand`);
/// SearchCore only describes them. Ids are fixed by docs/DESIGN.md.
public struct BuiltinCommand: Sendable, Hashable {
    public let id: String
    public let titleKo: String
    public let titleEn: String
    public let descriptionKo: String
    public let descriptionEn: String
    public let synonyms: [String]
    public let symbol: String
    public let requiresConfirmation: Bool

    public var itemID: String { "cmd:\(id)" }
}

public enum BuiltinCommands {
    public static let all: [BuiltinCommand] = [
        BuiltinCommand(
            id: "lock-screen", titleKo: "화면 잠금", titleEn: "Lock Screen",
            descriptionKo: "맥을 즉시 잠그고 로그인 화면으로 전환합니다", descriptionEn: "Lock the Mac immediately",
            synonyms: ["잠금", "잠그기", "화면 잠그기", "맥 잠그기", "lock", "lock mac", "lock computer"],
            symbol: "lock.fill", requiresConfirmation: false),
        BuiltinCommand(
            id: "sleep", titleKo: "잠자기", titleEn: "Sleep",
            descriptionKo: "맥을 잠자기 모드로 전환합니다", descriptionEn: "Put the Mac to sleep",
            synonyms: ["잠자기 모드", "절전", "슬립", "컴퓨터 재우기", "sleep mac", "sleep computer", "suspend"],
            symbol: "moon.zzz.fill", requiresConfirmation: false),
        BuiltinCommand(
            id: "display-sleep", titleKo: "디스플레이 끄기", titleEn: "Turn Off Display",
            descriptionKo: "화면(디스플레이)만 잠자기 상태로 끕니다", descriptionEn: "Put only the display to sleep",
            synonyms: ["화면 끄기", "모니터 끄기", "디스플레이 잠자기", "display sleep", "screen off", "monitor off", "sleep display"],
            symbol: "display", requiresConfirmation: false),
        BuiltinCommand(
            id: "screen-saver", titleKo: "화면 보호기 시작", titleEn: "Start Screen Saver",
            descriptionKo: "화면 보호기를 바로 실행합니다", descriptionEn: "Start the screen saver now",
            synonyms: ["화면 보호기", "스크린세이버", "screensaver", "screen saver"],
            symbol: "sparkles.tv", requiresConfirmation: false),
        BuiltinCommand(
            id: "restart", titleKo: "재시동", titleEn: "Restart",
            descriptionKo: "맥을 다시 시작합니다", descriptionEn: "Restart the Mac",
            synonyms: ["재시작", "다시 시작", "재부팅", "리부트", "restart mac", "reboot"],
            symbol: "arrow.clockwise.circle", requiresConfirmation: true),
        BuiltinCommand(
            id: "shut-down", titleKo: "시스템 종료", titleEn: "Shut Down",
            descriptionKo: "맥의 전원을 끕니다", descriptionEn: "Shut down the Mac",
            synonyms: ["종료", "전원 끄기", "컴퓨터 끄기", "맥 끄기", "shutdown", "power off", "turn off computer"],
            symbol: "power", requiresConfirmation: true),
        BuiltinCommand(
            id: "log-out", titleKo: "로그아웃", titleEn: "Log Out",
            descriptionKo: "현재 사용자 계정에서 로그아웃합니다", descriptionEn: "Log out of the current user account",
            synonyms: ["로그 아웃", "사용자 로그아웃", "logout", "sign out"],
            symbol: "rectangle.portrait.and.arrow.right", requiresConfirmation: true),
        BuiltinCommand(
            id: "empty-trash", titleKo: "휴지통 비우기", titleEn: "Empty Trash",
            descriptionKo: "휴지통에 있는 모든 항목을 영구 삭제합니다", descriptionEn: "Permanently delete everything in the Trash",
            synonyms: ["휴지통", "쓰레기통 비우기", "trash", "empty bin", "clear trash"],
            symbol: "trash", requiresConfirmation: true),
        BuiltinCommand(
            id: "toggle-dark-mode", titleKo: "다크 모드 전환", titleEn: "Toggle Dark Mode",
            descriptionKo: "다크 모드와 라이트 모드를 전환합니다", descriptionEn: "Switch between dark and light appearance",
            synonyms: ["다크 모드", "다크모드", "라이트 모드", "어두운 모드", "야간 모드", "dark mode", "light mode", "appearance"],
            symbol: "circle.lefthalf.filled", requiresConfirmation: false),
        BuiltinCommand(
            id: "toggle-mute", titleKo: "음소거 전환", titleEn: "Toggle Mute",
            descriptionKo: "소리를 끄거나 다시 켭니다", descriptionEn: "Mute or unmute the sound",
            synonyms: ["음소거", "소리 끄기", "무음", "mute", "unmute", "silence"],
            symbol: "speaker.slash.fill", requiresConfirmation: false),
        BuiltinCommand(
            id: "volume-up", titleKo: "볼륨 높이기", titleEn: "Volume Up",
            descriptionKo: "출력 음량을 높입니다", descriptionEn: "Raise the output volume",
            synonyms: ["소리 키우기", "음량 높이기", "볼륨 업", "louder", "increase volume"],
            symbol: "speaker.wave.3.fill", requiresConfirmation: false),
        BuiltinCommand(
            id: "volume-down", titleKo: "볼륨 낮추기", titleEn: "Volume Down",
            descriptionKo: "출력 음량을 낮춥니다", descriptionEn: "Lower the output volume",
            synonyms: ["소리 줄이기", "음량 낮추기", "볼륨 다운", "quieter", "decrease volume"],
            symbol: "speaker.wave.1.fill", requiresConfirmation: false),
        BuiltinCommand(
            id: "screenshot", titleKo: "스크린샷 찍기", titleEn: "Take Screenshot",
            descriptionKo: "화면을 캡처합니다", descriptionEn: "Capture the screen",
            synonyms: ["스크린샷", "화면 캡처", "캡쳐", "화면 찍기", "screenshot", "screen capture", "capture screen"],
            symbol: "camera.viewfinder", requiresConfirmation: false),
        BuiltinCommand(
            id: "toggle-hidden-files", titleKo: "숨김 파일 보기 전환", titleEn: "Toggle Hidden Files",
            descriptionKo: "Finder에서 숨김 파일을 보이거나 숨깁니다", descriptionEn: "Show or hide hidden files in Finder",
            synonyms: ["숨김 파일", "숨긴 파일 보기", "dotfiles", "show hidden files", "hidden files"],
            symbol: "eye", requiresConfirmation: false),
        BuiltinCommand(
            id: "open-downloads", titleKo: "다운로드 폴더 열기", titleEn: "Open Downloads",
            descriptionKo: "Finder에서 다운로드 폴더를 엽니다", descriptionEn: "Open the Downloads folder in Finder",
            synonyms: ["다운로드", "받은 파일", "downloads", "downloads folder"],
            symbol: "arrow.down.circle", requiresConfirmation: false),
        BuiltinCommand(
            id: "open-desktop", titleKo: "데스크탑 폴더 열기", titleEn: "Open Desktop",
            descriptionKo: "Finder에서 데스크탑 폴더를 엽니다", descriptionEn: "Open the Desktop folder in Finder",
            synonyms: ["데스크탑", "바탕화면", "바탕 화면 폴더", "desktop", "desktop folder"],
            symbol: "menubar.dock.rectangle", requiresConfirmation: false),
        BuiltinCommand(
            id: "open-documents", titleKo: "문서 폴더 열기", titleEn: "Open Documents",
            descriptionKo: "Finder에서 문서 폴더를 엽니다", descriptionEn: "Open the Documents folder in Finder",
            synonyms: ["문서", "도큐먼트", "documents", "documents folder"],
            symbol: "doc", requiresConfirmation: false),
        BuiltinCommand(
            id: "open-home", titleKo: "홈 폴더 열기", titleEn: "Open Home Folder",
            descriptionKo: "Finder에서 사용자 홈 폴더를 엽니다", descriptionEn: "Open your home folder in Finder",
            synonyms: ["홈 폴더", "사용자 폴더", "home", "home folder", "home directory"],
            symbol: "house", requiresConfirmation: false),
        BuiltinCommand(
            id: "eject-all", titleKo: "모든 디스크 추출", titleEn: "Eject All Disks",
            descriptionKo: "연결된 외장 디스크와 볼륨을 모두 추출합니다", descriptionEn: "Eject all external disks and volumes",
            synonyms: ["추출", "꺼내기", "외장 하드 꺼내기", "usb 꺼내기", "eject", "unmount", "eject disks"],
            symbol: "eject.fill", requiresConfirmation: true),
        BuiltinCommand(
            id: "restart-finder", titleKo: "Finder 재시작", titleEn: "Restart Finder",
            descriptionKo: "Finder를 종료하고 다시 실행합니다", descriptionEn: "Relaunch Finder",
            synonyms: ["파인더 재시작", "Finder 다시 시작", "relaunch finder", "kill finder"],
            symbol: "arrow.triangle.2.circlepath", requiresConfirmation: false),
        BuiltinCommand(
            id: "restart-dock", titleKo: "Dock 재시작", titleEn: "Restart Dock",
            descriptionKo: "Dock을 종료하고 다시 실행합니다", descriptionEn: "Relaunch the Dock",
            synonyms: ["독 재시작", "Dock 다시 시작", "relaunch dock", "kill dock"],
            symbol: "dock.rectangle", requiresConfirmation: false),
    ]

    public static let ids: [String] = all.map(\.id)

    public static func command(id: String) -> BuiltinCommand? { all.first { $0.id == id } }

    static func item(for c: BuiltinCommand) -> SearchItem {
        SearchItem(
            id: c.itemID,
            kind: .command,
            title: c.titleKo,
            subtitle: c.titleEn,
            keywords: ItemText.uniqueKeywords([c.titleKo, c.titleEn] + c.synonyms.map(Optional.some)),
            embeddingTitle: "\(c.titleKo) (\(c.titleEn))",
            embeddingText: "명령 (command) · \(c.descriptionKo) / \(c.descriptionEn) · \(c.synonyms.joined(separator: ", "))",
            action: .builtinCommand(id: c.id),
            icon: .systemSymbol(c.symbol),
            requiresConfirmation: c.requiresConfirmation
        )
    }
}
