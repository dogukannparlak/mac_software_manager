import SwiftUI

/// One trigger per feature, each reporting what it did to the console.
///
/// The State section fakes what the app *reads*; this one drives what the app
/// *does*. Everything here calls the real controller and the real stores, so
/// a green line in the console means the feature works - not that a fixture
/// parsed.
///
/// English-only string literals - see the header of `DebugView.swift`.
struct DebugSectionFeatures: View {
    var body: some View {
        DebugFeatureMigrationPanel()
        DebugFeatureInventoryPanel()
        DebugFeatureConfigPanel()
        DebugFeatureIgnorePanel()
        DebugFeatureSelfUpdatePanel()

        Card {
            DebugConsoleView(height: 240)
        }
    }
}
