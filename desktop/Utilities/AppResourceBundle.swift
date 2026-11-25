import Foundation

enum AppResourceBundle {
    static let bundle: Bundle = {
        if let resourceURL = Bundle.main.resourceURL {
            let bundleURL = resourceURL.appendingPathComponent("GoLens_GoLensApp.bundle")
            if let bundle = Bundle(url: bundleURL) {
                return bundle
            }
            let veloURL = resourceURL.appendingPathComponent("Velo_VeloApp.bundle")
            if let bundle = Bundle(url: veloURL) {
                return bundle
            }
        }
        let mainBundleURL = Bundle.main.bundleURL.appendingPathComponent("GoLens_GoLensApp.bundle")
        if let bundle = Bundle(url: mainBundleURL) {
            return bundle
        }
        return Bundle.main
    }()

    static func url(forResource name: String, withExtension ext: String?) -> URL? {
        if let url = bundle.url(forResource: name, withExtension: ext) {
            return url
        }
        return Bundle.main.url(forResource: name, withExtension: ext)
    }
}
