import Foundation
import Security

// Only synthetic credentials in memory: these checks never call the real keychain.
private final class MemoryKeychain {
    var items: [String: [String: Any]] = [:]
    var updateError: OSStatus?
    var readError: OSStatus?
    var addError: OSStatus?
    var deleteError: OSStatus?
    var failingAdds: Set<String> = []  // Services whose add fails, to stop a rebuild between its steps.
    var failingDeletes: Set<String> = []
    var updates = 0
    var access: KeyStore.Access {
        KeyStore.Access(
            read: { query in
                if let error = self.readError { return (error, nil) }
                guard let item = self.items[self.service(query)] else { return (errSecItemNotFound, nil) }
                return (errSecSuccess, item[kSecValueData as String] as? Data)
            },
            update: { query, attributes in
                self.updates += 1
                if let error = self.updateError { return error }
                let old = self.service(query)
                guard var item = self.items[old] else { return errSecItemNotFound }
                let new = attributes[kSecAttrService as String] as? String ?? old
                if new != old && self.items[new] != nil { return errSecDuplicateItem }
                item.merge(attributes) { _, new in new }
                self.items[old] = nil
                self.items[new] = item
                return errSecSuccess
            },
            add: { attributes in
                if let error = self.addError { return error }
                let name = self.service(attributes)
                if self.failingAdds.contains(name) { return errSecIO }
                guard self.items[name] == nil else { return errSecDuplicateItem }
                self.items[name] = attributes
                return errSecSuccess
            },
            delete: { query in
                if let error = self.deleteError { return error }
                if self.failingDeletes.contains(self.service(query)) { return errSecAuthFailed }
                return self.items.removeValue(forKey: self.service(query)) == nil ? errSecItemNotFound : errSecSuccess
            })
    }
    private func service(_ query: [String: Any]) -> String { query[kSecAttrService as String] as? String ?? "" }
    func seed(_ service: String, value: String) {
        items[service] = [kSecValueData as String: Data(value.utf8), kSecAttrAccount as String: "api-key"]
    }
}

extension ProcessingTests {
    func testKeychainNameMigration() throws {
        try Self.check(KeyStore.service == "io.github.nutcase.gijilog", "the keychain item belongs to Gijilog")
        let keychain = MemoryKeychain()
        keychain.seed(KeyStore.legacyService, value: "legacy-test-key")
        try Self.check(
            KeyStore.read(using: keychain.access) == "legacy-test-key", "the existing credential is retained")
        try Self.check(
            keychain.items[KeyStore.legacyService] == nil
                && keychain.items[KeyStore.service]?[kSecAttrLabel as String] as? String == KeyStore.label,
            "migration renames both the service and the displayed label")
        keychain.seed(KeyStore.legacyService, value: "older-test-key")
        let updates = keychain.updates
        try Self.check(
            KeyStore.read(using: keychain.access) == "legacy-test-key" && keychain.updates == updates,
            "an existing new item takes priority without being overwritten")
        keychain.readError = errSecAuthFailed
        try Self.check(
            KeyStore.read(using: keychain.access).isEmpty && keychain.updates == updates,
            "denied access to the new item does not migrate an older credential")

        let failed = MemoryKeychain()
        failed.seed(KeyStore.legacyService, value: "retained-test-key")
        failed.updateError = errSecAuthFailed
        try Self.check(
            KeyStore.read(using: failed.access) == "retained-test-key" && failed.items[KeyStore.legacyService] != nil,
            "failed migration leaves the legacy item available")
        failed.updateError = nil
        try Self.check(
            KeyStore.read(using: failed.access) == "retained-test-key" && failed.items[KeyStore.legacyService] == nil,
            "a later launch retries migration")
    }
    func testKeychainSaveAndDeleteAfterMigration() throws {
        let keychain = MemoryKeychain()
        keychain.seed(KeyStore.legacyService, value: "older-test-key")
        keychain.addError = errSecAuthFailed
        var rejected = false
        do { try KeyStore.save("new-test-key", using: keychain.access) } catch { rejected = true }
        try Self.check(rejected && keychain.items[KeyStore.legacyService] != nil, "failed saving preserves the old key")
        keychain.addError = nil
        try KeyStore.save("new-test-key", using: keychain.access)
        try Self.check(
            KeyStore.read(using: keychain.access) == "new-test-key" && keychain.items[KeyStore.legacyService] == nil,
            "saving writes the new service and removes the legacy fallback")
        try KeyStore.save("updated-test-key", using: keychain.access)
        try Self.check(
            KeyStore.read(using: keychain.access) == "updated-test-key", "saving again updates the same item")
        keychain.seed(KeyStore.legacyService, value: "older-test-key")
        keychain.deleteError = errSecAuthFailed
        try KeyStore.save("saved-despite-cleanup-error", using: keychain.access)
        try Self.check(
            KeyStore.read(using: keychain.access) == "saved-despite-cleanup-error"
                && keychain.items[KeyStore.legacyService] != nil,
            "a saved new key is usable even if legacy cleanup is denied")
        var deletionRejected = false
        do { try KeyStore.save("", using: keychain.access) } catch { deletionRejected = true }
        try Self.check(
            deletionRejected && KeyStore.read(using: keychain.access) == "saved-despite-cleanup-error",
            "clearing a key still reports failure if the legacy fallback cannot be removed")
        keychain.deleteError = nil
        try KeyStore.save("", using: keychain.access)
        try Self.check(
            keychain.items.isEmpty && KeyStore.read(using: keychain.access).isEmpty,
            "deletion cannot restore an old key")
        try KeyStore.save("", using: keychain.access)
    }
    // The item is made again under ギジログ's name; whichever step fails, the key is still in an item.
    func testKeychainItemRebuild() throws {
        let keychain = MemoryKeychain()
        keychain.seed(KeyStore.service, value: "rebuilt-test-key")
        try Self.check(
            KeyStore.rebuild("rebuilt-test-key", using: keychain.access)
                && keychain.items[KeyStore.service]?[kSecAttrLabel as String] as? String == KeyStore.label
                && keychain.items[KeyStore.spareService] == nil
                && KeyStore.read(using: keychain.access) == "rebuilt-test-key",
            "the item is made again with ギジログ's name, and the spare goes")
        let undeletable = MemoryKeychain()
        undeletable.seed(KeyStore.service, value: "kept-test-key")
        undeletable.failingDeletes = [KeyStore.service]
        try Self.check(
            !KeyStore.rebuild("kept-test-key", using: undeletable.access)
                && undeletable.items[KeyStore.spareService] == nil
                && KeyStore.read(using: undeletable.access) == "kept-test-key",
            "when the old item cannot be removed, it stays as it was and the spare goes")
        let stopped = MemoryKeychain()
        stopped.seed(KeyStore.service, value: "spare-test-key")
        stopped.failingAdds = [KeyStore.service]
        let rebuilt = KeyStore.rebuild("spare-test-key", using: stopped.access)
        let leftInSpare = stopped.items[KeyStore.service] == nil && stopped.items[KeyStore.spareService] != nil
        stopped.failingAdds = []
        try Self.check(
            !rebuilt && leftInSpare && KeyStore.read(using: stopped.access) == "spare-test-key"
                && stopped.items[KeyStore.service] != nil && stopped.items[KeyStore.spareService] == nil,
            "stopped between removing and adding, the key is in the spare, and reading puts it back")
        try Self.check(!KeyStore.rebuild("", using: keychain.access), "an empty key is not written")
    }
}
