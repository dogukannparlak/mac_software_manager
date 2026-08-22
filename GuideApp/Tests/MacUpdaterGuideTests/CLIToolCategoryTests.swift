@testable import MacUpdaterGuide
import XCTest

/// Tests for `CLIToolCategorizer` - the heuristic that groups the CLI Tools
/// list on the Installed Apps page. Real `brew desc` output for a mix of
/// installed formulae is used as fixtures so a change here is checked
/// against actual Homebrew phrasing, not an invented example.
final class CLIToolCategoryTests: XCTestCase {

    // MARK: - parseDescriptions ("token: description" lines)

    func testParsesTokenAndDescriptionSeparatedByFirstColon() {
        let result = CLIToolCategorizer.parseDescriptions(["git: Distributed revision control system"])
        XCTAssertEqual(result["git"], "Distributed revision control system")
    }

    func testSkipsLinesWithNoColon() {
        let result = CLIToolCategorizer.parseDescriptions(["not a valid line"])
        XCTAssertTrue(result.isEmpty)
    }

    func testHandlesEmptyToken() {
        let result = CLIToolCategorizer.parseDescriptions([": description with no token"])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Non-leaf formulae always land in .libraries

    func testNonLeafFormulaIsAlwaysLibrariesRegardlessOfDescription() {
        // "Official Amazon AWS command-line interface" would otherwise match
        // cloudDevOpsAI - the leaf/dependency split must win first.
        let category = CLIToolCategorizer.categorize(
            token: "aws-c-auth",
            description: "C99 library implementation of AWS client-side authentication",
            isLeaf: false
        )
        XCTAssertEqual(category, .libraries)
    }

    // MARK: - Leaf formulae, real `brew desc` output

    func testGitIsVersionControl() {
        XCTAssertEqual(
            categorizeLeaf("git", "Distributed revision control system"),
            .versionControl
        )
    }

    func testGitHubCLIIsVersionControl() {
        XCTAssertEqual(categorizeLeaf("gh", "GitHub command-line tool"), .versionControl)
    }

    func testAwsCliIsCloudDevOpsAI() {
        XCTAssertEqual(
            categorizeLeaf("awscli", "Official Amazon AWS command-line interface"),
            .cloudDevOpsAI
        )
    }

    func testGeminiCliIsCloudDevOpsAI() {
        XCTAssertEqual(
            categorizeLeaf("gemini-cli", "Interact with Google Gemini AI models from the command-line"),
            .cloudDevOpsAI
        )
    }

    func testDenoIsLanguagesRuntimes() {
        XCTAssertEqual(
            categorizeLeaf("deno", "Secure runtime for JavaScript and TypeScript"),
            .languagesRuntimes
        )
    }

    func testPythonIsLanguagesRuntimes() {
        XCTAssertEqual(
            categorizeLeaf("python@3.12", "Interpreted, interactive, object-oriented programming language"),
            .languagesRuntimes
        )
    }

    func testOpenJDKIsLanguagesRuntimes() {
        XCTAssertEqual(
            categorizeLeaf("openjdk@17", "Development kit for the Java programming language"),
            .languagesRuntimes
        )
    }

    func testCocoapodsIsBuildPackaging() {
        XCTAssertEqual(
            categorizeLeaf("cocoapods", "Dependency manager for Cocoa projects"),
            .buildPackaging
        )
    }

    func testTesseractIsMediaDocuments() {
        XCTAssertEqual(
            categorizeLeaf("tesseract", "OCR (Optical Character Recognition) engine"),
            .mediaDocuments
        )
    }

    func testYtDlpIsMediaDocuments() {
        XCTAssertEqual(
            categorizeLeaf("yt-dlp", "Feature-rich command-line audio/video downloader"),
            .mediaDocuments
        )
    }

    func testBatsCoreIsTesting() {
        XCTAssertEqual(
            categorizeLeaf("bats-core", "Bash Automated Testing System"),
            .testing
        )
    }

    func testUnrecognizedLeafFallsBackToOther() {
        // A real, if obscure, installed formula whose description does not
        // match any category rule.
        XCTAssertEqual(
            categorizeLeaf("merve", "C++ lexer for extracting named exports from CommonJS modules"),
            .other
        )
    }

    func testMissingDescriptionFallsBackToOther() {
        XCTAssertEqual(categorizeLeaf("some-tool", nil), .other)
    }

    // MARK: - librarySubcategory - real `brew desc` output for common
    // transitive dependencies, spanning every subcategory bucket.

    func testAwsComponentIsAwsSDKRegardlessOfWhatItDescribesItselfAs() {
        // "aws-c-compression"'s own description never says "compression" -
        // the token match ("aws-") has to be what catches it, and it must
        // win before the compression rule does.
        XCTAssertEqual(
            CLIToolCategorizer.librarySubcategory(
                token: "aws-c-compression",
                description: "C99 implementation of huffman encoding/decoding"
            ),
            .awsSDK
        )
    }

    func testNodeIsLanguageRuntimeSupport() {
        XCTAssertEqual(
            CLIToolCategorizer.librarySubcategory(
                token: "node",
                description: "Open-source, cross-platform JavaScript runtime environment"
            ),
            .languageRuntimeSupport
        )
    }

    func testLibnghttp2IsNetworkingSecurity() {
        XCTAssertEqual(
            CLIToolCategorizer.librarySubcategory(token: "libnghttp2", description: "HTTP/2 C Library"),
            .networkingSecurity
        )
    }

    func testCairoIsGraphicsMedia() {
        XCTAssertEqual(
            CLIToolCategorizer.librarySubcategory(
                token: "cairo",
                description: "Vector graphics library with cross-device output support"
            ),
            .graphicsMedia
        )
    }

    func testWebpIsGraphicsNotCompressionDespiteMentioningBoth() {
        // "Image format providing lossless and lossy compression" contains
        // both an image word and a compression word - graphics must win.
        XCTAssertEqual(
            CLIToolCategorizer.librarySubcategory(
                token: "webp",
                description: "Image format providing lossless and lossy compression"
            ),
            .graphicsMedia
        )
    }

    func testZstdIsCompression() {
        XCTAssertEqual(
            CLIToolCategorizer.librarySubcategory(
                token: "zstd",
                description: "Zstandard is a real-time compression algorithm"
            ),
            .compression
        )
    }

    func testIcu4cIsTextData() {
        XCTAssertEqual(
            CLIToolCategorizer.librarySubcategory(
                token: "icu4c@78",
                description: "C/C++ and Java libraries for Unicode and globalization"
            ),
            .textData
        )
    }

    func testSqliteIsDatabases() {
        XCTAssertEqual(
            CLIToolCategorizer.librarySubcategory(token: "sqlite", description: "Command-line interface for SQLite"),
            .databases
        )
    }

    func testLibx11IsWindowing() {
        XCTAssertEqual(
            CLIToolCategorizer.librarySubcategory(
                token: "libx11",
                description: "X.Org: Core X11 protocol client library"
            ),
            .windowing
        )
    }

    func testFontconfigIsGraphicsNotWindowingDespiteMentioningX() {
        // "XML-based font configuration API for X Windows" - the font match
        // must win before the loose "X" reference sends it to windowing.
        XCTAssertEqual(
            CLIToolCategorizer.librarySubcategory(
                token: "fontconfig",
                description: "XML-based font configuration API for X Windows"
            ),
            .graphicsMedia
        )
    }

    func testUnmatchedLibraryFallsBackToCore() {
        XCTAssertEqual(
            CLIToolCategorizer.librarySubcategory(
                token: "libffi",
                description: "Portable Foreign Function Interface library"
            ),
            .core
        )
    }

    func testCertifiDoesNotFalsePositiveIntoNetworkingSecurity() {
        // "Mozilla CA bundle for Python" says "CA bundle", not
        // "certificate" - must not match the certificate keyword.
        XCTAssertEqual(
            CLIToolCategorizer.librarySubcategory(token: "certifi", description: "Mozilla CA bundle for Python"),
            .core
        )
    }

    // MARK: - Helpers

    private func categorizeLeaf(_ token: String, _ description: String?) -> CLIToolCategory {
        CLIToolCategorizer.categorize(token: token, description: description, isLeaf: true)
    }
}
