import Foundation

enum ConnState {
    case connected   // real internet access
    case captured    // behind the portal / offline
}

// Fetched once and reused for the gating decision and the login submit.
struct CaptivePage {
    let url: URL?
    let html: String
    var hops = 0

    // Logged on rejection: path and shape only, never the page body or host.
    var summary: String {
        let path = url.map { $0.path.isEmpty ? "/" : $0.path } ?? "?"
        let form = LoginFormParser.parse(html: html) == nil ? "no form" : "form"
        return "\(path), \(html.utf8.count) bytes, \(form), \(hops) redirect(s) followed"
    }
}

// Connectivity detection + captive-portal login.
final class PortalClient {
    private static let maxRedirectHops = 3
    private let probeURL: URL
    private let successMarker = "<TITLE>Success</TITLE>"

    init(probeURL: URL = URL(string: "http://captive.apple.com/hotspot-detect.html")!) {
        self.probeURL = probeURL
    }

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: cfg)
    }()

    // Apple's probe returns a page containing "Success" only with real internet;
    // otherwise the portal intercepts the request.
    func checkConnectivity(completion: @escaping (ConnState) -> Void) {
        let task = session.dataTask(with: probeURL) { data, _, _ in
            if let data = data,
               let body = String(data: data, encoding: .utf8),
               body.contains(self.successMarker) {
                completion(.connected)
            } else {
                completion(.captured)
            }
        }
        task.resume()
    }

    // Gate before any POST: the page must hold a login form, or the marker when set.
    func inspectCaptivePage(completion: @escaping (_ isOurPortal: Bool, _ page: CaptivePage?) -> Void) {
        fetchCaptivePage { page in
            guard let page = page else { completion(false, nil); return }
            completion(Self.isOurPortal(page: page, marker: Settings.shared.portalMarker), page)
        }
    }

    // The marker may sit in the page address (portal domain) or its text.
    static func isOurPortal(page: CaptivePage, marker: String) -> Bool {
        let trimmed = marker.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return LoginFormParser.parse(html: page.html) != nil }
        let address = page.url?.absoluteString ?? ""
        return address.localizedCaseInsensitiveContains(trimmed) || page.html.localizedCaseInsensitiveContains(trimmed)
    }

    func login(page: CaptivePage, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                completion(false)
                return
            }
            let settings = Settings.shared
            if let form = LoginFormParser.parse(html: page.html),
               let action = Self.resolve(action: form.action, base: page.url) {
                self.postForm(url: action,
                              fields: form.filled(username: settings.username, password: settings.password),
                              completion: completion)
            } else {
                self.loginWithConfiguredEndpoint(completion: completion)
            }
        }
    }

    // Portals answer the probe with a login page or a meta/JS redirect page; follow those.
    private func fetchCaptivePage(completion: @escaping (CaptivePage?) -> Void) {
        fetchPage(probeURL, hops: 0, completion: completion)
    }

    private func fetchPage(_ url: URL, hops: Int, completion: @escaping (CaptivePage?) -> Void) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        let task = session.dataTask(with: request) { [weak self] data, response, _ in
            guard let html = data.flatMap({ String(data: $0, encoding: .utf8) }) else {
                completion(nil)
                return
            }
            let page = CaptivePage(url: response?.url ?? url, html: html, hops: hops)
            guard let self = self, hops < Self.maxRedirectHops,
                  let next = LoginFormParser.redirectURL(html: html, base: page.url) else {
                completion(page)
                return
            }
            self.fetchPage(next, hops: hops + 1, completion: completion)
        }
        task.resume()
    }

    private func loginWithConfiguredEndpoint(completion: @escaping (Bool) -> Void) {
        let settings = Settings.shared
        guard let url = URL(string: settings.loginURL) else {
            completion(false)
            return
        }
        var fields: [(String, String)] = [
            ("username", settings.username),
            ("password", settings.password),
        ]
        fields.append(contentsOf: Self.parseExtraFields(settings.extraFields))
        postForm(url: url, fields: fields, completion: completion)
    }

    private func postForm(url: URL, fields: [(String, String)], completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(fields).data(using: .utf8)
        request.timeoutInterval = 15
        let task = session.dataTask(with: request) { _, _, error in
            // The response body varies by portal; the caller re-checks
            // connectivity to confirm the login actually worked.
            completion(error == nil)
        }
        task.resume()
    }

    // MARK: - Helpers

    // Resolves a form action (absolute, relative, or empty) against the page URL.
    static func resolve(action: String, base: URL?) -> URL? {
        let a = action.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return base }
        if let absolute = URL(string: a), absolute.scheme != nil { return absolute }
        return URL(string: a, relativeTo: base)?.absoluteURL
    }

    // Parses configured extra fields: one "name=value" per line or comma.
    static func parseExtraFields(_ raw: String) -> [(String, String)] {
        var fields: [(String, String)] = []
        for line in raw.split(whereSeparator: { $0 == "\n" || $0 == "," }) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let value = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
            fields.append((name, value))
        }
        return fields
    }

    static func formEncode(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { name, value in
            let n = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(n)=\(v)"
        }.joined(separator: "&")
    }
}
