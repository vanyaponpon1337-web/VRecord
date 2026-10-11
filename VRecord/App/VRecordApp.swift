import UIKit
import AVFoundation
import os

@main
final class VRecordApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var coordinator: AppLifecycle?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        do {
            let coordinator = try AppLifecycle()
            self.coordinator = coordinator
            window.rootViewController = coordinator.viewController
        } catch {
            Logger(subsystem: "com.vrecord.app", category: "Startup")
                .fault("Metal initialization failed: \(error.localizedDescription, privacy: .public)")
            // No custom visual controls or error text: unavailable hardware is
            // reported to the system log while the immersive surface stays black.
            let controller = UIViewController()
            controller.view.backgroundColor = .black
            window.rootViewController = controller
        }
        self.window = window
        window.makeKeyAndVisible()
        coordinator?.requestPermissionsAndStart()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) { coordinator?.background() }
    func applicationDidBecomeActive(_ application: UIApplication) { coordinator?.foreground() }
    func applicationWillResignActive(_ application: UIApplication) { coordinator?.resignActive() }
    func applicationDidReceiveMemoryWarning(_ application: UIApplication) { coordinator?.memoryWarning() }
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        .landscape
    }
}

final class ImmersiveViewController: UIViewController {
    var onOrientation: ((UIInterfaceOrientation) -> Void)?
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }
    override var shouldAutorotate: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        reportOrientation()
    }
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.reportOrientation() }
    }
    private func reportOrientation() {
        if let value = view.window?.windowScene?.interfaceOrientation, value.isLandscape { onOrientation?(value) }
    }
}
