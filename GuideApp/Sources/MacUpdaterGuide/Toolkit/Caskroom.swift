import Foundation

/// Which installed apps Homebrew put there, read from Homebrew's own records
/// rather than guessed from the app's name.
///
/// Every installed cask keeps a copy of its definition in the Caskroom:
/// `<prefix>/Caskroom/<token>/.metadata/<version>/<timestamp>/Casks/<token>.json`
/// (`.rb` for casks installed from a tap's Ruby file). That definition lists
/// the exact `.app` the cask moved into Applications - "Docker.app" for
/// `docker-desktop`, "Microsoft Word.app" for `microsoft-word` - which no
/// amount of name munging (`InstalledInventory.caskCandidates`) can recover.
///
/// Read straight off disk: no `brew` process, and no dependence on the
/// `brew_casks` cache entry having been written yet - a token directory in
/// the Caskroom is itself proof the cask is installed.
struct CaskIndex: Sendable {
    /// Installed cask tokens.
    var tokens: Set<String> = []
    /// Lowercased `.app` file name -> the cask token that installed it.
    var appOwners: [String: String] = [:]

    /// The cask that installed `appURL`, if Homebrew's records say one did.
    func owner(of appURL: URL) -> String? {
        appOwners[appURL.lastPathComponent.lowercased()]
    }

    static let caskroomRoots = [
        URL(filePath: "/opt/homebrew/Caskroom", directoryHint: .isDirectory),
        URL(filePath: "/usr/local/Caskroom", directoryHint: .isDirectory)
    ]

    /// The tokens from the `brew_casks` cache entry, plus everything the
    /// Caskroom says is installed and which apps those casks own.
    static func load(cachedTokens: Set<String>, roots: [URL] = caskroomRoots) -> CaskIndex {
        var index = CaskIndex(tokens: cachedTokens)
        let fileManager = FileManager.default

        for root in roots {
            guard let tokenDirectories = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for directory in tokenDirectories {
                let token = directory.lastPathComponent
                index.tokens.insert(token)
                for app in appNames(inCaskDirectory: directory, token: token) {
                    index.appOwners[app.lowercased()] = token
                }
            }
        }
        return index
    }

    /// The newest recorded definition of one installed cask, parsed for its
    /// `app` artifacts.
    static func appNames(inCaskDirectory directory: URL, token: String) -> [String] {
        let fileManager = FileManager.default
        let metadata = directory.appending(path: ".metadata", directoryHint: .isDirectory)

        // Version and timestamp folders both sort correctly as plain strings
        // often enough, but not always ("10.0" vs "9.0") - so every recorded
        // definition is read, newest timestamp first, and the first one that
        // names an app wins.
        var definitions: [(stamp: String, url: URL)] = []
        let versions = (try? fileManager.contentsOfDirectory(at: metadata, includingPropertiesForKeys: nil)) ?? []
        for version in versions {
            let stamps = (try? fileManager.contentsOfDirectory(at: version, includingPropertiesForKeys: nil)) ?? []
            for stamp in stamps {
                let casks = stamp.appending(path: "Casks", directoryHint: .isDirectory)
                for name in ["\(token).json", "\(token).rb"] {
                    let file = casks.appending(path: name)
                    if fileManager.fileExists(atPath: file.path(percentEncoded: false)) {
                        definitions.append((stamp.lastPathComponent, file))
                    }
                }
            }
        }

        for definition in definitions.sorted(by: { $0.stamp > $1.stamp }) {
            guard let data = try? Data(contentsOf: definition.url) else { continue }
            let apps = definition.url.pathExtension == "json"
                ? appNames(fromJSON: data)
                : appNames(fromRuby: String(bytes: data, encoding: .utf8) ?? "")
            if !apps.isEmpty { return apps }
        }
        return []
    }

    /// `"artifacts": [{"app": ["Foo.app"]}, {"app": ["Foo.app", {"target": "Bar.app"}]}, ...]`
    /// - the target's file name when there is one, since that is the name
    /// the app actually has in Applications.
    static func appNames(fromJSON data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let artifacts = root["artifacts"] as? [Any] else { return [] }

        var names: [String] = []
        for case let artifact as [String: Any] in artifacts {
            guard let app = artifact["app"] as? [Any],
                  let source = app.first as? String else { continue }
            let options = app.dropFirst().compactMap { $0 as? [String: Any] }.first
            let target = options?["target"] as? String
            names.append(fileName(of: target ?? source))
        }
        return names
    }

    /// `app "Foo.app"` / `app "Foo.app", target: "Bar.app"` lines of a
    /// cask's Ruby definition.
    static func appNames(fromRuby text: String) -> [String] {
        var names: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("app ") || trimmed.hasPrefix("app\t") else { continue }
            let quoted = trimmed.split(separator: "\"", omittingEmptySubsequences: false)
            // app "Source.app", target: "Target.app"  ->  [app , Source.app, , target: , Target.app, ]
            guard quoted.count >= 3 else { continue }
            let source = String(quoted[1])
            let target = trimmed.contains("target:") && quoted.count >= 5 ? String(quoted[3]) : nil
            names.append(fileName(of: target ?? source))
        }
        return names
    }

    /// "Foo.app", "Utilities/Foo.app" and "~/Applications/Foo.app" all name
    /// the bundle by its last path component.
    private static func fileName(of path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
