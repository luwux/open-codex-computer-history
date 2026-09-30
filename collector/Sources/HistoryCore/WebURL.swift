import Foundation

public enum WebURL {
    /// The value as an absolute `http`/`https` URL with a host, else `nil`.
    public static func webURL(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else {
            return nil
        }
        return url.absoluteString
    }
}
