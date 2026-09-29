import Foundation

/// `bestcast://run/<key>`: runs a launcher row by its preference key, the way its hotkey would.
enum LauncherDeepLink {
    static let scheme = "bestcast"
    static let host = "run"

    /// Unreserved only, so a `/` or `:` inside a key never reads back as structure.
    private static let keyCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    static func url(forKey key: String) -> URL? {
        guard !key.isEmpty,
            let encoded = key.addingPercentEncoding(withAllowedCharacters: keyCharacters)
        else { return nil }
        return URL(string: "\(scheme)://\(host)/\(encoded)")
    }

    /// The key a link names, or nil for any URL this type did not write.
    static func key(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme,
            url.host(percentEncoded: false)?.lowercased() == host
        else { return nil }
        var path = Substring(url.path(percentEncoded: true))
        guard path.first == "/" else { return nil }
        path = path.dropFirst()
        if path.last == "/" { path = path.dropLast() }
        guard !path.isEmpty, !path.contains("/"),
            let key = String(path).removingPercentEncoding, !key.isEmpty
        else { return nil }
        return key
    }
}
