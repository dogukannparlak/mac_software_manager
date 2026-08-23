import Foundation

/// The engine, inside the app.
///
/// There is no installation step for it and there never should have been. The
/// engine is `update_system.1h.sh` plus `lib/*.sh` - files this project writes,
/// released in the same build as the app that runs them. Copying them out of
/// the bundle into `~/Library/Application Support` and calling that "setting
/// up" would be the app installing itself, in front of the user, with a
/// progress log: an extra thing to go wrong, an extra thing to explain, and a
/// scary-looking step before a single update has been checked.
///
/// Three properties of the engine make running it in place possible, and all
/// three are load-bearing enough to state here:
///
/// * It writes nothing beside itself. Every path it writes hangs off
///   `$HOME/Library/Application Support/MacSoftwareUpdater`, which matters
///   because an app bundle is read-only and code-signed.
/// * It creates that state directory itself, on every run
///   (`mkdir -p "$APP_DIR" "$CACHE_DIR" "$LOCK_DIR"`), so nothing has to exist
///   beforehand.
/// * `settings.conf` is optional - with no config file it returns early and
///   runs on its defaults.
///
/// So the app points `MSU_LIB_DIR` at its own resources and runs the script
/// where it lies. What used to be a setup wizard step is now nothing at all.
enum BundledEngine {

    /// The library files the engine sources, without the `.sh`. Must match
    /// `LIB_NAMES` in update_system.1h.sh - the engine refuses to start with
    /// any of them missing, so an incomplete bundle has to be detectable here
    /// rather than at the point a run fails.
    static let libraryNames = [
        "utils", "cache", "ignored", "history", "selfupdate", "updaters",
        "selfupdate_apps", "app_install", "migrate", "run_modes", "menu"
    ]

    /// The engine this build ships, or `nil` if the bundle somehow has none.
    ///
    /// Both halves have to be there. A script with no library beside it exits
    /// with "Missing engine file" on its first line, which is a worse failure
    /// than falling back to whatever is installed on the Mac.
    static var scriptURL: URL? { resolved?.script }

    /// What to set `MSU_LIB_DIR` to so the engine sources this build's
    /// library rather than one left in the support folder by an older
    /// install.
    static var libraryDirectory: URL? { resolved?.library }

    /// The environment every invocation of the bundled engine needs. Empty
    /// when there is no bundled engine, so a caller can merge it
    /// unconditionally.
    static var environment: [String: String] {
        guard let library = libraryDirectory else { return [:] }
        return ["MSU_LIB_DIR": library.path(percentEncoded: false)]
    }

    /// `uninstall.sh` as shipped, for the Uninstall page to drive. Same
    /// reasoning as the engine: the script is ours, so there is no sense in
    /// requiring a copy of it to have been installed before the app can
    /// remove itself.
    static var uninstallScriptURL: URL? {
        locate("uninstall.sh")
    }

    // MARK: - Finding the files

    private struct Resolved {
        let script: URL
        let library: URL
    }

    /// Resolved once. The bundle does not change while the app is running,
    /// and this walks a few directories.
    private static let resolved: Resolved? = {
        guard let script = locate("update_system.1h.sh") else { return nil }
        guard let library = locateLibraryDirectory() else { return nil }
        return Resolved(script: script, library: library)
    }()

    /// The directory holding every `lib/*.sh`, whichever shape the build
    /// system left them in.
    ///
    /// The two disagree, and neither is wrong: SwiftPM keeps the folder
    /// (`…/EngineResources/lib/utils.sh`), while Xcode's synchronized group
    /// flattens every resource into `Contents/Resources`, so the same file
    /// arrives as `…/Resources/utils.sh`. The engine sources
    /// `$MSU_LIB_DIR/<name>.sh`, which means the flattened layout works
    /// untouched as long as `MSU_LIB_DIR` points at the flattened directory -
    /// so this returns whichever directory actually holds them.
    private static func locateLibraryDirectory() -> URL? {
        for root in resourceRoots() {
            for candidate in [
                root.appending(path: "EngineResources/lib", directoryHint: .isDirectory),
                root.appending(path: "lib", directoryHint: .isDirectory),
                root
            ] where holdsCompleteLibrary(candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Every library file, not just the first. A partial directory would let
    /// the engine start and die halfway through sourcing.
    private static func holdsCompleteLibrary(_ directory: URL) -> Bool {
        libraryNames.allSatisfy { name in
            FileManager.default.isReadableFile(
                atPath: directory.appending(path: "\(name).sh").path(percentEncoded: false)
            )
        }
    }

    private static func locate(_ name: String) -> URL? {
        for root in resourceRoots() {
            for candidate in [
                root.appending(path: "EngineResources/\(name)"),
                root.appending(path: name)
            ] where FileManager.default.isReadableFile(atPath: candidate.path(percentEncoded: false)) {
                return candidate
            }
        }
        return nil
    }

    /// Where a resource can be, across both build systems.
    ///
    /// `Bundle.module` would name the SwiftPM one directly, but it exists only
    /// in a SwiftPM build - referring to it would stop the Xcode target
    /// compiling, and that is the build that ships.
    private static func resourceRoots() -> [URL] {
        var roots: [URL] = []

        if let resources = Bundle.main.resourceURL {
            roots.append(resources)
        }

        let executableDirectory = Bundle.main.bundleURL.deletingLastPathComponent()
        if let siblings = try? FileManager.default.contentsOfDirectory(
            at: executableDirectory,
            includingPropertiesForKeys: nil
        ) {
            for sibling in siblings where sibling.pathExtension == "bundle" {
                roots.append(sibling)
                roots.append(sibling.appending(path: "Contents/Resources", directoryHint: .isDirectory))
            }
        }

        return roots
    }
}
