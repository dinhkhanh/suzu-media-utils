import FaceLibrary
import Foundation
import Security

/// AWS settings for celebrity naming. Keys live in the login Keychain; region and threshold in UserDefaults.
enum AWSSettings {
    static let service = "dk.dinhkhanh.suzumediautils.aws"
    static let legacyService = "dk.dinhkhanh.facegrouping.aws"

    static var credentials: AWSCredentials? {
        get { read(service) ?? read(legacyService) }
        set {
            let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
            SecItemDelete(base as CFDictionary)
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else { return }
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "SuZu Media Utils – Amazon Rekognition"
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func read(_ service: String) -> AWSCredentials? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(AWSCredentials.self, from: data)
    }

    /// Singapore is the closest Rekognition region to Vietnam.
    static var region: String {
        get { UserDefaults.standard.string(forKey: "awsRegion") ?? "ap-southeast-1" }
        set { UserDefaults.standard.set(newValue, forKey: "awsRegion") }
    }

    static var minConfidence: Double {
        get { UserDefaults.standard.object(forKey: "celebrityMinConfidence") as? Double ?? 90 }
        set { UserDefaults.standard.set(newValue, forKey: "celebrityMinConfidence") }
    }

    static var client: RekognitionClient? {
        credentials.map { RekognitionClient(credentials: $0, region: region) }
    }
}
