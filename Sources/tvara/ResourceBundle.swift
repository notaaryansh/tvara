import Foundation

extension Bundle {
    /// The MobileCLIP model + CLIP tokenizer resource bundle
    /// (`tvara_tvara.bundle`), resolved in a way that survives `.app` packaging.
    ///
    /// SwiftPM generates `Bundle.module` for the executable target as:
    ///
    ///     Bundle(path: Bundle.main.bundleURL/"tvara_tvara.bundle")   // app ROOT
    ///       ?? Bundle(path: "<absolute build-machine path>/…")       // dev only
    ///
    /// Both candidates fail in a shipped app:
    ///   • The app ROOT is codesign-illegal for a resource bundle — placing it
    ///     there yields "unsealed contents present in the bundle root", so the
    ///     app is signed with the bundle under `Contents/`, which `Bundle.module`
    ///     never looks in.
    ///   • The baked build path is the CI runner's `/Users/runner/work/…`, which
    ///     exists on no user's machine.
    ///
    /// So every CI-built release `fatalError`ed on first access to `Bundle.module`
    /// (image indexing at launch). It only ever "worked" from local dev builds,
    /// where the baked path points at the developer's own `.build` directory.
    ///
    /// Fix: resolve the bundle from `Contents/Resources` (its codesign-legal,
    /// shipped location) first, and fall back to `Bundle.module` for `swift run`
    /// dev builds where the baked path is valid.
    static let tvaraResources: Bundle = {
        if let resourceURL = Bundle.main.resourceURL {
            let packaged = resourceURL.appendingPathComponent("tvara_tvara.bundle")
            if let bundle = Bundle(url: packaged) {
                return bundle
            }
        }
        return .module
    }()
}
