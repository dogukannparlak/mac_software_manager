import SwiftUI

/// Replays a run's `cache/progress` entries, and writes single frames by hand.
///
/// Refuses to write while a real run is in flight. `cache/progress` is the
/// one file two writers can collide on - the engine re-stamps it every few
/// seconds for as long as its run lives - and a fake frame landing in the
/// middle of a real run would not just confuse the banner, it would tell the
/// concurrency queue a run had ended when it had not.
///
/// English-only string literals - see the header of `DebugView.swift`.
struct DebugStateProgressPanel: View {
    @Environment(ToolkitController.self) private var toolkit
    @Environment(DebugStateStore.self) private var store
    @Environment(DebugLog.self) private var log

    @State private var simulator = DebugProgressSimulator()
    @State private var manualState = "running"
    @State private var manualPhase = "brew-upgrade"

    private var progressFile: URL { ToolkitPaths.cacheFile("progress") }

    /// A real run owns this file. Everything on the panel is gated on it.
    private var isBlocked: Bool { toolkit.isUpdating }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Progress")
                    .font(.headline)

                if isBlocked {
                    Callout(
                        role: .caution,
                        text: """
                        A real run is in flight and owns cache/progress. Writing a frame now would \
                        report an ending that has not happened. Wait for it to finish.
                        """
                    )
                }

                scriptPicker
                transport
                frameList
                Divider()
                manualFrame
            }
        }
    }

    // MARK: - Script

    private var scriptPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Script", selection: Binding(
                get: { simulator.script },
                set: { simulator.script = $0 }
            )) {
                ForEach(DebugProgressSimulator.Script.allCases) { script in
                    Text(script.label).tag(script)
                }
            }
            .pickerStyle(.menu)

            Text(simulator.script.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var transport: some View {
        HStack(spacing: 10) {
            Button {
                simulator.play { writeFrame($0) }
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .disabled(isBlocked || simulator.isPlaying || simulator.isFinished)

            Button {
                simulator.pause()
            } label: {
                Label("Pause", systemImage: "pause.fill")
            }
            .disabled(!simulator.isPlaying)

            Button {
                simulator.step { writeFrame($0) }
            } label: {
                Label("Step", systemImage: "forward.frame.fill")
            }
            .disabled(isBlocked || simulator.isPlaying || simulator.isFinished)

            Button {
                simulator.rewind()
            } label: {
                Label("Rewind", systemImage: "backward.end.fill")
            }
            .disabled(simulator.position == 0)

            Text("\(simulator.position)/\(simulator.frames.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Text("Speed")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { simulator.interval },
                set: { simulator.interval = $0 }
            ), in: 0.1...3.0)
                .frame(width: 120)
            Text(String(format: "%.1fs", simulator.interval))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }

    private var frameList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(simulator.frames) { frame in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: written(frame) ? "checkmark.circle.fill" : "circle")
                        .font(.caption2)
                        .foregroundStyle(written(frame) ? Color.green : Color.secondary.opacity(0.5))

                    Text(frame.summary)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)

                    if !frame.note.isEmpty {
                        Text("— \(frame.note)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func written(_ frame: DebugProgressSimulator.Frame) -> Bool {
        simulator.frames.firstIndex(where: { $0.id == frame.id }).map { $0 < simulator.position } ?? false
    }

    // MARK: - One frame by hand

    private var manualFrame: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Write one frame")
                .font(.subheadline.weight(.medium))

            HStack(spacing: 8) {
                Picker("State", selection: $manualState) {
                    ForEach(DebugProgressSimulator.stateTokens, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 170)

                Picker("Phase", selection: $manualPhase) {
                    ForEach(DebugProgressSimulator.phaseTokens, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 260)

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Button("Write") {
                    write(DebugFixtures.progress(state: manualState, phase: manualPhase, item: "alt-tab", index: 3, total: 8))
                }
                .disabled(isBlocked)

                Button("Age to stale") {
                    // Past staleAfterQuick, which is what makes a `running`
                    // entry read as a run that died. The long window applies
                    // only to the phases that can legitimately go quiet.
                    store.backdate(progressFile, by: UpdateProgress.staleAfterQuick + 60, log: log)
                    toolkit.reload()
                }
                .disabled(isBlocked)
                .help("Backdates the file past the 15-minute quick window, so the reader treats a running entry as dead.")

                Button("Malformed: wrong version") {
                    write("v2|running|brew-upgrade|alt-tab|3|8\n")
                }
                .disabled(isBlocked)

                Button("Malformed: unknown state") {
                    write("v1|maybe|brew-upgrade|alt-tab|3|8\n")
                }
                .disabled(isBlocked)

                Button("Delete entry") {
                    store.removeInjecting(progressFile, log: log)
                    toolkit.reload()
                }
                .disabled(isBlocked)

                Spacer(minLength: 0)
            }
            .controlSize(.small)

            Text("""
            Both malformed cases must produce "nothing to show", never a guessed outcome - the reader \
            fails closed on an unrecognised version and on an unrecognised state, which is the whole \
            point of the marker.
            """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Writing

    private func writeFrame(_ frame: DebugProgressSimulator.Frame) {
        write(frame.line)
    }

    private func write(_ contents: String) {
        store.write(contents, to: progressFile, log: log)
        // The controller only re-reads the progress file on reload; without
        // this the banner would not move until something else happened to
        // ask for one.
        toolkit.reload()
    }
}
