import Foundation

/// Where the Installed Apps scan looks. Split from `InstalledInventory` to keep
/// that type within the length SwiftLint allows.
extension InstalledInventory {

    static func searchDirectories() -> [URL] {
        var directories = [URL(filePath: "/Applications")]

        let userApps = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Applications", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: userApps.path(percentEncoded: false)) {
            directories.append(userApps)
        }

        // Setapp keeps its catalogue in a subfolder
        let setapp = URL(filePath: "/Applications/Setapp")
        if FileManager.default.fileExists(atPath: setapp.path(percentEncoded: false)) {
            directories.append(setapp)
        }

        // Apps that install into a folder of their own ("Adobe Photoshop
        // 2025/Adobe Photoshop 2025.app", "/Applications/Utilities") were
        // invisible: only the top level was ever listed. One level down is
        // where installers put them; deeper than that is an app's own
        // business. Setapp is already above.
        for root in Array(directories) where root != setapp {
            directories += applicationSubfolders(of: root)
        }

        return directories
    }

    private static func applicationSubfolders(of root: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []

        return entries.filter { url in
            guard url.pathExtension != "app", url.lastPathComponent != "Setapp" else { return false }
            return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }
}
