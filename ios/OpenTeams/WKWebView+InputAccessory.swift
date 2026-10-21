import ObjectiveC
import WebKit

extension WKWebView {
    /// Removes the bar WebKit shows above the keyboard for web form fields
    /// (previous / next / done), which native apps do not have.
    ///
    /// WKWebView has no public switch for it. The bar is the
    /// `inputAccessoryView` of WebKit's internal content view, so that view is
    /// given a runtime subclass that returns nil. If WebKit changes its view
    /// structure this does nothing, and the bar simply stays.
    func removeInputAccessoryView() {
        guard let contentView = scrollView.subviews.first(where: {
            String(describing: type(of: $0)).hasPrefix("WKContent")
        }), let originalClass = object_getClass(contentView) else { return }

        let subclassName = "\(NSStringFromClass(originalClass))_OpenTeamsNoAccessory"
        if originalClass == NSClassFromString(subclassName) { return }

        var subclass: AnyClass? = NSClassFromString(subclassName)
        if subclass == nil, let created = objc_allocateClassPair(originalClass, subclassName, 0) {
            let noAccessory: @convention(block) (AnyObject) -> AnyObject? = { _ in nil }
            class_addMethod(
                created,
                #selector(getter: UIResponder.inputAccessoryView),
                imp_implementationWithBlock(noAccessory),
                "@@:"
            )
            objc_registerClassPair(created)
            subclass = created
        }
        if let subclass {
            object_setClass(contentView, subclass)
        }
    }
}
