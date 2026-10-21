import UIKit

/// Shown over the web view while Teams starts and when it cannot load,
/// instead of a blank page and an alert.
final class LoadingView: UIView {
    private let logo = UIImageView(image: UIImage(named: "LoadingLogo"))
    private let progress = UIProgressView(progressViewStyle: .default)
    private let message = UILabel()
    private let retryButton = UIButton(configuration: .filled())
    var onRetry: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground

        logo.contentMode = .scaleAspectFit
        logo.layer.cornerRadius = 22
        logo.layer.cornerCurve = .continuous
        logo.clipsToBounds = true

        progress.trackTintColor = .tertiarySystemFill

        message.font = .preferredFont(forTextStyle: .subheadline)
        message.adjustsFontForContentSizeCategory = true
        message.textColor = .secondaryLabel
        message.textAlignment = .center
        message.numberOfLines = 0

        retryButton.configuration?.title = String(localized: "Retry")
        retryButton.configuration?.cornerStyle = .capsule
        retryButton.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .primaryActionTriggered)

        let stack = UIStackView(arrangedSubviews: [logo, progress, message, retryButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 20
        stack.setCustomSpacing(28, after: logo)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            logo.widthAnchor.constraint(equalToConstant: 96),
            logo.heightAnchor.constraint(equalToConstant: 96),
            progress.widthAnchor.constraint(equalToConstant: 160),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -40),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),
        ])
        showLoading()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func showLoading() {
        progress.isHidden = false
        message.text = nil
        message.isHidden = true
        retryButton.isHidden = true
    }

    func showError(_ text: String) {
        progress.isHidden = true
        message.text = text
        message.isHidden = false
        retryButton.isHidden = false
    }

    func setProgress(_ value: Double) {
        // Keep a sliver visible so the bar reads as "working" from the start.
        progress.setProgress(Float(max(value, 0.05)), animated: value > 0.05)
    }
}
