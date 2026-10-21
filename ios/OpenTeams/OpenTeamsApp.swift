import SwiftUI

@main
struct OpenTeamsApp: App {
    var body: some Scene {
        WindowGroup {
            // The view controller handles safe areas and the keyboard itself,
            // so the status bar area can take Teams' title bar color.
            TeamsView()
                .ignoresSafeArea()
        }
    }
}

/// Bridges the UIKit view controller that owns the WKWebView into SwiftUI.
struct TeamsView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> TeamsViewController {
        TeamsViewController()
    }

    func updateUIViewController(_ uiViewController: TeamsViewController, context: Context) {}
}
