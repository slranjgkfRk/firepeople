import Foundation

extension URLSession {

    /// The app's session: 15s request timeout (README §3.5).
    ///
    /// A fresh session per access on purpose — `TossClient` takes one in its initialiser and keeps
    /// it, so exactly one is built per client, and no shared mutable session is left lying around
    /// for a second process to inherit.
    public static var fireDefault: URLSession { fire(timeout: 15) }

    /// Ephemeral, no connectivity waiting, no cache, no cookies. The widget passes `10`, which is
    /// the whole budget a timeline refresh gets (README §3.5).
    ///
    /// `waitsForConnectivity = false` matters more than it looks: a widget that waits for the radio
    /// to come back burns its extension time and renders nothing, whereas failing fast lets
    /// `RefreshService` fall back to the stored snapshot immediately.
    public static func fire(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = timeout
        // Payloads are a few kilobytes; the whole task gets the same budget as one request.
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpAdditionalHeaders = ["Accept": "application/json"]
        // openapi.tossinvest.com is HTTPS-only and there is no ATS exception anywhere (README §7).
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        return URLSession(configuration: configuration)
    }
}
