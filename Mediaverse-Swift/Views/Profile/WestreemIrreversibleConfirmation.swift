import SwiftUI

struct WestreemIrreversibleProjection: Equatable, Sendable {
    let title: String
    let explanation: String
    let removes: [String]
    let keeps: [String]
    let confirmationLabel: String
    let cancelLabel: String
}

/// Design System 26-H. Present this content as a sheet; it applies the shared
/// WeStreem adaptive treatment and keeps destructive authority injected.
struct WestreemIrreversibleConfirmation: View {
    let value: WestreemIrreversibleProjection
    let busy: Bool
    let error: String?
    let onConfirm: @MainActor () -> Void
    let onCancel: @MainActor () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(value.title)
                    .font(WestreemTokens.Typography.heading)
                    .accessibilityAddTraits(.isHeader)

                Text(value.explanation)
                    .font(WestreemTokens.Typography.caption)
                    .foregroundStyle(WestreemTokens.Palette.textBody)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, WestreemTokens.Spacing.s)

                impactList(title: "THIS WILL REMOVE", values: value.removes, danger: true)
                    .padding(.top, 20)
                impactList(title: "THIS WILL STAY", values: value.keeps, danger: false)
                    .padding(.top, WestreemTokens.Spacing.m)

                if let error, !error.isEmpty {
                    Text(error)
                        .font(WestreemTokens.Typography.caption)
                        .foregroundStyle(WestreemTokens.Palette.pink)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(WestreemTokens.Spacing.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(WestreemTokens.Palette.pink.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: WestreemTokens.Radius.row))
                        .overlay(RoundedRectangle(cornerRadius: WestreemTokens.Radius.row).stroke(WestreemTokens.Palette.pink.opacity(0.35)))
                        .padding(.top, WestreemTokens.Spacing.l)
                        .accessibilityLabel("Error. \(error)")
                }

                VStack(spacing: WestreemTokens.Spacing.s) {
                    Button(value.cancelLabel) { onCancel() }
                        .buttonStyle(IrreversibleCancelButtonStyle())
                        .disabled(busy)

                    Button { onConfirm() } label: {
                        HStack(spacing: WestreemTokens.Spacing.s) {
                            if busy {
                                ProgressView()
                                    .tint(WestreemTokens.Palette.pinkOn)
                                    .accessibilityHidden(true)
                            }
                            Text(busy ? "Working…" : value.confirmationLabel)
                        }
                    }
                    .buttonStyle(IrreversibleDangerButtonStyle())
                    .disabled(busy)
                    .accessibilityValue(busy ? "In progress" : "")
                }
                .padding(.top, WestreemTokens.Spacing.xl)
            }
            .padding(WestreemTokens.Spacing.l)
        }
        .background(WestreemTokens.Palette.ink900)
        .foregroundStyle(WestreemTokens.Palette.text)
        .accessibilityIdentifier("westreem-irreversible-confirmation-26-h")
        .westreemAdaptiveSheet(detents: [.medium, .large], dismissible: !busy)
    }

    private func impactList(title: String, values: [String], danger: Bool) -> some View {
        VStack(alignment: .leading, spacing: WestreemTokens.Spacing.m) {
            Text(title)
                .font(.custom(WestreemTokens.FontFamily.monoMedium, size: 9, relativeTo: .caption2))
                .foregroundStyle(danger ? WestreemTokens.Palette.pink : WestreemTokens.Palette.green)
                .tracking(0.8)

            ForEach(values, id: \.self) { item in
                HStack(alignment: .top, spacing: WestreemTokens.Spacing.s) {
                    Text(danger ? "−" : "✓")
                        .foregroundStyle(danger ? WestreemTokens.Palette.pink : WestreemTokens.Palette.green)
                        .accessibilityHidden(true)
                    Text(item)
                        .font(WestreemTokens.Typography.caption)
                        .foregroundStyle(WestreemTokens.Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(WestreemTokens.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WestreemTokens.Palette.ink800)
        .clipShape(RoundedRectangle(cornerRadius: WestreemTokens.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: WestreemTokens.Radius.card).stroke(WestreemTokens.Palette.lineEdge))
        .accessibilityElement(children: .combine)
    }
}

private struct IrreversibleCancelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(WestreemTokens.Typography.bodyEmphasized)
            .foregroundStyle(WestreemTokens.Palette.text)
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, WestreemTokens.Spacing.l)
            .background(LinearGradient(
                colors: [WestreemTokens.Palette.ink700, WestreemTokens.Palette.surfaceRaisedEnd],
                startPoint: .top,
                endPoint: .bottom
            ), in: Capsule())
            .overlay(Capsule().stroke(WestreemTokens.Palette.lineHard))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(WestreemTokens.Easing.fast, value: configuration.isPressed)
    }
}

private struct IrreversibleDangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom(WestreemTokens.FontFamily.bodyBold, size: 13, relativeTo: .body))
            .foregroundStyle(WestreemTokens.Palette.pinkOn)
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, WestreemTokens.Spacing.l)
            .background(WestreemTokens.Palette.pink, in: Capsule())
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(WestreemTokens.Easing.fast, value: configuration.isPressed)
    }
}
