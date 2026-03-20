import Foundation
import Contacts

final class ContactsReader: @unchecked Sendable {
    private let store = CNContactStore()
    private let localStore: LocalStore
    private let logger: Logger
    private let refreshQueue = DispatchQueue(label: "com.blawby.agent.contacts.refresh", qos: .utility)
    private var observer: NSObjectProtocol?

    init(localStore: LocalStore, logger: Logger) {
        self.localStore = localStore
        self.logger = logger
    }

    func start() {
        guard observer == nil else { return }
        requestAccessAndRefresh()
        observer = NotificationCenter.default.addObserver(
            forName: .CNContactStoreDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.refreshAllContacts()
        }
    }

    func lookupContact(email: String) -> StoredContact? {
        localStore.lookupContact(email: email)
    }

    private func requestAccessAndRefresh() {
        store.requestAccess(for: .contacts) { [weak self] granted, error in
            guard let self else { return }
            if let error {
                self.logger.error("contacts access error: \(error.localizedDescription)")
                return
            }
            if !granted {
                self.logger.warning("contacts access denied")
                return
            }
            self.refreshAllContacts()
        }
    }

    private func refreshAllContacts() {
        refreshQueue.async { [weak self] in
            self?.refreshAllContactsOnQueue()
        }
    }

    private func refreshAllContactsOnQueue() {
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor
        ]

        let request = CNContactFetchRequest(keysToFetch: keys)
        var contacts: [StoredContact] = []
        do {
            try store.enumerateContacts(with: request) { contact, _ in
                let phones = contact.phoneNumbers.map { $0.value.stringValue }
                for email in contact.emailAddresses {
                    let normalized = String(email.value).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if normalized.isEmpty { continue }
                    contacts.append(
                        StoredContact(
                            email: normalized,
                            givenName: contact.givenName,
                            familyName: contact.familyName,
                            organizationName: contact.organizationName,
                            phoneNumbers: phones
                        )
                    )
                }
            }
            localStore.replaceContacts(contacts)
            logger.info("contacts refreshed count=\(contacts.count)")
        } catch {
            logger.error("contacts refresh failed: \(error.localizedDescription)")
        }
    }
    
    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
