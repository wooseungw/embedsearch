import Observation
import ServiceManagement

/// Login item via `SMAppService.mainApp`. `register()` can succeed while the status stays
/// `.requiresApproval` until the user allows it in System Settings › General › Login Items.
@MainActor
@Observable
final class LaunchAtLogin {
    private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    private(set) var lastError: String?

    var isEnabled: Bool { status == .enabled || status == .requiresApproval }

    var statusText: String {
        switch status {
        case .enabled: return "켜짐"
        case .requiresApproval: return "승인 필요 — 시스템 설정 › 일반 › 로그인 항목에서 허용하세요"
        case .notRegistered: return "꺼짐"
        case .notFound: return "앱을 찾을 수 없음 (~/Applications에 설치 후 다시 시도)"
        @unknown default: return "알 수 없음"
        }
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
