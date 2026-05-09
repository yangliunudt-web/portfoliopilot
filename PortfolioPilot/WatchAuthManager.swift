import LocalAuthentication

enum WatchAuthManager {
    /// 使用 Apple Watch / Touch ID 验证，成功返回 true
    /// 默认使用 deviceOwnerAuthentication，macOS 会依次尝试 Apple Watch → Touch ID
    /// 不会自动回退到密码输入
    static func authenticate(reason: String = "验证身份以继续操作") async -> Bool {
        let context = LAContext()
        // 不覆盖 localizedFallbackTitle，保留系统默认的"输入密码..."按钮
        // 让 Apple Watch 有足够时间响应
        context.localizedCancelTitle = "取消"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            print("[WatchAuth] Not available: \(error?.localizedDescription ?? "")")
            // 无 Watch/Touch ID 的 Mac，直接放行
            return true
        }

        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch let laErr as LAError {
            switch laErr.code {
            case .userCancel, .systemCancel:
                print("[WatchAuth] Cancelled: \(laErr.code)")
            case .userFallback:
                // 用户点击了"输入密码..."按钮 → 走到系统密码验证
                print("[WatchAuth] User chose password fallback")
                return true
            default:
                print("[WatchAuth] LAError: \(laErr.code.rawValue)")
            }
            return false
        } catch {
            print("[WatchAuth] Error: \(error)")
            return false
        }
    }
}
