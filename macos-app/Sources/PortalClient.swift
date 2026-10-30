import Foundation
import Network
import SystemConfiguration

enum ConnState {
    case connected   // real internet access
    case captured    // behind the portal / offline
}

// Fetched once and reused for the gating decision and the login submit.
struct CaptivePage {
    let url: URL?
    let html: String
    var hops = 0

    var isLoggedIn: Bool { LoginFormParser.isSessionPage(html: html) }

    // Logged on rejection: path and shape only, never the page body or host.
    var summary: String {
        let path = url.map { $0.path.isEmpty ? "/" : $0.path } ?? "?"
        let form = LoginFormParser.parse(html: html) == nil ? "no form" : "form"
        return "\(path), \(html.utf8.count) bytes, \(form), \(hops) redirect(s) followed"
    }
}

// Portal replies are read as they come; a followed redirect would lose the hop.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// Connectivity detection + captive-portal login.
final class PortalClient {
    private static let maxRedirectHops = 3
    private let probeURL: URL
    private let successMarker = "<TITLE>Success</TITLE>"
    private let wifiPath = NWPathMonitor(requiredInterfaceType: .wifi)
    private let wifiQueue = DispatchQueue(label: "wifi-butler.wifi-path")
    private var wifiInterface: String?

    init(probeURL: URL = URL(string: "http://captive.apple.com/hotspot-detect.html")!) {
        self.probeURL = probeURL
        wifiPath.pathUpdateHandler = { [weak self] path in
            self?.wifiInterface = path.availableInterfaces.first { $0.type == .wifi }?.name
        }
        wifiPath.start(queue: wifiQueue)
    }

    // NWPath.gateways reports the VPN's gateway; the Wi-Fi router comes from the per-service state.
    private var wifiGateway: String? {
        guard let name = wifiQueue.sync(execute: { wifiInterface }),
              let store = SCDynamicStoreCreate(nil, "WifiAutoLogin" as CFString, nil, nil),
              let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/[^/]+/IPv4" as CFString) as? [String]
        else { return nil }
        for key in keys {
            guard let state = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  state["InterfaceName"] as? String == name else { continue }
            return state["Router"] as? String
        }
        return nil
    }

    private var portalHost: String? { URL(string: Settings.shared.loginURL)?.host }

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: cfg, delegate: NoRedirects(), delegateQueue: nil)
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

    // Asks the portal first: internet may lag behind the login while a VPN reconnects.
    func confirmLogin(completion: @escaping (Bool) -> Void) {
        inspectCaptivePage { [weak self] ours, page in
            if ours, page?.isLoggedIn == true {
                completion(true)
            } else if let self = self {
                self.checkConnectivity { completion($0 == .connected) }
            } else {
                completion(false)
            }
        }
    }

    func login(page: CaptivePage, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                completion(false)
                return
            }
            let settings = Settings.shared
            let password = settings.password
            guard !password.isEmpty else {
                Log.write("No password from the Keychain — re-enter it in Settings.")
                completion(false)
                return
            }
            if let form = LoginFormParser.parse(html: page.html),
               let action = Self.resolve(action: form.action, base: page.url) {
                self.postForm(url: action,
                              fields: form.filled(username: settings.username, password: password),
                              completion: completion)
            } else {
                self.loginWithConfiguredEndpoint(password: password, completion: completion)
            }
        }
    }

    // Portals answer the probe with a login page or a meta/JS redirect page; follow those.
    // The marker gates the gateway page: a router's own admin login must never get the password.
    private func fetchCaptivePage(completion: @escaping (CaptivePage?) -> Void) {
        let marker = Settings.shared.portalMarker.trimmingCharacters(in: .whitespaces)
        guard !marker.isEmpty, let gateway = wifiGateway, let start = URL(string: "http://\(gateway)/login") else {
            fetchPage(probeURL, hops: 0, completion: completion)
            return
        }
        fetchPage(start, hops: 0) { [weak self] page in
            if let page = page {
                completion(page)
            } else if let self = self {
                self.fetchPage(self.probeURL, hops: 0, completion: completion)
            } else {
                completion(nil)
            }
        }
    }

    private func portalRequest(_ url: URL) -> URLRequest {
        let host = portalHost
        let routed = PortalRoute.url(url, portalHost: host, gateway: wifiGateway)
        var request = URLRequest(url: routed)
        if routed != url { request.setValue(host, forHTTPHeaderField: "Host") }
        return request
    }

    private func fetchPage(_ url: URL, hops: Int, completion: @escaping (CaptivePage?) -> Void) {
        var request = portalRequest(url)
        request.timeoutInterval = 6
        let task = session.dataTask(with: request) { [weak self] data, response, _ in
            guard let html = data.flatMap({ String(data: $0, encoding: .utf8) }) else {
                completion(nil)
                return
            }
            let page = CaptivePage(url: url, html: html, hops: hops)
            let location = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location")
                .flatMap { URL(string: $0, relativeTo: url)?.absoluteURL }
            guard let self = self, hops < Self.maxRedirectHops,
                  let next = location ?? LoginFormParser.redirectURL(html: html, base: page.url) else {
                completion(page)
                return
            }
            self.fetchPage(next, hops: hops + 1, completion: completion)
        }
        task.resume()
    }

    private func loginWithConfiguredEndpoint(password: String, completion: @escaping (Bool) -> Void) {
        let settings = Settings.shared
        guard let url = URL(string: settings.loginURL) else {
            completion(false)
            return
        }
        var fields: [(String, String)] = [
            ("username", settings.username),
            ("password", password),
        ]
        fields.append(contentsOf: Self.parseExtraFields(settings.extraFields))
        postForm(url: url, fields: fields, completion: completion)
    }

    private func postForm(url: URL, fields: [(String, String)], completion: @escaping (Bool) -> Void) {
        var request = portalRequest(url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(fields).data(using: .utf8)
        request.timeoutInterval = 15
        let task = session.dataTask(with: request) { _, response, error in
            let status = (response as? HTTPURLResponse).map { "HTTP \($0.statusCode)" } ?? "no response"
            Log.write("Login POST: \(status)\(error.map { " (error \(($0 as NSError).code))" } ?? "").")
            // The response body varies by portal; the caller confirms the login separately.
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
