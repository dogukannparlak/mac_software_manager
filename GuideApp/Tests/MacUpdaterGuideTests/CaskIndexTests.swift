@testable import MacUpdaterGuide
import XCTest

/// `CaskIndex` (Toolkit/Caskroom.swift): which installed app a Homebrew cask
/// put there, from Homebrew's own recorded definition - so an app whose name
/// is nothing like its cask token (Docker.app / docker-desktop) is labelled
/// Homebrew rather than "Installed manually". Same cases as
/// tests/caskroom.bats, which covers the shell engine's copy of this logic.
final class CaskIndexTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "caskroom-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ token: String, version: String, stamp: String, ext: String, _ body: String) throws {
        let dir = root.appending(path: "\(token)/.metadata/\(version)/\(stamp)/Casks", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try body.write(to: dir.appending(path: "\(token).\(ext)"), atomically: true, encoding: .utf8)
    }

    func testAppWithUnrelatedNameIsOwnedByItsCask() throws {
        try write("docker-desktop", version: "4.30.0", stamp: "20240101120000.000", ext: "json", """
        {"token": "docker-desktop", "artifacts": [{"app": ["Docker.app"]}, {"zap": [{"trash": "~/x"}]}]}
        """)
        let index = CaskIndex.load(cachedTokens: [], roots: [root])
        XCTAssertEqual(index.owner(of: URL(filePath: "/Applications/Docker.app")), "docker-desktop")
        XCTAssertTrue(index.tokens.contains("docker-desktop"))
    }

    func testTargetNameIsTheNameInApplications() throws {
        try write("renamed", version: "1.1", stamp: "20240301000000.000", ext: "json", """
        {"artifacts":[{"app":["Source Name.app",{"target":"Pretty Name.app"}]}]}
        """)
        let index = CaskIndex.load(cachedTokens: [], roots: [root])
        XCTAssertEqual(index.owner(of: URL(filePath: "/Applications/Pretty Name.app")), "renamed")
        XCTAssertNil(index.owner(of: URL(filePath: "/Applications/Source Name.app")))
    }

    func testNewestDefinitionWins() throws {
        try write("renamed", version: "1.0", stamp: "20230101000000.000", ext: "json", #"{"artifacts":[{"app":["Old.app"]}]}"#)
        try write("renamed", version: "1.1", stamp: "20240301000000.000", ext: "json", #"{"artifacts":[{"app":["New.app"]}]}"#)
        let index = CaskIndex.load(cachedTokens: [], roots: [root])
        XCTAssertEqual(index.owner(of: URL(filePath: "/Applications/New.app")), "renamed")
        XCTAssertNil(index.owner(of: URL(filePath: "/Applications/Old.app")))
    }

    func testRubyDefinitionIsReadWithTargets() {
        let names = CaskIndex.appNames(fromRuby: """
        cask "tapcask" do
          version "2.0"
          app "Tap Thing.app", target: "Tap Target.app"
          app "Second.app"
          binary "tool"
        end
        """)
        XCTAssertEqual(names, ["Tap Target.app", "Second.app"])
    }

    func testCaskroomDirectoriesAddToCachedTokens() throws {
        try FileManager.default.createDirectory(
            at: root.appending(path: "no-metadata-yet", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        let index = CaskIndex.load(cachedTokens: ["alt-tab"], roots: [root])
        XCTAssertEqual(index.tokens, ["alt-tab", "no-metadata-yet"])
        XCTAssertTrue(index.appOwners.isEmpty)
    }
}
