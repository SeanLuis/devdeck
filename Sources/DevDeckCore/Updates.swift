import Foundation

/// A published version of the app, as GitHub's releases API describes it.
public struct AppRelease: Sendable, Hashable, Codable {
    public let version: String
    public let notes: String
    public let pageURL: String
    public let downloadURL: String?
    public let publishedAt: Date?

    public init(version: String, notes: String, pageURL: String, downloadURL: String?, publishedAt: Date?) {
        self.version = version; self.notes = notes; self.pageURL = pageURL; self.downloadURL = downloadURL; self.publishedAt = publishedAt
    }
}

public enum Updates {
    public static let repository = "SeanLuis/devdeck"
    public static var latestURL: URL { URL(string: "https://api.github.com/repos/\(repository)/releases/latest")! }

    /// "v0.10.2" → [0, 10, 2]. Anything after a "-" (pre-release tag) is ignored.
    static func numbers(_ version: String) -> [Int] {
        let core = version.trimmingCharacters(in: .whitespaces).drop { $0 == "v" || $0 == "V" }.split(separator: "-").first ?? ""
        return core.split(separator: ".").map { Int($0) ?? 0 }
    }

    /// True when `candidate` is a higher version than `current` (numeric, not alphabetical: 0.10 > 0.9).
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = numbers(candidate), b = numbers(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The JSON of `GET /repos/…/releases/latest`.
    public static func parse(_ data: Data) -> AppRelease? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let tag = obj["tag_name"] as? String,
              (obj["draft"] as? Bool) != true, (obj["prerelease"] as? Bool) != true else { return nil }
        let assets = (obj["assets"] as? [[String: Any]]) ?? []
        let zip = assets.first { ($0["name"] as? String) == "DevDeck.zip" }?["browser_download_url"] as? String
        let published = (obj["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let version = String(tag.drop { $0 == "v" || $0 == "V" })
        return AppRelease(version: version, notes: (obj["body"] as? String) ?? "", pageURL: (obj["html_url"] as? String) ?? "https://github.com/\(repository)/releases",
                          downloadURL: zip, publishedAt: published)
    }

    public static func fetchLatest() async throws -> AppRelease? {
        var request = URLRequest(url: latestURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DevDeck", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data)
    }

    public enum InstallError: LocalizedError {
        case noDownload, download, unpack, untrusted(String), replace(String)

        public var errorDescription: String? {
            switch self {
            case .noDownload: return L("Esta versión no trae un archivo para descargar.")
            case .download: return L("No se pudo descargar la actualización.")
            case .unpack: return L("No se pudo descomprimir la actualización.")
            case .untrusted(let why): return L("La descarga no pasó la verificación de seguridad y no se instaló: %@", why)
            case .replace(let why): return L("No se pudo reemplazar la aplicación: %@", why)
            }
        }
    }

    /// Team that signed an app bundle, or nil for ad-hoc/unsigned builds.
    public static func teamIdentifier(ofApp path: String) async -> String? {
        let result = await Shell.run("/usr/bin/codesign", ["-dv", path], timeout: 20)
        for line in (result.stderr + result.stdout).split(separator: "\n") where line.hasPrefix("TeamIdentifier=") {
            let team = String(line.dropFirst("TeamIdentifier=".count))
            return team == "not set" ? nil : team
        }
        return nil
    }

    public enum Stage: Sendable { case downloading, verifying, installing }

    /// A download that stalls or never ends fails with a message instead of leaving the update spinning.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    /// Downloads the release, checks that macOS accepts it as notarized and that it comes from the expected team,
    /// and puts it in place of `appPath`. The old app is only removed once the new one is verified.
    public static func install(_ release: AppRelease, replacing appPath: String, stage: @Sendable (Stage) async -> Void = { _ in }) async throws {
        guard let text = release.downloadURL, let url = URL(string: text), url.scheme == "https" else { throw InstallError.noDownload }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("devdeck-update-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let zip = work.appendingPathComponent("DevDeck.zip")
        await stage(.downloading)
        do {
            let (downloaded, response) = try await session.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw InstallError.download }
            try FileManager.default.moveItem(at: downloaded, to: zip)
        } catch let error as InstallError { throw error } catch { throw InstallError.download }

        await stage(.verifying)
        guard await Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path], timeout: 120).ok else { throw InstallError.unpack }
        let fresh = work.appendingPathComponent("DevDeck.app").path
        guard FileManager.default.fileExists(atPath: fresh) else { throw InstallError.unpack }

        // Trust: a valid signature, notarized by Apple, and signed by the same team as this app (when this one is signed).
        guard await Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", fresh], timeout: 60).ok else { throw InstallError.untrusted("codesign") }
        let gatekeeper = await Shell.run("/usr/sbin/spctl", ["--assess", "--type", "execute", "--verbose", fresh], timeout: 60)
        guard gatekeeper.ok, (gatekeeper.stderr + gatekeeper.stdout).contains("Notarized Developer ID") else { throw InstallError.untrusted("Gatekeeper") }
        let newTeam = await teamIdentifier(ofApp: fresh)
        if let current = await teamIdentifier(ofApp: appPath), current != newTeam { throw InstallError.untrusted("team \(newTeam ?? "?")") }
        guard newTeam != nil else { throw InstallError.untrusted("team") }

        await stage(.installing)
        let backup = appPath + ".previous"
        try? FileManager.default.removeItem(atPath: backup)
        do {
            try FileManager.default.moveItem(atPath: appPath, toPath: backup)
            do {
                try FileManager.default.copyItem(atPath: fresh, toPath: appPath)
            } catch {
                try? FileManager.default.moveItem(atPath: backup, toPath: appPath)
                throw error
            }
            try? FileManager.default.removeItem(atPath: backup)
        } catch {
            throw InstallError.replace(error.localizedDescription)
        }
    }
}
