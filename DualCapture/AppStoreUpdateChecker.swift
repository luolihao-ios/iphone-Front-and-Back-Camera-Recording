import Foundation

struct AppStoreUpdate: Identifiable {
    let version: String
    let storeURL: URL

    var id: String { version }
}

enum AppStoreUpdateChecker {
    static let appID = "6795392492"
    static let lastCheckDefaultsKey = "appStoreUpdateLastCheckedAt"
    static let productURL = URL(string: "https://apps.apple.com/app/id\(appID)")!
    static let writeReviewURL = URL(string: "https://apps.apple.com/app/id\(appID)?action=write-review")!

    static func isStoreVersion(_ storeVersion: String, newerThan installedVersion: String) -> Bool {
        let storeParts = numericParts(of: storeVersion)
        let installedParts = numericParts(of: installedVersion)
        let count = max(storeParts.count, installedParts.count)

        for index in 0..<count {
            let store = index < storeParts.count ? storeParts[index] : 0
            let installed = index < installedParts.count ? installedParts[index] : 0
            if store != installed { return store > installed }
        }
        return false
    }

    static func fetchAvailableUpdate(installedVersion: String, defaults: UserDefaults = .standard) async -> AppStoreUpdate? {
        guard shouldCheckNow(defaults: defaults) else { return nil }
        defaults.set(Date(), forKey: lastCheckDefaultsKey)

        guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(appID)") else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return nil }
            let lookup = try JSONDecoder().decode(AppStoreLookupResponse.self, from: data)
            guard let result = lookup.results.first,
                  isStoreVersion(result.version, newerThan: installedVersion) else { return nil }
            return AppStoreUpdate(version: result.version, storeURL: URL(string: result.trackViewUrl) ?? productURL)
        } catch {
            return nil
        }
    }

    private static func shouldCheckNow(defaults: UserDefaults, now: Date = Date()) -> Bool {
        guard let lastCheck = defaults.object(forKey: lastCheckDefaultsKey) as? Date else { return true }
        return now.timeIntervalSince(lastCheck) >= 24 * 60 * 60
    }

    private static func numericParts(of version: String) -> [Int] {
        version.split(separator: ".").map { Int($0) ?? 0 }
    }
}

enum ReviewPromptPolicy {
    static func shouldRequest(successfulSaveCount: Int, lastPromptedVersion: String?, currentVersion: String) -> Bool {
        successfulSaveCount >= 3 && lastPromptedVersion != currentVersion
    }
}

enum AppVersion {
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}

private struct AppStoreLookupResponse: Decodable {
    let results: [AppStoreLookupResult]
}

private struct AppStoreLookupResult: Decodable {
    let version: String
    let trackViewUrl: String
}
