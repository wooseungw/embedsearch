/// Hand-written enrichment for well-known apps: what the app is for (ko + en, feeds the embedding
/// card) and common aliases such as Hangul transliterations ("크롬", "엑셀") that the bundle does
/// not ship. Keyed by bundle identifier. Apps not listed here still get names, bundle id and category.
enum AppCatalog {
    struct Entry {
        let description: String
        let aliases: [String]
    }

    static func entry(for bundleID: String) -> Entry? { entries[bundleID.lowercased()] }

    private static let entries: [String: Entry] = {
        var d: [String: Entry] = [:]
        for (id, description, aliases) in table { d[id.lowercased()] = Entry(description: description, aliases: aliases) }
        return d
    }()

    private static let table: [(String, String, [String])] = [
        // Apple — /System/Applications
        ("com.apple.AppStore", "앱 다운로드·설치·업데이트 / download, install and update apps", ["앱스토어", "앱 스토어"]),
        ("com.apple.apps.launcher", "설치된 앱 모아 보기, 런치패드 / browse installed apps, Launchpad", ["런치패드", "Launchpad"]),
        ("com.apple.Automator", "작업 자동화 워크플로 / automation workflows", ["오토메이터"]),
        ("com.apple.iBooksX", "전자책, 오디오북 읽기 / read ebooks and audiobooks", ["아이북스", "iBooks"]),
        ("com.apple.calculator", "사칙연산, 공학용 계산, 단위 변환 / arithmetic, scientific calculator, unit conversion", ["calc"]),
        ("com.apple.iCal", "일정, 약속, 달력 관리 / schedule events and appointments", ["달력", "일정"]),
        ("com.apple.Chess", "체스 게임 / play chess", []),
        ("com.apple.clock", "알람, 타이머, 스톱워치, 세계 시계 / alarm, timer, stopwatch, world clock", ["알람", "타이머"]),
        ("com.apple.AddressBook", "연락처, 주소록, 전화번호 / contacts, address book, phone numbers", ["주소록"]),
        ("com.apple.Dictionary", "단어 뜻 찾기, 영어사전, 국어사전 / look up word definitions, thesaurus", []),
        ("com.apple.FaceTime", "영상 통화, 음성 통화 / video and audio calls", ["페이스타임"]),
        ("com.apple.findmy", "아이폰·기기·친구 위치 찾기 / locate devices, people and items", ["나의 아이폰 찾기", "Find My iPhone"]),
        ("com.apple.FontBook", "서체 설치 및 관리 / install and manage fonts", ["폰트", "fonts"]),
        ("com.apple.freeform", "화이트보드, 브레인스토밍 / whiteboard canvas", ["프리폼"]),
        ("com.apple.games", "게임 모음, Game Center / games hub", []),
        ("com.apple.Home", "스마트 홈 기기 제어, HomeKit / control smart home accessories", ["HomeKit"]),
        ("com.apple.Image_Capture", "스캐너, 카메라에서 사진 가져오기 / scan documents, import photos from devices", ["스캔"]),
        ("com.apple.GenerativePlaygroundApp", "AI 이미지 생성 / generate images with Apple Intelligence", []),
        ("com.apple.ScreenContinuity", "아이폰 화면을 맥에서 사용 / use your iPhone screen on the Mac", ["아이폰 미러링"]),
        ("com.apple.journal", "일기 쓰기 / write a journal, diary", ["일기"]),
        ("com.apple.mail", "이메일 읽기·보내기 / read and send email", ["이메일", "메일", "email"]),
        ("com.apple.Maps", "지도, 길찾기, 내비게이션 / maps, directions, navigation", ["길찾기"]),
        ("com.apple.MobileSMS", "문자 메시지, iMessage 채팅 / text messages, SMS, iMessage chat", ["문자", "iMessage", "SMS"]),
        ("com.apple.exposelauncher", "열린 윈도우와 데스크탑 공간 모두 보기 / show all open windows and Spaces", ["미션 컨트롤", "Exposé"]),
        ("com.apple.Music", "음악, 노래 재생, Apple Music / play music and songs", ["아이튠즈", "iTunes", "노래"]),
        ("com.apple.news", "뉴스 읽기 / read news", []),
        ("com.apple.Notes", "메모 작성, 노트 필기 / write notes, memos", ["노트", "memo"]),
        ("com.apple.Passwords", "암호, 패스키 관리 / password manager, passkeys", ["비밀번호", "패스워드"]),
        ("com.apple.mobilephone", "전화 걸기, 통화 / make phone calls", ["전화"]),
        ("com.apple.PhotoBooth", "웹캠으로 셀카 찍기 / take selfies with the webcam", ["포토부스"]),
        ("com.apple.Photos", "사진, 동영상 보관함 / photo and video library", ["사진첩", "갤러리"]),
        ("com.apple.podcasts", "팟캐스트 듣기 / listen to podcasts", ["팟캐스트"]),
        ("com.apple.Preview", "PDF, 이미지 보기 및 편집 / view and annotate PDFs and images", ["프리뷰", "PDF 뷰어"]),
        ("com.apple.QuickTimePlayerX", "동영상 재생, 화면 녹화 / play videos, record the screen", ["퀵타임", "동영상 플레이어"]),
        ("com.apple.reminders", "할 일 목록, 체크리스트 / to-do list, tasks", ["할 일", "todo", "to-do"]),
        ("com.apple.shortcuts", "단축어 만들기, 자동화 / build shortcuts and automations", ["단축어"]),
        ("com.apple.siri.launcher", "음성 비서 / voice assistant", ["시리"]),
        ("com.apple.Stickies", "화면에 붙이는 스티커 메모 / sticky notes on the desktop", ["포스트잇", "sticky notes"]),
        ("com.apple.stocks", "주식 시세 / stock quotes", ["주가"]),
        ("com.apple.systempreferences", "맥 설정 변경, 환경설정 / change Mac settings, control panel", ["환경설정", "시스템 환경설정", "제어판", "control panel"]),
        ("com.apple.TextEdit", "텍스트 편집기, 메모장, 문서 작성 / plain and rich text editor, notepad", ["메모장", "notepad"]),
        ("com.apple.backup.launcher", "백업에서 파일 복원 / restore files from backups", ["타임머신", "백업"]),
        ("com.apple.helpviewer", "사용 팁과 도움말 / tips and help", []),
        ("com.apple.TV", "영화, TV 프로그램 보기 / watch movies and TV shows", []),
        ("com.apple.VoiceMemos", "음성 녹음, 녹음기 / record audio, voice recorder", ["녹음", "녹음기"]),
        ("com.apple.weather", "날씨, 일기 예보 / weather forecast", ["일기예보"]),
        // Apple — Utilities
        ("com.apple.ActivityMonitor", "작업 관리자, CPU·메모리 사용량, 프로세스 강제 종료 / task manager, CPU and memory usage, kill processes", ["작업 관리자", "task manager"]),
        ("com.apple.airport.airportutility", "AirPort 공유기 설정 / configure AirPort base stations", []),
        ("com.apple.audio.AudioMIDISetup", "오디오 장치, MIDI 설정 / audio devices and MIDI setup", []),
        ("com.apple.BluetoothFileExchange", "블루투스로 파일 보내기 / send files over Bluetooth", []),
        ("com.apple.bootcampassistant", "Windows 설치 / install Windows", []),
        ("com.apple.ColorSyncUtility", "색상 프로파일 / color profiles", []),
        ("com.apple.Console", "시스템 로그 보기 / view system logs", ["로그"]),
        ("com.apple.DigitalColorMeter", "화면 색상 값 측정, 스포이드 / measure on-screen colors, eyedropper", ["스포이드", "color picker"]),
        ("com.apple.DiskUtility", "디스크 포맷, 파티션, 복구 / format, partition and repair disks", ["포맷"]),
        ("com.apple.grapher", "수식 그래프 그리기 / plot equations", []),
        ("com.apple.Magnifier", "카메라로 확대해서 보기 / magnify with the camera", ["돋보기"]),
        ("com.apple.MigrateAssistant", "다른 맥이나 PC에서 데이터 옮기기 / transfer data from another Mac or PC", []),
        ("com.apple.printcenter", "프린터 대기열, 인쇄 작업 / printer queue, print jobs", []),
        ("com.apple.ScreenSharing", "원격 화면 공유, 원격 제어, VNC / remote screen sharing and control", ["원격 데스크톱", "VNC"]),
        ("com.apple.screenshot.launcher", "스크린샷 찍기, 화면 캡처, 화면 기록 / take screenshots, capture or record the screen", ["화면 캡처", "캡쳐", "screen capture"]),
        ("com.apple.ScriptEditor2", "AppleScript 작성 / write AppleScript", []),
        ("com.apple.SystemProfiler", "하드웨어 정보, 시스템 리포트 / hardware information, system report", []),
        ("com.apple.Terminal", "명령줄 셸, 콘솔 / command line shell", ["터미널", "shell", "cli"]),
        ("com.apple.VoiceOverUtility", "VoiceOver 화면 읽기 설정 / screen reader settings", []),
        // Apple — CoreServices
        ("com.apple.finder", "파일 탐색기, 파일과 폴더 관리 / file manager, browse files and folders", ["파인더", "탐색기", "file explorer"]),
        ("com.apple.archiveutility", "압축 풀기, zip 압축 / unzip and compress archives", ["압축"]),
        ("com.apple.keychainaccess", "저장된 암호, 인증서 / saved passwords and certificates", ["키체인"]),
        ("com.apple.AboutThisMacLauncher", "맥 사양, 모델 정보 / Mac model and specs", ["사양"]),
        ("com.apple.wifi.diagnostics", "와이파이 문제 진단 / diagnose Wi-Fi problems", ["와이파이 진단"]),
        ("com.apple.Safari", "웹 브라우저, 인터넷 / web browser", ["사파리", "browser", "브라우저"]),
        ("com.apple.Keynote", "프레젠테이션, 발표 자료 / presentations, slides", ["키노트", "ppt"]),
        ("com.apple.iWork.Keynote", "프레젠테이션, 발표 자료 / presentations, slides", ["키노트", "ppt"]),
        ("com.apple.iWork.Numbers", "스프레드시트, 표 계산 / spreadsheets", ["넘버스", "엑셀"]),
        ("com.apple.iWork.Pages", "워드 프로세서, 문서 작성 / word processor, documents", ["페이지스"]),
        ("com.apple.dt.Xcode", "앱 개발 IDE / IDE for Apple platforms", ["엑스코드"]),
        // Popular third-party apps
        ("com.google.Chrome", "웹 브라우저, 인터넷 / web browser", ["크롬", "chrome", "browser", "브라우저"]),
        ("com.microsoft.Word", "워드 프로세서, 문서 작성 / word processor, documents", ["워드", "word"]),
        ("com.microsoft.Excel", "스프레드시트, 표 계산 / spreadsheets", ["엑셀", "excel"]),
        ("com.microsoft.Powerpoint", "프레젠테이션, 발표 자료 / presentations, slides", ["파워포인트", "피피티", "ppt"]),
        ("com.microsoft.onenote.mac", "디지털 노트 필기 / digital notebook", ["원노트"]),
        ("com.microsoft.VSCode", "코드 편집기 / code editor", ["비주얼 스튜디오 코드", "vscode", "vs code", "코드"]),
        ("com.kakao.KakaoTalkMac", "메신저, 채팅 / messenger, chat", ["카톡"]),
        ("com.hnc.Discord", "음성 채팅, 커뮤니티 메신저 / voice chat and community messenger", ["디스코드"]),
        ("notion.id", "노트, 문서, 위키, 할 일 / notes, docs, wiki, tasks", ["노션"]),
        ("md.obsidian", "마크다운 노트 / markdown notes, knowledge base", ["옵시디언"]),
        ("com.figma.Desktop", "UI 디자인 / interface design", ["피그마"]),
        ("com.anthropic.claudefordesktop", "AI 어시스턴트 / AI assistant", ["클로드"]),
        ("com.openai.chat", "AI 챗봇 / AI chatbot", ["챗지피티", "챗GPT"]),
        ("com.linguee.DeepLCopyTranslator", "번역기 / translator", ["딥엘", "번역"]),
        ("com.googlecode.iterm2", "터미널 에뮬레이터 / terminal emulator", ["아이텀"]),
        ("com.docker.docker", "컨테이너 / containers", ["도커"]),
        ("com.raycast.macos", "런처, 생산성 도구 / launcher", ["레이캐스트"]),
        ("us.zoom.xos", "화상 회의 / video meetings", ["줌"]),
        ("com.hancom.office.hwp12.mac.general", "한글 문서 작성, hwp / Hangul word processor", ["한글", "hwp", "아래아한글"]),
    ]
}
