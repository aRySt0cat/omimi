import BackgroundTasks
import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// CoreBluetooth の状態復元のため、起動直後 (バックグラウンド起動を含む) に生成する
    @MainActor private(set) static var model: AppModel!

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MainActor.assumeIsolated {
            Self.styleNavigationBar()
            let model = AppModel()
            Self.model = model
            BGTaskScheduler.shared.register(forTaskWithIdentifier: AppModel.backlogTaskIdentifier, using: nil) { task in
                guard let task = task as? BGProcessingTask else { return }
                MainActor.assumeIsolated { model.handleBacklogTask(task) }
            }
        }
        return true
    }

    /// 画面のタイトルも明朝・藍墨にそろえる
    @MainActor private static func styleNavigationBar() {
        let ink = UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: 0xE6ECF5) : UIColor(rgb: 0x1D2A44) }
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        if let large = UIFont(name: "HiraMinProN-W6", size: 32), let small = UIFont(name: "HiraMinProN-W6", size: 17) {
            appearance.largeTitleTextAttributes = [.font: large, .foregroundColor: ink]
            appearance.titleTextAttributes = [.font: small, .foregroundColor: ink]
        }
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
    }
}

@main
struct OmimiApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(AppDelegate.model)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: AppDelegate.model.didBecomeActive()
            case .background: AppDelegate.model.didEnterBackground()
            default: break
            }
        }
    }
}
