import Foundation

#if canImport(Security)
import Security

/// Keeps the token in the Keychain as a generic password.
///
/// Items are stored with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: available to a
/// background refresh after the first unlock, and never copied to another device or a backup. A
/// refresh token that syncs is a refresh token on hardware you did not authenticate.
public struct KeychainTokenStore: TokenStore {
    /// A Keychain failure, carrying the `OSStatus` so it can be looked up.
    public struct KeychainError: Error, Equatable, Sendable, LocalizedError {
        /// The operation that failed.
        public let operation: String
        /// The status the Keychain returned.
        public let status: Int32

        public var errorDescription: String? {
            "Keychain \(operation) failed with status \(status)."
        }
    }

    /// The service name items are filed under, usually a reverse-DNS identifier.
    public let service: String
    /// The account name, usually an identifier for the signed-in user or the API.
    public let account: String
    /// An optional access group, for sharing between an app and its extensions.
    public let accessGroup: String?

    /// Creates a Keychain-backed store.
    public init(service: String, account: String, accessGroup: String? = nil) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    /// The query identifying this store's item.
    ///
    /// Internal so a test can assert the attributes without touching the real Keychain, which is not
    /// available in every build environment.
    func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    public func load() async throws -> OAuth2Token? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError(operation: "read", status: status)
        }
        return try JSONDecoder().decode(OAuth2Token.self, from: data)
    }

    public func save(_ token: OAuth2Token) async throws {
        let data = try JSONEncoder().encode(token)
        let query = baseQuery()

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError(operation: "update", status: updateStatus)
        }

        var insert = query
        insert.merge(attributes) { current, _ in current }
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError(operation: "add", status: addStatus)
        }
    }

    public func clear() async throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(operation: "delete", status: status)
        }
    }
}
#endif
