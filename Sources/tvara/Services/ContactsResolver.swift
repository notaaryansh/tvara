import Contacts
import Foundation

/// One contact's identifiers extracted from Contacts.app.
struct ResolvedContact: Sendable {
    let displayName: String
    let phoneNumbers: [String]
    let emails: [String]
    let imageData: Data?
}

/// Wraps CNContactStore for name-based lookups. Used by AppleMessagesService
/// to surface phone-only contacts in iMessage search results (chat.db
/// doesn't carry contact names — those live in Contacts.app).
///
/// First call triggers the Contacts TCC prompt. Subsequent calls are
/// instant — CNContactStore caches its own access decision.
actor ContactsResolver {
    private let store = CNContactStore()
    private var accessDecided = false
    private var accessGranted = false

    private static let keys: [CNKeyDescriptor] = [
        CNContactGivenNameKey,
        CNContactFamilyNameKey,
        CNContactOrganizationNameKey,
        CNContactPhoneNumbersKey,
        CNContactEmailAddressesKey,
        CNContactImageDataKey,
        CNContactThumbnailImageDataKey,
    ] as [CNKeyDescriptor]

    /// Touch the store at app launch so the TCC prompt appears alongside
    /// the other permission prompts rather than as a surprise on first
    /// search.
    func warmCache() async {
        _ = await ensureAccess()
    }

    /// Substring name lookup. Returns at most `limit` matches, ordered by
    /// Contacts.app's own scoring. Empty list on no access or no match.
    func search(name: String, limit: Int = 5) async -> [ResolvedContact] {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return [] }
        guard await ensureAccess() else { return [] }

        let predicate = CNContact.predicateForContacts(matchingName: trimmed)
        let contacts: [CNContact]
        do {
            contacts = try store.unifiedContacts(matching: predicate, keysToFetch: Self.keys)
        } catch {
            return []
        }

        return contacts.prefix(limit).map { c in
            let name = [c.givenName, c.familyName]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let fallback = name.isEmpty ? c.organizationName : name
            return ResolvedContact(
                displayName: fallback,
                phoneNumbers: c.phoneNumbers.map { $0.value.stringValue },
                emails: c.emailAddresses.map { $0.value as String },
                imageData: c.thumbnailImageData ?? c.imageData
            )
        }
    }

    private func ensureAccess() async -> Bool {
        if accessDecided { return accessGranted }
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .authorized {
            accessDecided = true; accessGranted = true; return true
        }
        if status == .denied || status == .restricted {
            accessDecided = true; accessGranted = false; return false
        }
        let granted: Bool = await withCheckedContinuation { cont in
            store.requestAccess(for: .contacts) { ok, _ in
                cont.resume(returning: ok)
            }
        }
        accessDecided = true
        accessGranted = granted
        return granted
    }
}
