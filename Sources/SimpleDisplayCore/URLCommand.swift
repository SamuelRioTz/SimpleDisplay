import Foundation

/// Parsed representation of a `simpledisplay://` URL. Every variant carries
/// validated, typed data — no raw strings leak from the parser into the app
/// or CLI layers.
public enum URLCommand: Equatable, Sendable {
    case create(VirtualDisplayRequest)
    case remove(RemoveTarget)
    case reconfigure(id: UInt32, request: VirtualDisplayRequest)
    case open
}

public enum RemoveTarget: Equatable, Sendable {
    case id(UInt32)
    case name(String)
}

public enum URLCommandError: Error, Equatable, Sendable, CustomStringConvertible {
    case wrongScheme(found: String?)
    case unknownHost(String)
    case missingHost
    case missingParameter(String)
    case invalidParameter(String, reason: String)
    case conflictingParameters(String)

    public var description: String {
        switch self {
        case .wrongScheme(let found):
            return "expected scheme 'simpledisplay', got '\(found ?? "<none>")'"
        case .unknownHost(let host):
            return "unknown action '\(host)' — expected create/remove/reconfigure/open"
        case .missingHost:
            return "URL has no action (expected simpledisplay://<action>)"
        case .missingParameter(let name):
            return "missing required parameter '\(name)'"
        case .invalidParameter(let name, let reason):
            return "invalid value for '\(name)': \(reason)"
        case .conflictingParameters(let reason):
            return reason
        }
    }
}

public enum URLCommandParser {
    public static let scheme = "simpledisplay"

    /// Parse a full `simpledisplay://...` URL into a typed command. Returns
    /// a detailed `URLCommandError` on any validation failure so callers can
    /// surface it to the user (or logs) verbatim.
    public static func parse(_ url: URL) -> Result<URLCommand, URLCommandError> {
        guard url.scheme?.lowercased() == scheme else {
            return .failure(.wrongScheme(found: url.scheme))
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(),
              !host.isEmpty
        else {
            return .failure(.missingHost)
        }
        let params = Params(items: components.queryItems ?? [])
        switch host {
        case "create":
            return parseCreate(params)
        case "remove":
            return parseRemove(params)
        case "reconfigure":
            return parseReconfigure(params)
        case "open":
            return .success(.open)
        default:
            return .failure(.unknownHost(host))
        }
    }

    // MARK: - Per-action parsing

    private static func parseCreate(_ p: Params) -> Result<URLCommand, URLCommandError> {
        parseRequest(p, requireName: false).map(URLCommand.create)
    }

    private static func parseRemove(_ p: Params) -> Result<URLCommand, URLCommandError> {
        let hasID = p.value("id") != nil
        let hasName = p.value("name") != nil
        switch (hasID, hasName) {
        case (true, true):
            return .failure(.conflictingParameters("remove accepts either 'id' or 'name', not both"))
        case (false, false):
            return .failure(.missingParameter("id-or-name"))
        case (true, _):
            switch p.requireUInt32("id") {
            case .success(let id): return .success(.remove(.id(id)))
            case .failure(let e): return .failure(e)
            }
        case (_, true):
            switch p.requireName("name") {
            case .success(let name): return .success(.remove(.name(name)))
            case .failure(let e): return .failure(e)
            }
        }
    }

    private static func parseReconfigure(_ p: Params) -> Result<URLCommand, URLCommandError> {
        switch p.requireUInt32("id") {
        case .success(let id):
            return parseRequest(p, requireName: false).map { req in
                .reconfigure(id: id, request: req)
            }
        case .failure(let err):
            return .failure(err)
        }
    }

    // MARK: - Shared: display-request body

    private static func parseRequest(
        _ p: Params,
        requireName: Bool
    ) -> Result<VirtualDisplayRequest, URLCommandError> {
        let width: Int
        switch p.requireDimension("width") {
        case .success(let v): width = v
        case .failure(let e): return .failure(e)
        }
        let height: Int
        switch p.requireDimension("height") {
        case .success(let v): height = v
        case .failure(let e): return .failure(e)
        }
        var request = VirtualDisplayRequest(width: width, height: height)

        if let raw = p.value("name") {
            switch validateName(raw) {
            case .success(let name): request.name = name
            case .failure(let e): return .failure(e)
            }
        } else if requireName {
            return .failure(.missingParameter("name"))
        }

        if p.value("refresh") != nil {
            switch p.optionalRefreshRate("refresh") {
            case .success(let v?): request.refreshRate = v
            case .success(nil): break
            case .failure(let e): return .failure(e)
            }
        }

        if let raw = p.value("hidpi") {
            switch parseBool(raw, name: "hidpi") {
            case .success(let b): request.hiDPI = b
            case .failure(let e): return .failure(e)
            }
        }

        return .success(request)
    }

    // MARK: - Field validators

    static func validateName(_ raw: String) -> Result<String, URLCommandError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .failure(.invalidParameter("name", reason: "cannot be empty"))
        }
        if trimmed.count > VirtualDisplayRequest.maxNameLength {
            return .failure(.invalidParameter(
                "name",
                reason: "max \(VirtualDisplayRequest.maxNameLength) characters"
            ))
        }
        // Guard against control chars sneaking in via an SSH/URL shell pipeline.
        if trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return .failure(.invalidParameter("name", reason: "contains control characters"))
        }
        return .success(trimmed)
    }

    static func parseBool(_ raw: String, name: String) -> Result<Bool, URLCommandError> {
        switch raw.lowercased() {
        case "1", "true", "yes", "on": return .success(true)
        case "0", "false", "no", "off": return .success(false)
        default:
            return .failure(.invalidParameter(name, reason: "expected true/false"))
        }
    }
}

// MARK: - Internal query-param helpers

private struct Params {
    let items: [URLQueryItem]

    func value(_ name: String) -> String? {
        items.first { $0.name.lowercased() == name.lowercased() }?.value
    }

    func requireUInt32(_ name: String) -> Result<UInt32, URLCommandError> {
        guard let raw = value(name) else {
            return .failure(.missingParameter(name))
        }
        guard let v = UInt32(raw) else {
            return .failure(.invalidParameter(name, reason: "expected integer in 0…\(UInt32.max)"))
        }
        return .success(v)
    }

    func requireDimension(_ name: String) -> Result<Int, URLCommandError> {
        guard let raw = value(name) else {
            return .failure(.missingParameter(name))
        }
        guard let v = Int(raw) else {
            return .failure(.invalidParameter(name, reason: "expected integer"))
        }
        let min = VirtualDisplayRequest.minDimension
        let max = VirtualDisplayRequest.maxDimension
        guard (min...max).contains(v) else {
            return .failure(.invalidParameter(name, reason: "must be between \(min) and \(max)"))
        }
        return .success(v)
    }

    func optionalRefreshRate(_ name: String) -> Result<Double?, URLCommandError> {
        guard let raw = value(name) else { return .success(nil) }
        guard let v = Double(raw), v >= 0 else {
            return .failure(.invalidParameter(name, reason: "expected non-negative number"))
        }
        if v > VirtualDisplayRequest.maxRefreshRate {
            return .failure(.invalidParameter(
                name,
                reason: "max \(VirtualDisplayRequest.maxRefreshRate) Hz"
            ))
        }
        return .success(v)
    }

    func requireName(_ name: String) -> Result<String, URLCommandError> {
        guard let raw = value(name) else {
            return .failure(.missingParameter(name))
        }
        return URLCommandParser.validateName(raw)
    }
}

// MARK: - URL construction (used by the CLI)

extension URLCommand {
    /// Build the canonical URL for this command. Used by the CLI to construct
    /// URLs it then hands to `open(1)`. Guarantees round-trip with the parser.
    public var url: URL {
        var components = URLComponents()
        components.scheme = URLCommandParser.scheme
        switch self {
        case .create(let req):
            components.host = "create"
            components.queryItems = requestQueryItems(req)
        case .remove(.id(let id)):
            components.host = "remove"
            components.queryItems = [URLQueryItem(name: "id", value: String(id))]
        case .remove(.name(let name)):
            components.host = "remove"
            components.queryItems = [URLQueryItem(name: "name", value: name)]
        case .reconfigure(let id, let req):
            components.host = "reconfigure"
            components.queryItems = [URLQueryItem(name: "id", value: String(id))] + requestQueryItems(req)
        case .open:
            components.host = "open"
        }
        guard let url = components.url else {
            fatalError("URLComponents failed to produce URL — this is a bug")
        }
        return url
    }

    private func requestQueryItems(_ r: VirtualDisplayRequest) -> [URLQueryItem] {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "width", value: String(r.width)),
            URLQueryItem(name: "height", value: String(r.height)),
        ]
        if r.name != VirtualDisplayRequest().name {
            items.append(URLQueryItem(name: "name", value: r.name))
        }
        if r.refreshRate != 60.0 {
            items.append(URLQueryItem(name: "refresh", value: String(r.refreshRate)))
        }
        if r.hiDPI {
            items.append(URLQueryItem(name: "hidpi", value: "true"))
        }
        return items
    }
}
