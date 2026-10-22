import CryptoKit
import Foundation

public struct AWSCredentials: Codable, Sendable, Equatable {
    public var accessKeyId: String
    public var secretAccessKey: String
    public var sessionToken: String?
    public init(accessKeyId: String, secretAccessKey: String, sessionToken: String? = nil) {
        self.accessKeyId = accessKeyId; self.secretAccessKey = secretAccessKey; self.sessionToken = sessionToken
    }
}

/// AWS Signature Version 4 for a single request (no SDK).
public enum SigV4 {
    static func hex(_ d: some Sequence<UInt8>) -> String { d.map { String(format: "%02x", $0) }.joined() }
    static func sha256(_ d: Data) -> String { hex(SHA256.hash(data: d)) }
    static func hmac(_ key: Data, _ msg: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(msg.utf8), using: SymmetricKey(data: key)))
    }

    static func uriEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// Returns `headers` plus x-amz-date, (x-amz-security-token) and Authorization.
    public static func sign(method: String, url: URL, headers: [String: String], body: Data, service: String,
                            region: String, credentials: AWSCredentials, date: Date = Date()) -> [String: String] {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = fmt.string(from: date)
        let day = String(amzDate.prefix(8))

        var all = headers
        all["host"] = url.host!
        all["x-amz-date"] = amzDate
        if let t = credentials.sessionToken { all["x-amz-security-token"] = t }
        let lower = Dictionary(all.map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) }, uniquingKeysWith: { a, _ in a })
        let names = lower.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(lower[$0]!)\n" }.joined()
        let signedHeaders = names.joined(separator: ";")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let canonicalQuery = query.map { (uriEncode($0.name), uriEncode($0.value ?? "")) }.sorted { $0 < $1 }
            .map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        let path = url.path.isEmpty ? "/" : url.path.split(separator: "/", omittingEmptySubsequences: false)
            .map { uriEncode(String($0)) }.joined(separator: "/")
        let canonical = [method, path, canonicalQuery, canonicalHeaders, signedHeaders, sha256(body)].joined(separator: "\n")
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let toSign = ["AWS4-HMAC-SHA256", amzDate, scope, sha256(Data(canonical.utf8))].joined(separator: "\n")
        var key = hmac(Data("AWS4\(credentials.secretAccessKey)".utf8), day)
        for part in [region, service, "aws4_request"] { key = hmac(key, part) }
        let signature = hex(hmac(key, toSign))
        all["Authorization"] = "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyId)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        return all
    }
}

public struct Celebrity: Sendable, Equatable {
    public var name: String
    public var id: String
    public var confidence: Double
    public var urls: [String]
    /// Face box in the sent image, normalized 0-1.
    public var box: CGRect
}

public struct AWSError: Error, LocalizedError, Sendable {
    public var type: String
    public var message: String
    public var errorDescription: String? {
        switch type {
        case "UnrecognizedClientException": return "AWS doesn't recognise this access key. Check the Access Key ID."
        case "InvalidSignatureException": return "AWS rejected the signature. Check the Secret Access Key."
        case "AccessDeniedException": return "This AWS user isn't allowed to call Rekognition. Attach the rekognition:RecognizeCelebrities permission."
        default: return "\(type): \(message)"
        }
    }
    var isThrottle: Bool { type.contains("Throttl") || type.contains("ProvisionedThroughputExceeded") }
}

/// Amazon Rekognition RecognizeCelebrities over plain HTTPS.
public struct RekognitionClient: Sendable {
    public var credentials: AWSCredentials
    public var region: String

    public init(credentials: AWSCredentials, region: String) {
        self.credentials = credentials
        self.region = region
    }

    public func recognizeCelebrities(jpeg: Data) async throws -> [Celebrity] {
        let url = URL(string: "https://rekognition.\(region).amazonaws.com/")!
        let body = try JSONSerialization.data(withJSONObject: ["Image": ["Bytes": jpeg.base64EncodedString()]])
        let headers = SigV4.sign(method: "POST", url: url,
                                 headers: ["content-type": "application/x-amz-json-1.1",
                                           "x-amz-target": "RekognitionService.RecognizeCelebrities"],
                                 body: body, service: "rekognition", region: region, credentials: credentials)
        var attempt = 0
        while true {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.httpBody = body
            for (k, v) in headers where k != "host" { req.setValue(v, forHTTPHeaderField: k) }
            let (data, response) = try await URLSession.shared.data(for: req)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if (response as? HTTPURLResponse)?.statusCode == 200 { return Self.parse(json) }
            let err = AWSError(type: (json["__type"] as? String).map { $0.components(separatedBy: "#").last! } ?? "HTTP error",
                               message: (json["message"] ?? json["Message"]) as? String ?? String(decoding: data, as: UTF8.self))
            // Signatures stay valid for 5 minutes, so retrying the same signed request is fine.
            guard err.isThrottle, attempt < 5 else { throw err }
            attempt += 1
            try await Task.sleep(for: .milliseconds(400 << attempt))
        }
    }

    static func parse(_ json: [String: Any]) -> [Celebrity] {
        (json["CelebrityFaces"] as? [[String: Any]] ?? []).compactMap { c in
            guard let name = c["Name"] as? String else { return nil }
            let b = ((c["Face"] as? [String: Any])?["BoundingBox"] as? [String: Double]) ?? [:]
            return Celebrity(name: name, id: c["Id"] as? String ?? "", confidence: c["MatchConfidence"] as? Double ?? 0,
                             urls: c["Urls"] as? [String] ?? [],
                             box: CGRect(x: b["Left"] ?? 0, y: b["Top"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0))
        }
    }
}
