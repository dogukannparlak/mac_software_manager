import SwiftUI

/// Runs `update_system.*.sh` by hand, and drives the controller entry points
/// the rest of the app calls.
///
/// The engine is invoked exactly the way `ToolkitController` invokes it -
/// `/bin/zsh <script> run <mode> …` - so what happens here is what happens
/// when a button elsewhere in the app is pressed. The difference is that the
/// command line is on screen before it runs and the output is not thrown
/// away.
///
/// English-only string literals - see the header of `DebugView.swift`.
struct DebugSectionEngine: View {
    @Environment(ToolkitController.self) private var toolkit
    @Environment(DebugLog.self) private var log

    @State private var runner = DebugProcessRunner()
    @State private var mode: EngineMode = .plugin
    @State private var arguments = ""
    @State private var dryRun = true
    @State private var scope: LaunchScope = .all
    @State private var pending: PendingAction?

    var body: some View {
        enginePanel
        controllerPanel

        Card {
            DebugConsoleView(height: 320)
        }
        .confirmationDialog(
            pending?.title ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { action in
            Button(action.confirmLabel, role: .destructive) { perform(action) }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { action in
            Text(action.message)
        }
    }

    // MARK: - Engine panel

    private var enginePanel: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Run the engine")
                    .font(.headline)

                Picker("Mode", selection: $mode) {
                    ForEach(EngineMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(mode.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("Arguments", text: $arguments, prompt: Text(mode.argumentHint))
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .disabled(!mode.takesArguments)

                Toggle("Dry run", isOn: $dryRun)
                    .disabled(!mode.supportsDryRun)
                    .help(mode.supportsDryRun
                          ? "Adds the engine's own 'dry' positional - nothing is installed."
                          : "This mode has no dry-run form in the engine.")

                commandPreview
                runControls

                if let caution = mode.caution {
                    Callout(role: .caution, text: caution)
                }
            }
        }
    }

    /// The exact argv, shown before it runs.
    ///
    /// The engine's positionals are order-dependent and undocumented at the
    /// call site (`run install <name> <live|dry>`, `run migrate <app>
    /// <token> <mode>`), and a dry-run switch that quietly appends a token
    /// is the kind of thing that gets misread as "nothing happened" when
    /// something did. Printing the line removes the guess.
    private var commandPreview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Command")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(previewText)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                }
        }
    }

    private var previewText: String {
        guard let script = toolkit.scriptURL else { return "no engine script found - see Environment" }
        return (["/bin/zsh", script.path(percentEncoded: false)] + engineArguments).joined(separator: " ")
    }

    private var runControls: some View {
        HStack(spacing: 10) {
            Button(role: mode.installsPackages ? .destructive : nil) {
                if mode.installsPackages, !(dryRun && mode.supportsDryRun) {
                    pending = .engine(mode)
                } else {
                    startEngine()
                }
            } label: {
                Label("Run", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(mode.installsPackages && !(dryRun && mode.supportsDryRun) ? .red : .accentColor)
            .disabled(runner.isRunning || toolkit.scriptURL == nil)

            if runner.isRunning {
                Button(role: .destructive) {
                    runner.stop(log: log)
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }

                ProgressView().controlSize(.small)

                if let description = runner.runningDescription {
                    Text(description)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else if let outcome = runner.lastOutcome {
                Label(outcome.summary, systemImage: outcome.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(outcome.succeeded ? .green : .orange)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Controller panel

    private var controllerPanel: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("ToolkitController")
                    .font(.headline)

                Text("""
                The same entry points the rest of the app calls. Output goes wherever the \
                controller sends it - the progress banner, the failure banner - not to the \
                console below.
                """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button("reload()") {
                        log.note("ToolkitController.reload()")
                        toolkit.reload()
                    }
                    Button("refresh(force: true)") {
                        log.note("ToolkitController.refresh(force: true)")
                        toolkit.refresh(force: true)
                    }
                    .disabled(toolkit.isRefreshing)
                    Button("checkToolkitUpdate()") {
                        log.note("ToolkitController.checkToolkitUpdate()")
                        toolkit.checkToolkitUpdate()
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    Button("checkHomebrewDatabase()") {
                        log.note("ToolkitController.checkHomebrewDatabase()")
                        toolkit.checkHomebrewDatabase()
                    }
                    .disabled(toolkit.isUpdating)
                    Spacer(minLength: 0)
                }

                Divider()
                launchUpdateControls
            }
        }
    }

    private var launchUpdateControls: some View {
        HStack(spacing: 8) {
            Picker("Scope", selection: $scope) {
                ForEach(LaunchScope.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            Button(role: .destructive) {
                pending = .launchUpdate(scope)
            } label: {
                Label("launchUpdate(scope:)", systemImage: "exclamationmark.triangle.fill")
            }
            .tint(.red)
            .disabled(toolkit.isUpdating)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Running

    /// `run <mode> …` plus whatever the mode's own trailing positional is.
    ///
    /// `install` always needs its live/dry token - the engine reads it
    /// positionally and treats a missing one as "live". `migrate` takes its
    /// mode in the same slot, so a dry run appends `dry` and anything else
    /// is left exactly as typed rather than guessed at.
    private var engineArguments: [String] {
        var argv = ["run", mode.rawValue] + DebugArguments.split(arguments)
        switch mode {
        case .install:
            argv.append(dryRun ? "dry" : "live")
        case .migrate:
            if dryRun { argv.append("dry") }
        case .plugin, .system, .all, .single:
            break
        }
        return argv
    }

    private func startEngine() {
        guard let script = toolkit.scriptURL else {
            log.note("No engine script found - see the Environment panel.")
            return
        }
        runner.run(
            executable: URL(filePath: "/bin/zsh"),
            arguments: [script.path(percentEncoded: false)] + engineArguments,
            log: log
        )
    }

    private func perform(_ action: PendingAction) {
        pending = nil
        switch action {
        case .engine:
            startEngine()
        case .launchUpdate(let scope):
            log.note("ToolkitController.launchUpdate(scope: \"\(scope.rawValue)\")")
            toolkit.launchUpdate(scope: scope.rawValue)
        }
    }
}
