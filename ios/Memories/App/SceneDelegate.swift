import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    let container = AppContainer()

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default", sessionRole: session.role)
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var main: MainViewController?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene, let app = UIApplication.shared.delegate as? AppDelegate else { return }
        let main = MainViewController(container: app.container)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = main
        window.makeKeyAndVisible()
        self.window = window
        self.main = main
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        main?.onForeground()
    }
}
