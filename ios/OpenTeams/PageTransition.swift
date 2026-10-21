import UIKit

/// Keeps Teams' narrow-layout slide animations behind a snapshot when a
/// native tab switches. The tab bar itself remains responsive. The page
/// reports when the target is selected, idle and no longer sliding; a bounded
/// fallback prevents a stuck overlay if Teams changes its layout.
final class PageTransition {
    private var cover: UIView?
    private var deadline: DispatchWorkItem?
    private(set) var generation = 0

    @discardableResult
    func begin(over page: UIView) -> Int {
        generation += 1
        deadline?.cancel()
        if UIAccessibility.isReduceMotionEnabled {
            cover?.removeFromSuperview()
            cover = nil
        } else if cover == nil, let host = page.superview,
                  let snapshot = page.snapshotView(afterScreenUpdates: false) {
            snapshot.frame = page.frame
            snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            // Block taps on the old screenshot, but not on the native tab bar.
            snapshot.isUserInteractionEnabled = true
            host.insertSubview(snapshot, aboveSubview: page)
            cover = snapshot
        }
        let token = generation
        let fallback = DispatchWorkItem { [weak self] in self?.finish(token: token) }
        deadline = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: fallback)
        return token
    }

    func finish(token: Int) {
        guard token == generation else { return }
        deadline?.cancel()
        deadline = nil
        guard let snapshot = cover else { return }
        // Detach ownership before animating: another tap can start a fresh
        // transition without an older completion removing its cover.
        cover = nil
        if UIAccessibility.isReduceMotionEnabled {
            snapshot.removeFromSuperview()
        } else {
            UIView.animate(withDuration: 0.16, animations: {
                snapshot.alpha = 0
            }, completion: { _ in snapshot.removeFromSuperview() })
        }
    }

    func cancel() {
        generation += 1
        deadline?.cancel()
        deadline = nil
        cover?.removeFromSuperview()
        cover = nil
    }

    deinit {
        deadline?.cancel()
        cover?.removeFromSuperview()
    }
}
