import AppKit
import SwiftUI

/// The shared output log for the Debug page, and the view that shows it.
///
/// English-only string literals here, like everywhere under `Views/Debug/` -
/// see the header of `DebugView.swift` for why that folder is the one
/// exception to `UIStrings`.

/// Timestamped stdout/stderr/notes from whatever the Debug page last ran.
///
/// One log shared by every section rather than one per panel: the sections
/// drive the same engine and the same files, and the question being asked is
/// almost always "what happened, in what order" across all of them - a cache
/// entry deleted here, a `run install` started there. Splitting that into
/// three scrollbacks would lose the ordering that makes it readable.
@MainActor
@Observable
final class DebugLog {

    /// Which pipe (or neither) the text came from. `note` is the app's own
    /// commentary - "started `run install foo dry`", "exit 0 in 1.4s" - kept
    /// apart from process output so a line the engine printed is never
    /// confused with a line this page wrote about it.
    enum Stream: Sendable {
        case stdout
        case stderr
        case note
    }

    struct Line: Identifiable, Sendable {
        let id = UUID()
        let at: Date
        let stream: Stream
        let text: String
    }

    private(set) var lines: [Line] = []

    /// Oldest lines are dropped past this. A `run all` on a busy machine
    /// prints tens of thousands of lines and every one of them would be a
    /// live SwiftUI row; the tail is what anybody debugging is reading
    /// anyway, and the whole point of this page is that it stays responsive
    /// while the engine is working.
    static let limit = 2000

    /// Says so when the head was dropped, for the same reason `StderrDrain`
    /// does (ToolkitRunner.swift): a truncated scrollback must never read as
    /// the whole run.
    private(set) var droppedLines = 0

    func append(_ text: String, stream: Stream, at date: Date = Date()) {
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            // A trailing newline splits into a final empty piece - that is
            // the separator, not a blank line the process printed.
            guard !line.isEmpty else { continue }
            lines.append(Line(at: date, stream: stream, text: line))
        }
        trim()
    }

    /// The page's own commentary: what was started, how it ended, how long
    /// it took.
    func note(_ text: String) {
        append(text, stream: .note)
    }

    func clear() {
        lines.removeAll()
        droppedLines = 0
    }

    /// Everything currently held, in the same shape it is drawn - what the
    /// Copy button puts on the pasteboard.
    var plainText: String {
        let body = lines.map { "\(Self.stamp($0.at)) \($0.prefix)\($0.text)" }.joined(separator: "\n")
        guard droppedLines > 0 else { return body }
        return "[... \(droppedLines) earlier lines dropped ...]\n" + body
    }

    private func trim() {
        guard lines.count > Self.limit else { return }
        let excess = lines.count - Self.limit
        lines.removeFirst(excess)
        droppedLines += excess
    }

    static func stamp(_ date: Date) -> String {
        stampFormatter.string(from: date)
    }

    /// Millisecond resolution on purpose: the thing being read off this log
    /// is often how long the engine sat between two lines.
    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

private extension DebugLog.Line {
    /// Marks the stream in the text itself, so a copied scrollback pasted
    /// into an issue keeps the distinction the colours carry on screen.
    var prefix: String {
        switch stream {
        case .stdout: return ""
        case .stderr: return "! "
        case .note: return "# "
        }
    }

    var tint: Color {
        switch stream {
        case .stdout: return .primary
        case .stderr: return .orange
        case .note: return .secondary
        }
    }
}

/// Monospaced, auto-scrolling, selectable view of a `DebugLog`.
struct DebugConsoleView: View {
    @Environment(DebugLog.self) private var log

    var height: CGFloat = 260

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Console")
                    .font(.headline)

                Text("\(log.lines.count) lines")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log.plainText, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                .disabled(log.lines.isEmpty)

                Button {
                    log.clear()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .controlSize(.small)
                .disabled(log.lines.isEmpty)
            }

            scrollback
        }
    }

    private var scrollback: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if log.droppedLines > 0 {
                        Text("[... \(log.droppedLines) earlier lines dropped ...]")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(log.lines) { line in
                        HStack(alignment: .top, spacing: 8) {
                            Text(DebugLog.stamp(line.at))
                                .foregroundStyle(.tertiary)
                            Text(line.text)
                                .foregroundStyle(line.tint)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .id(line.id)
                    }

                    // Scrolling to the last line leaves it flush against the
                    // bottom edge; an anchor below it keeps the newest output
                    // visible rather than half-clipped.
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .font(.caption.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .frame(height: height)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
            .onChange(of: log.lines.count) {
                // No animation: a live run appends several times a second and
                // an animated scroll never catches up with it.
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
    }

    private static let bottomAnchor = "debug-console-bottom"
}
