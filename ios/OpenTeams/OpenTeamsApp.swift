import SwiftUI

@main
struct OpenTeamsApp: App {
    var body: some Scene {
        WindowGroup {
            TeamsView()
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
