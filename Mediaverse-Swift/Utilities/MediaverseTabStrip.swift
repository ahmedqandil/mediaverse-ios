import SwiftUI

struct MediaverseTabItem: Identifiable, Equatable {
    let id: String
    let label: String
    let count: Int?
    let iconName: String?
    let fallbackSystemName: String?

    init(
        id: String,
        label: String,
        count: Int? = nil,
        iconName: String? = nil,
        fallbackSystemName: String? = nil
    ) {
        self.id = id
        self.label = label
        self.count = count
        self.iconName = iconName
        self.fallbackSystemName = fallbackSystemName
    }
}

struct MediaverseUnderlineTabStrip: View {
    let items: [MediaverseTabItem]
    let selectedID: String
    var fillsWidth = false
    var horizontalPadding: CGFloat = C.pagePad
    var verticalPadding: CGFloat = 12
    var background: Color = C.bg
    var loadingID: String? = nil
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                Button {
                    onSelect(item.id)
                } label: {
                    HStack(spacing: 4) {
                        if let iconName = item.iconName {
                            MediaverseIcon(
                                name: iconName,
                                fallbackSystemName: item.fallbackSystemName ?? "circle"
                            )
                            .frame(width: 16, height: 16)
                        }
                        Text(item.label)
                            .font(.subheadline.weight(isSelected(item) ? .semibold : .regular))
                        if let count = item.count, count > 0 {
                            Text("(\(count))")
                                .font(.caption2)
                                .foregroundStyle(C.textMuted)
                        }
                        if loadingID == item.id {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(C.watch)
                                .accessibilityHidden(true)
                        }
                    }
                    .foregroundStyle(isSelected(item) ? C.text : C.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .frame(maxWidth: fillsWidth ? .infinity : nil)
                    .padding(.horizontal, fillsWidth ? 0 : 16)
                    .padding(.vertical, verticalPadding)
                    .overlay(alignment: .bottom) {
                        if isSelected(item) {
                            Rectangle()
                                .fill(C.watch)
                                .frame(height: 2)
                        }
                    }
                }
                .frame(maxWidth: fillsWidth ? .infinity : nil)
                .buttonStyle(.plain)
                .disabled(loadingID == item.id)
                // Keep tab navigation individually discoverable and stable for
                // VoiceOver/UI automation. The underline and text weight remain
                // the visual selection cues; the selected trait exposes the same
                // state to assistive technologies without relying on colour.
                .accessibilityIdentifier("mediaverse-tab-\(item.id)")
                .accessibilityLabel(item.label)
                .accessibilityAddTraits(isSelected(item) ? .isSelected : [])
                .id(item.id)
            }

            if !fillsWidth {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .background(background)
        .overlay(alignment: .bottom) {
            Divider().background(C.border)
        }
    }

    private func isSelected(_ item: MediaverseTabItem) -> Bool {
        item.id == selectedID
    }
}
