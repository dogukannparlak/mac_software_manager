import SwiftUI

/// The reading pane: one topic, rendered from its content blocks.
struct TopicDetailView: View {
    @Environment(LocalizationStore.self) private var loc

    let topic: GuideTopic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                ForEach(topic.sections) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        if let heading = section.heading {
                            Text(heading[loc.language])
                                .font(.title3.weight(.semibold))
                                .padding(.top, 4)
                        }

                        Card {
                            VStack(alignment: .leading, spacing: 14) {
                                ForEach(Array(section.blocks.enumerated()), id: \.offset) { _, block in
                                    blockView(block)
                                }
                            }
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(topic.title[loc.language])
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            IconTile(symbol: topic.symbol, size: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(topic.title[loc.language])
                    .font(.system(.largeTitle, design: .default).weight(.bold))

                Text(topic.summary[loc.language])
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func blockView(_ block: GuideBlock) -> some View {
        switch block {
        case .paragraph(let value):
            Text(value[loc.language])
                .fixedSize(horizontal: false, vertical: true)

        case .bullets(let values):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(values, id: \.self) { value in
                    BulletRow(text: value[loc.language])
                }
            }

        case .steps(let values):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    StepRow(index: index + 1, text: value[loc.language])
                }
            }

        case .note(let value):
            Callout(role: .note, text: value[loc.language])

        case .caution(let value):
            Callout(role: .caution, text: value[loc.language])
        }
    }
}
