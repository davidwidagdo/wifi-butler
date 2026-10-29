import Foundation

enum ConnState {
    case connected   // real internet access
    case captured    // behind the portal / offline
}

// A captive-portal page fetched once, reused for both the "is this our portal?"
// decision and the login submit (avoids a second round-trip).
struct CaptivePage {
    let url: URL?
    let html: String
}

// Connectivity detection + captive-portal login.
final class PortalClient {
    private let probeURL = URL(string: "http://captive.apple.com/hotspot-detect.html")!
    private let successMarker = "<TITLE>Success</TITLE>"

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

    // Confirms the configured portal is actually on this network before we send
    // credentials. This keeps the app from POSTing on no-login/offline networks
    // or leaking credentials to a foreign captive portal. If a marker is set,
    // the portal page must also contain it.
    // Host-independent: inspects the captive page macOS was redirected to, so a
    // misconfigured Host can't stop login. With a marker set, the page must
    // contain it (recommended, to avoid submitting credentials on other captive
    // networks); without one, any page that has a fillable login form counts.
    // Fetches the captive page once, reports whether it's our portal, and hands
    // back the page so login() can reuse it without a second round-trip — faster,
    // so macOS closes its own captive popup sooner.
    func inspectCaptivePage(completion: @escaping (_ isOurPortal: Bool, _ page: CaptivePage?) -> Void) {
        fetchCaptivePage { url, html in
            guard let html = html else { completion(false, nil); return }
            let ours = Self.isOurPortal(html: html, marker: Settings.shared.portalMarker)
            completion(ours, CaptivePage(url: url, html: html))
        }
    }

    static func isOurPortal(html: String?, marker: String) -> Bool {
        guard let html = html else { return false }
        let trimmed = marker.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return html.localizedCaseInsensitiveContains(trimmed) }
        return LoginFormParser.parse(html: html) != nil
    }

    // Logs in by auto-discovering the portal's login form from the intercepted
    // page. Falls back to the manually configured endpoint if no form is found
    // (e.g. a JS-rendered portal), so behaviour is never worse than before.
    // Logs in using an already-fetched captive page. Falls back to the manually
    // configured endpoint if the page has no parseable login form.
    func login(page: CaptivePage, completion: @escaping (Bool) -> Void) {
        // Reading the password hits the Keychain, which blocks the calling thread
        // for as long as macOS keeps an authorization prompt on screen. This is
        // called from the main thread during auto-login, so do the read on a
        // background queue — otherwise an unanswered prompt freezes the whole app,
        // menu bar and monitors included. The completion already hops back to main
        // in AppDelegate.
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

    // GETs the probe URL; when captured, the portal serves (or redirects to) its
    // login page, so the response body is the login HTML and response.url is a
    // good base for resolving a relative form action.
    private func fetchCaptivePage(completion: @escaping (URL?, String?) -> Void) {
        var request = URLRequest(url: probeURL)
        request.timeoutInterval = 6
        let task = session.dataTask(with: request) { data, response, _ in
            completion(response?.url, data.flatMap { String(data: $0, encoding: .utf8) })
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
