import Darwin
import Foundation

enum PageReadError: Error, Equatable, LocalizedError {
    case blocked(String)
    case dnsFailure(String)
    case http(Int)
    case tooLarge
    case unsupportedContentType(String)
    case emptyContent
    case redirectLimit

    var errorDescription: String? {
        switch self {
        case .blocked(let reason): return "Blocked URL: \(reason)"
        case .dnsFailure(let host): return "DNS resolution failed for \(host)"
        case .http(let status): return "Page returned HTTP \(status)"
        case .tooLarge: return "Page exceeds the 4 MB response ceiling"
        case .unsupportedContentType(let type): return "Unsupported content type: \(type)"
        case .emptyContent: return "Page has no readable text"
        case .redirectLimit: return "Too many redirects"
        }
    }
}

/// Last-resort direct HTTPS reader. It only runs after Firecrawl fails, uses an
/// ephemeral session, rejects non-public hosts before and after every redirect,
/// and never executes JavaScript.
struct DirectHTMLReader: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    typealias Resolver = @Sendable (String) async throws -> [String]

    static let maxResponseBytes = 4 * 1024 * 1024
    static let maxCharacters = 12_000
    static let maxRedirects = 5
    static let timeout: TimeInterval = 25

    static let allowedContentTypes = [
        "text/html",
        "application/xhtml+xml",
        "text/plain",
        "application/xml",
        "text/xml",
    ]

    let transport: Transport
    let resolver: Resolver
    let now: @Sendable () -> Date

    init(
        transport: @escaping Transport = DirectHTMLReader.liveTransport,
        resolver: @escaping Resolver = DirectHTMLReader.liveResolver,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.resolver = resolver
        self.now = now
    }

    func read(urlString: String) async throws -> ResearchDocument {
        var current = try validatedURL(urlString)

        for redirectIndex in 0...Self.maxRedirects {
            try Task.checkCancellation()
            try await ensurePublicHost(current)

            var request = URLRequest(url: current)
            request.httpMethod = "GET"
            request.timeoutInterval = Self.timeout
            request.setValue(
                "text/html,application/xhtml+xml,text/plain,application/xml;q=0.9,*/*;q=0.5",
                forHTTPHeaderField: "Accept"
            )
            request.setValue("NewsBar/1.0 (macOS; Research)", forHTTPHeaderField: "User-Agent")

            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await transport(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as PageReadError {
                throw error
            } catch {
                throw PageReadError.http(0)
            }

            if (300...399).contains(response.statusCode),
               let location = response.value(forHTTPHeaderField: "Location") {
                guard redirectIndex < Self.maxRedirects else {
                    throw PageReadError.redirectLimit
                }
                guard let next = URL(string: location, relativeTo: current)?.absoluteURL else {
                    throw PageReadError.blocked("Invalid redirect target")
                }
                current = try validatedURL(next.absoluteString)
                continue
            }

            guard (200...299).contains(response.statusCode) else {
                throw PageReadError.http(response.statusCode)
            }

            if let declared = response.value(forHTTPHeaderField: "Content-Length"),
               let length = Int(declared),
               length > Self.maxResponseBytes {
                throw PageReadError.tooLarge
            }
            guard data.count <= Self.maxResponseBytes else {
                throw PageReadError.tooLarge
            }

            let contentType = (response.value(forHTTPHeaderField: "Content-Type") ?? "")
                .split(separator: ";", maxSplits: 1)
                .first
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            guard Self.allowedContentTypes.contains(contentType) else {
                throw PageReadError.unsupportedContentType(contentType)
            }

            let html = String(decoding: data, as: UTF8.self)
            let text = HTMLTextExtractor.text(from: html)
            guard text.count >= 40 else {
                throw PageReadError.emptyContent
            }

            let title = HTMLTextExtractor.title(from: html) ?? current.host ?? current.absoluteString
            return ResearchDocument(
                url: current.absoluteString,
                title: String(title.prefix(300)),
                text: String(text.prefix(Self.maxCharacters)),
                publishedAt: nil,
                fetchedAt: now(),
                source: .direct
            )
        }

        throw PageReadError.redirectLimit
    }

    // MARK: - Validation

    private func validatedURL(_ raw: String) throws -> URL {
        switch SecurityPolicies.validatePublicHTTPURL(raw) {
        case .valid(let url):
            return url
        case .blocked(let reason):
            throw PageReadError.blocked(reason)
        }
    }

    private func ensurePublicHost(_ url: URL) async throws {
        guard let host = url.host, !host.isEmpty else {
            throw PageReadError.blocked("Missing host")
        }
        if PublicAddressPolicy.isIPLiteral(host) {
            guard PublicAddressPolicy.isPublicAddress(host) else {
                throw PageReadError.blocked("Non-public IP address")
            }
            return
        }
        // Residual risk: URLSession resolves the host again when it connects,
        // so a rebinding resolver can still win this race. Closing it fully
        // needs a pinned-IP connection layer; the per-hop URL and DNS checks
        // remain the boundary for now and this is documented for users.
        let addresses: [String]
        do {
            addresses = try await resolver(host)
        } catch {
            throw PageReadError.dnsFailure(host)
        }
        guard !addresses.isEmpty else {
            throw PageReadError.dnsFailure(host)
        }
        guard addresses.allSatisfy({ PublicAddressPolicy.isPublicAddress($0) }) else {
            throw PageReadError.blocked("Host resolves to a non-public address")
        }
    }

    // MARK: - Live dependencies

    static let liveTransport: Transport = { request in
        do {
            return try await PrivateHTTP.data(
                for: request,
                maxBytes: maxResponseBytes,
                timeout: timeout
            )
        } catch PrivateHTTPError.tooLarge {
            throw PageReadError.tooLarge
        } catch let error as PageReadError {
            throw error
        } catch let error as CancellationError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw PageReadError.http(0)
        }
    }

    static let liveResolver: Resolver = { host in
        try resolveAddresses(host)
    }

    private static func resolveAddresses(_ host: String) throws -> [String] {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let first = result else {
            throw PageReadError.dnsFailure(host)
        }
        defer { freeaddrinfo(first) }

        var addresses: [String] = []
        var pointer: UnsafeMutablePointer<addrinfo>? = first
        while let info = pointer {
            if let address = info.pointee.ai_addr {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let nameStatus = getnameinfo(
                    address,
                    info.pointee.ai_addrlen,
                    &buffer,
                    socklen_t(buffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if nameStatus == 0 {
                    addresses.append(String(cString: buffer))
                }
            }
            pointer = info.pointee.ai_next
        }
        return addresses
    }
}

enum HTMLTextExtractor {
    static func title(from html: String) -> String? {
        guard let raw = firstCapture(pattern: #"<title[^>]*>([\s\S]*?)</title>"#, in: html) else {
            return nil
        }
        let decoded = decodeEntities(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded.isEmpty ? nil : decoded
    }

    static func text(from html: String) -> String {
        var value = html

        for tag in ["script", "style", "noscript", "svg", "iframe", "template", "object"] {
            value = replace(
                pattern: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>",
                in: value,
                with: " "
            )
        }
        value = replace(pattern: "<!--[\\s\\S]*?-->", in: value, with: " ")
        value = replace(pattern: "(?i)<br\\s*/?>", in: value, with: "\n")
        value = replace(pattern: "(?i)</(p|div|li|h[1-6]|tr|section|article)>", in: value, with: "\n")
        value = replace(pattern: "<[^>]+>", in: value, with: " ")
        value = decodeEntities(value)

        value = value.replacingOccurrences(of: "\r\n", with: "\n")
        value = value.replacingOccurrences(of: "\r", with: "\n")
        value = replace(pattern: "[ \\t\\u{00A0}]+", in: value, with: " ")
        value = replace(pattern: "\\n{3,}", in: value, with: "\n\n")
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstCapture(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let capture = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[capture])
    }

    private static func replace(pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    private static func decodeEntities(_ text: String) -> String {
        var value = text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&mdash;", with: "—")
            .replacingOccurrences(of: "&ndash;", with: "–")
            .replacingOccurrences(of: "&hellip;", with: "…")

        guard let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);", options: []) else {
            return value
        }
        let matches = regex.matches(in: value, options: [], range: NSRange(value.startIndex..., in: value))
        for match in matches.reversed() {
            guard let full = Range(match.range(at: 0), in: value),
                  let flag = Range(match.range(at: 1), in: value),
                  let digits = Range(match.range(at: 2), in: value) else { continue }
            let radix = value[flag].isEmpty ? 10 : 16
            guard let code = UInt32(String(value[digits]), radix: radix),
                  let scalar = Unicode.Scalar(code) else { continue }
            value.replaceSubrange(full, with: String(Character(scalar)))
        }
        return value
    }
}
