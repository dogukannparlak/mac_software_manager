@testable import MacUpdaterGuide
import XCTest

/// Parsing tests for `NotificationRequest.parse(raw:)` - the
/// "v1|title|subtitle|body" format the shell engine's `notify()` (lib/utils.sh)
/// writes and NotificationBridge reads. See CACHE_FORMAT.md ("Notification
/// queue") for the schema both sides are required to agree on.
final class NotificationRequestParsingTests: XCTestCase {

    /// The exact example from CACHE_FORMAT.md - `tests/notify.bats` asserts
    /// the shell's `notify()` produces this same literal string, so this test
    /// and that one are the two halves of one producer/consumer agreement
    /// check.
    static let canonicalLine = "v1|Mac Software Manager|Update Complete|3 package(s) updated successfully."

    func testParsesTheCanonicalExampleFromCacheFormatDoc() {
        let request = NotificationRequest.parse(raw: Self.canonicalLine)
        XCTAssertEqual(request?.title, "Mac Software Manager")
        XCTAssertEqual(request?.subtitle, "Update Complete")
        XCTAssertEqual(request?.body, "3 package(s) updated successfully.")
    }

    func testEmptySubtitleFieldParsesAsEmptyString() {
        let request = NotificationRequest.parse(raw: "v1|Mac Software Manager||Plugin is up to date.")
        XCTAssertEqual(request?.subtitle, "")
        XCTAssertEqual(request?.body, "Plugin is up to date.")
    }

    func testMissingVersionFieldFailsToParse() {
        XCTAssertNil(NotificationRequest.parse(raw: "Mac Software Manager|Update Complete|Done."))
    }

    func testUnrecognizedVersionFailsToParse() {
        // A future incompatible format bump - fails closed rather than
        // parsing v2's fields as if they were v1's.
        XCTAssertNil(NotificationRequest.parse(raw: "v2|Mac Software Manager|Update Complete|Done."))
    }

    func testTooFewFieldsFailsToParse() {
        XCTAssertNil(NotificationRequest.parse(raw: "v1|Mac Software Manager|Update Complete"))
    }

    func testTooManyFieldsFailsToParse() {
        // No field may contain a literal '|' (CACHE_FORMAT.md convention) -
        // an extra field means the writer broke that rule, so this fails
        // closed rather than silently dropping the overflow.
        XCTAssertNil(NotificationRequest.parse(raw: "v1|Title|Subtitle|Body|Extra"))
    }

    func testEmptyStringFailsToParse() {
        XCTAssertNil(NotificationRequest.parse(raw: ""))
    }

    func testTrailingNewlineAndWhitespaceAreTrimmed() {
        let request = NotificationRequest.parse(raw: "  v1|Mac Software Manager||Done.  \n")
        XCTAssertEqual(request?.title, "Mac Software Manager")
        XCTAssertEqual(request?.body, "Done.")
    }
}
