import SwiftUI

/// Context switcher sheet — lists admin/network/channel/user contexts.
/// Mirrors the UserContextMenu component in TopBar.tsx
struct ContextSwitcherView: View {

    @Binding var contexts: [ActiveContext]
    @Binding var active: ActiveContext?
    let onSwitch: (ActiveContext) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                C.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 0) {
                        // Active context header
                        if let currentActive = active {
                            activeHeader(currentActive)
                        }

                        Divider().background(C.border)

                        // Context list
                        LazyVStack(spacing: 0) {
                            ForEach(contexts) { ctx in
                                ContextRow(
                                    ctx: ctx,
                                    isActive: ctx.id == active?.id && ctx.type == active?.type
                                ) {
                                    Task { await switchTo(ctx) }
                                }
                                Divider().background(C.border)
                                    .padding(.leading, C.pagePad + 40)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Switch Context")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(C.watch)
                }
            }
        }
    }

    // MARK: - Active context header

    private func activeHeader(_ ctx: ActiveContext) -> some View {
        HStack(spacing: 12) {
            contextIcon(ctx.type)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text("Active context")
                    .font(.caption)
                    .foregroundStyle(C.textMuted)
                Text(ctx.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(C.text)
                Text(ctx.type.capitalized)
                    .font(.caption2)
                    .foregroundStyle(C.textMuted)
            }
            Spacer()
        }
        .padding(.horizontal, C.pagePad)
        .padding(.vertical, 16)
    }

    // MARK: - Icon

    @ViewBuilder
    private func contextIcon(_ type: String) -> some View {
        let (iconName, color): (String, Color) = {
            switch type {
            case "admin":   return ("shield.fill",       Color(hex: "#EF4444"))
            case "network": return ("building.2.fill",   Color(hex: "#F59E0B"))
            case "channel": return ("play.rectangle.fill", C.watch)
            default:        return ("person.fill",        Color(hex: "#10B981"))
            }
        }()
        Image(systemName: iconName)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 40, height: 40)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Switch

    private func switchTo(_ ctx: ActiveContext) async {
        do {
            let resp = try await APIClient.shared.switchContext(ctx)
            if let newCtx = resp.context ?? (resp.ok ? ctx : nil) {
                active = newCtx
                onSwitch(newCtx)
                dismiss()
            }
        } catch {}
    }
}

// MARK: - Context row

private struct ContextRow: View {
    let ctx: ActiveContext
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                contextIcon(ctx.type)

                VStack(alignment: .leading, spacing: 2) {
                    Text(ctx.name)
                        .font(.subheadline.weight(isActive ? .semibold : .regular))
                        .foregroundStyle(C.text)
                    Text(typeLabel(ctx.type))
                        .font(.caption2)
                        .foregroundStyle(C.textMuted)
                }

                Spacer()

                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(C.watch)
                }
            }
            .padding(.horizontal, C.pagePad)
            .padding(.vertical, 14)
        }
    }

    @ViewBuilder
    private func contextIcon(_ type: String) -> some View {
        let (iconName, color): (String, Color) = {
            switch type {
            case "admin":   return ("shield.fill",         Color(hex: "#EF4444"))
            case "network": return ("building.2.fill",     Color(hex: "#F59E0B"))
            case "channel": return ("play.rectangle.fill", Color(hex: "#0EA5E9"))
            default:        return ("person.fill",          Color(hex: "#10B981"))
            }
        }()
        Image(systemName: iconName)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 36, height: 36)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func typeLabel(_ type: String) -> String {
        switch type {
        case "admin":   return "System Admin"
        case "network": return "Network"
        case "channel": return "Channel"
        default:        return "Viewer"
        }
    }
}
