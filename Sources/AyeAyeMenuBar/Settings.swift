import Foundation
import Security

/// Where this installation is, which organisation new tasks go to, and the
/// token that proves who you are.
///
/// The token is the only thing here that is a secret, and it is the only
/// thing that does not live in `UserDefaults`. A personal access token is a
/// bearer credential: anything holding it can act as you against your
/// installation until you revoke it from the account screen. `UserDefaults`
/// is a plist in your home directory that every process you run can read,
/// so it goes in the Keychain instead — which costs about forty lines and
/// removes the whole question.
enum Settings {
    private static let baseURLKey = "baseURL"
    private static let orgIDKey = "organisationID"
    private static let orgNameKey = "organisationName"
    private static let detailsKey = "detailsExpanded"
    private static let sparkKey = "capturesSparks"

    /// The environment wins over anything stored, for all three settings.
    ///
    /// This is for scripts and for CI, and it earns its place twice over.
    /// A scripted `--create` shouldn't have to configure a machine first,
    /// or leave a token on a build agent's disk afterwards — and reading
    /// the Keychain from a freshly compiled binary provokes a system
    /// permission dialog every single build, because the item's ACL is tied
    /// to the code signature and a rebuild changes it. That dialog blocks
    /// forever where nobody can click it, which makes an env override the
    /// difference between this being testable and not.
    private static func env(_ name: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            return nil
        }
        return value
    }

    /// e.g. `https://ayeayecaptain.io` — no trailing slash, no `/mcp`.
    static var baseURL: String? {
        get { env("AYEAYE_SERVER") ?? UserDefaults.standard.string(forKey: baseURLKey) }
        set { UserDefaults.standard.set(newValue, forKey: baseURLKey) }
    }

    static var organisationID: String? {
        get { env("AYEAYE_ORG") ?? UserDefaults.standard.string(forKey: orgIDKey) }
        set { UserDefaults.standard.set(newValue, forKey: orgIDKey) }
    }

    /// Shown in the popover so you can see where a task is about to go. Kept
    /// alongside the id rather than looked up on open: this is a text box
    /// that has to appear instantly, and a network call to render a label
    /// would be the slowest thing in it.
    static var organisationName: String? {
        get { UserDefaults.standard.string(forKey: orgNameKey) }
        set { UserDefaults.standard.set(newValue, forKey: orgNameKey) }
    }

    /// Whether the popover opens with the extra fields showing.
    ///
    /// The *values* in them are deliberately not remembered — a box that
    /// quietly files your next thought into last week's project is worse than
    /// one that asks again — but whether you want to see them at all is a
    /// preference, not a value, and re-opening the same panel every time is
    /// the kind of small tax that makes people stop using the extra fields.
    static var detailsExpanded: Bool {
        get { UserDefaults.standard.bool(forKey: detailsKey) }
        set { UserDefaults.standard.set(newValue, forKey: detailsKey) }
    }

    /// Whether the box files a spark rather than a task.
    ///
    /// Remembered, unlike anything in the Details panel — and the difference
    /// is that this one is never quiet. The panel's *values* are hidden the
    /// moment it is closed, which is why applying last week's project to
    /// today's thought would be a thing done behind your back; the mode is
    /// spelled out three times on a box you are looking at (the picker, the
    /// placeholder in the field, and the hint beside it). Somebody who
    /// mostly captures sparks shouldn't have to say so every time.
    static var capturesSparks: Bool {
        get { UserDefaults.standard.bool(forKey: sparkKey) }
        set { UserDefaults.standard.set(newValue, forKey: sparkKey) }
    }

    /// Enough to reach the server as you: an address and a token.
    ///
    /// Which is the whole bar for a spark, because a spark has no
    /// organisation — the server's own record carries no `organisation_id`,
    /// so somebody who has been invited nowhere yet can still capture one.
    static var isConnected: Bool {
        guard let base = baseURL, !base.isEmpty else { return false }
        return token != nil
    }

    /// The above, plus somewhere for a task to go.
    static var isConfigured: Bool {
        guard isConnected else { return false }
        guard let org = organisationID, !org.isEmpty else { return false }
        return true
    }

    // MARK: - The token

    private static let service = "com.bitroot.ayeaye-menubar"
    private static let account = "personal-access-token"

    static var token: String? {
        get {
            // Checked before the Keychain, so a scripted run never touches
            // it — see `env` above for why that matters more than it looks.
            if let fromEnv = env("AYEAYE_TOKEN") { return fromEnv }
            var query = baseQuery()
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data,
                  let value = String(data: data, encoding: .utf8),
                  !value.isEmpty
            else { return nil }
            return value
        }
        set {
            // Delete first, then add. `SecItemUpdate` needs the item to
            // already exist and returns errSecItemNotFound when it doesn't,
            // so "delete then add" is one path for both cases instead of
            // two with a branch that is only exercised on first run — which
            // is exactly the branch that would go untested.
            SecItemDelete(baseQuery() as CFDictionary)
            guard let value = newValue, !value.isEmpty,
                  let data = value.data(using: .utf8) else { return }
            var query = baseQuery()
            query[kSecValueData as String] = data
            // This machine only. A token synced to iCloud would outlive the
            // laptop it was minted for, and there is no iOS app to sync to.
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
