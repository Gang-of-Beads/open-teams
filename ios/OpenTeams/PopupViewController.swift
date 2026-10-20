import UIKit
import WebKit

/// Presents a window.open() popup (for example a sign-in or consent page) as
/// a modal sheet with a Done button.
final class PopupViewController: UIViewController {
    private let webView: WKWebView
    private let onClose: () -> Void
    private var titleObservation: NSKeyValueObservation?

    init(webView: WKWebView, onClose: @escaping () -> Void) {
        self.webView = webView
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        titleObservation = webView.observe(\.title, options: [.initial, .new]) { [weak self] webView, _ in
            self?.navigationItem.title = webView.title
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Covers Done, swipe-to-dismiss and window.close().
        if navigationController?.isBeingDismissed ?? isBeingDismissed {
            onClose()
        }
    }
}
