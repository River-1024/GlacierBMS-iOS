import Foundation
import UIKit

/// 日志系统的启动与崩溃取证钩子。
///
/// 为什么需要：iOS 无「捕获 fatalError」的官方机制，越界/强制解包等 trap 会直接终止进程。
/// 我们能做的是在终止**之前**尽可能把现场写入磁盘，并在下次启动时报告「上次异常退出」，
/// 让真机闪退有可追溯的证据链。
public enum AppLogBootstrap {
    /// 上次启动是否异常退出（由上次会话写入标记，本次启动读取后清除）。
    private static let crashFlagKey = "com.zjsf.anturide.log.uncleanExit"

    /// 在 App 启动最早时机调用。
    public static func install() {
        let previousUnclean = UserDefaults.standard.bool(forKey: crashFlagKey)

        AppLog.lifecycle.notice("App 启动, 版本=\(appVersion), 部署目标 iOS 16.0")

        if previousUnclean {
            // 上一次会话未正常走完 didEnterBackground / willTerminate。
            AppLog.lifecycle.warning("检测到上次会话为异常退出（可能闪退），请结合此前最后一条日志定位")
        }

        // 标记本次会话为「未正常结束」；正常进入后台时会清除该标记。
        UserDefaults.standard.set(true, forKey: crashFlagKey)

        registerLifecycleObservers()
    }

    /// 注册系统通知，在进入后台/终止前落盘并清除异常标记。
    private static func registerLifecycleObservers() {
        let center = NotificationCenter.default
        center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            AppLog.lifecycle.notice("App 进入后台")
            // 进入后台视为一次「健康」的生命周期节点，清除异常退出标记。
            UserDefaults.standard.set(false, forKey: crashFlagKey)
        }

        center.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            AppLog.lifecycle.notice("App 即将终止")
            UserDefaults.standard.set(false, forKey: crashFlagKey)
        }
    }

    static var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
