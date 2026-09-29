import Foundation

enum ExtensionContributionError: LocalizedError, Equatable {
    case notBuilt(String)
    case missingExport(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notBuilt(let path): return "\(path) isn't part of this install."
        case .missingExport(let member): return "The bundle has no export named \(member)."
        case .failed(let message): return message
        }
    }
}

extension InstalledExtension {
    /// A contribution's bundle, or nil when the install lacks it.
    func bundleURL(forExport export: ExtensionExportRef) -> URL? {
        let url = export.fileURL(in: directory)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// Runs a contribution's export one-shot on the tool-session lane; search may keep one warm.
@MainActor
final class ExtensionContributionRunner {
    typealias SessionFactory = @MainActor (InstalledExtension, URL) async throws -> ExtensionToolSession

    static let warmLifetime: Duration = .seconds(30)
    static let defaultTimeout: Duration = .seconds(10)

    private struct WarmSession {
        let session: ExtensionToolSession
        var isBusy: Bool
        var expiry: Task<Void, Never>?
    }

    private let makeSession: SessionFactory
    private var warm: [String: WarmSession] = [:]
    /// One-shot sessions in flight, so switching extensions off can end them too.
    private var oneShots: [ObjectIdentifier: (extensionName: String, session: ExtensionToolSession)] = [:]

    init(makeSession: @escaping SessionFactory) {
        self.makeSession = makeSession
    }

    /// `keepWarm` reuses a loaded bundle for keystroke-rate calls; a failed call never reuses one.
    func runExport(
        _ export: ExtensionExportRef, of owner: InstalledExtension, input: JSONValue,
        timeout: Duration = defaultTimeout, keepWarm: Bool = false
    ) async throws -> JSONValue {
        guard let bundle = owner.bundleURL(forExport: export) else {
            throw ExtensionContributionError.notBuilt(export.path)
        }
        let key = owner.manifest.name + "\n" + export.path
        let session: ExtensionToolSession
        if keepWarm, var entry = warm[key], !entry.isBusy {
            entry.isBusy = true
            entry.expiry?.cancel()
            warm[key] = entry
            session = entry.session
        } else {
            session = try await makeSession(owner, bundle)
            if keepWarm, warm[key] == nil {
                warm[key] = WarmSession(session: session, isBusy: true)
            } else {
                oneShots[ObjectIdentifier(session)] = (owner.manifest.name, session)
            }
        }
        let outcome = await session.call(export.member, input: Self.encode(input), timeout: timeout)
        settle(session, key: key, reusable: !Task.isCancelled && outcome.isReturned)
        switch outcome {
        case .returned(.value(let value)): return value
        case .returned(.missing): throw ExtensionContributionError.missingExport(export.member)
        case .failed(let message): throw ExtensionContributionError.failed(message)
        }
    }

    func stop(extension name: String) {
        for (key, entry) in warm where key.hasPrefix(name + "\n") {
            entry.expiry?.cancel()
            warm[key] = nil
            entry.session.end()
        }
        for (id, running) in oneShots where running.extensionName == name {
            oneShots[id] = nil
            running.session.end()
        }
    }

    func stopAll() {
        let names = Set(warm.keys.compactMap { $0.split(separator: "\n").first.map(String.init) })
            .union(oneShots.values.map(\.extensionName))
        names.forEach(stop(extension:))
    }

    private func settle(_ session: ExtensionToolSession, key: String, reusable: Bool) {
        guard var entry = warm[key], entry.session === session else {
            oneShots[ObjectIdentifier(session)] = nil
            session.end()
            return
        }
        guard reusable else {
            warm[key] = nil
            session.end()
            return
        }
        entry.isBusy = false
        entry.expiry = Task { [weak self] in
            try? await Task.sleep(for: Self.warmLifetime)
            guard !Task.isCancelled else { return }
            self?.expire(key, session: session)
        }
        warm[key] = entry
    }

    private func expire(_ key: String, session: ExtensionToolSession) {
        guard let entry = warm[key], entry.session === session, !entry.isBusy else { return }
        warm[key] = nil
        session.end()
    }

    private static func encode(_ value: JSONValue) -> String {
        let data = try? JSONSerialization.data(withJSONObject: value.jsonObject, options: [.fragmentsAllowed])
        return data.flatMap { String(bytes: $0, encoding: .utf8) } ?? "{}"
    }
}

extension ExtensionToolSession.Outcome {
    fileprivate var isReturned: Bool {
        if case .returned = self { return true }
        return false
    }
}
