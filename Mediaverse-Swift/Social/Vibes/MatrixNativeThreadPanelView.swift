import SwiftUI

/// Sheet listing every thread with at least one reply inside a Wave.
///
/// Element X iOS presents this as a "Threads" list at the top-right of every
/// room view (parity with `ThreadPanel.tsx` on web). Tapping a row emits the
/// selected `rootEventID` back to the presenter so the existing
/// `MatrixNativeThreadView` sheet on `MatrixNativeWaveRoomView` opens with
/// the correct root. The parent already owns the timeline items we need to
/// resolve the root — see `openRoot(_:)`.
///
/// Uses `matrixSession.threadSummaries(roomID:)` for the source of truth,
/// which is currently a client-side derivation over the live timeline. When
/// the Rust SDK exposes `Room.threads()` the presenter can swap without any
/// UI changes.
struct MatrixNativeThreadPanelView: View {
    private enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case mine = "My"
        var id: Self { self }
    }

    let roomID: String
    let openRoot: (_ rootEventID: String) -> Void

    @EnvironmentObject private var matrixSession: MatrixNativeSessionController
    @Environment(\.dismiss) private var dismiss
    @State private var summaries: [MatrixNativeThreadSummary] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var filter: Filter = .all

    private var visibleSummaries: [MatrixNativeThreadSummary] {
        filter == .all ? summaries : summaries.filter(\.isParticipated)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Thread filter", selection: $filter) {
                    ForEach(Filter.allCases) { value in
                        Text(value.rawValue).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, WestreemTokens.Spacing.l)
                .padding(.vertical, WestreemTokens.Spacing.s)
                content
            }
                .background(C.bg.ignoresSafeArea())
                .navigationTitle("Threads")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task { await load() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(isLoading)
                        .accessibilityLabel("Refresh threads")
                    }
                }
        }
        .preferredColorScheme(.dark)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading, summaries.isEmpty {
            ProgressView("Loading threads…")
                .tint(C.watch)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage, summaries.isEmpty {
            VStack(spacing: WestreemTokens.Spacing.m) {
                Image(systemName: "exclamationmark.bubble")
                    .font(.system(size: 30))
                    .foregroundStyle(C.textMuted)
                Text(errorMessage)
                    .font(WestreemTokens.Typography.body)
                    .foregroundStyle(C.textMuted)
                    .multilineTextAlignment(.center)
                Button("Try again") { Task { await load() } }
                    .buttonStyle(.borderedProminent)
                    .tint(C.watch)
            }
            .padding(WestreemTokens.Spacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleSummaries.isEmpty {
            emptyState
        } else {
            list
        }
    }

    private var emptyState: some View {
        VStack(spacing: WestreemTokens.Spacing.m) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 36))
                .foregroundStyle(C.textMuted)
            Text(filter == .mine ? "No threads you joined" : "No threads yet")
                .font(WestreemTokens.Typography.heading)
                .foregroundStyle(C.text)
            Text(
                filter == .mine
                    ? "Threads you start or reply to appear here."
                    : "Long-press a Ripple and choose Reply in thread to start one."
            )
                .font(WestreemTokens.Typography.caption)
                .foregroundStyle(C.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, WestreemTokens.Spacing.l)
        }
        .padding(WestreemTokens.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List {
            ForEach(visibleSummaries) { summary in
                Button {
                    openRoot(summary.rootEventID)
                    dismiss()
                } label: {
                    row(summary)
                }
                .listRowBackground(C.surface)
                .listRowSeparatorTint(C.borderSubtle)
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "Thread by \(summary.rootSenderName). \(summary.replyCount) replies."
                )
                .accessibilityHint("Opens this discussion.")
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .refreshable { await load() }
    }

    private func row(_ summary: MatrixNativeThreadSummary) -> some View {
        VStack(alignment: .leading, spacing: WestreemTokens.Spacing.xs) {
            HStack(spacing: WestreemTokens.Spacing.s) {
                Text(summary.rootSenderName)
                    .font(WestreemTokens.Typography.bodyEmphasized)
                    .foregroundStyle(C.text)
                if summary.hasUnread {
                    Circle()
                        .fill(C.watch)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel("Unread")
                }
                Spacer(minLength: 0)
                Text(summary.lastReplyAt.formatted(.relative(presentation: .named)))
                    .font(WestreemTokens.Typography.small)
                    .foregroundStyle(C.textMuted)
            }
            Text(summary.rootBody)
                .font(WestreemTokens.Typography.body)
                .foregroundStyle(C.text)
                .lineLimit(2)
            if let lastReplyBody = summary.lastReplyBody,
               let sender = summary.lastReplySenderName {
                HStack(alignment: .top, spacing: WestreemTokens.Spacing.xs) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(WestreemTokens.Typography.small)
                        .foregroundStyle(C.textMuted)
                    Text("\(sender): \(lastReplyBody)")
                        .font(WestreemTokens.Typography.caption)
                        .foregroundStyle(C.textMuted)
                        .lineLimit(1)
                }
            }
            HStack(spacing: WestreemTokens.Spacing.s) {
                Label(
                    "\(summary.replyCount) \(summary.replyCount == 1 ? "reply" : "replies")",
                    systemImage: "bubble.left.and.bubble.right"
                )
                .font(WestreemTokens.Typography.small)
                .foregroundStyle(C.watch)
                if !summary.participants.isEmpty {
                    Text("· \(summary.participants.prefix(3).joined(separator: ", "))")
                        .font(WestreemTokens.Typography.small)
                        .foregroundStyle(C.textMuted)
                        .lineLimit(1)
                }
            }
            .padding(.top, WestreemTokens.Spacing.xs)
        }
        .padding(.vertical, WestreemTokens.Spacing.xs)
    }

    @MainActor
    private func load() async {
        if summaries.isEmpty { isLoading = true }
        defer { isLoading = false }
        do {
            summaries = try await matrixSession.threadSummaries(roomID: roomID)
            errorMessage = nil
        } catch {
            errorMessage = "Threads could not be loaded."
        }
    }
}

// MARK: - Offline banner
//
// Amber banner shown at the top of Vibes-family surfaces when
// `NWPathMonitor` reports the device is offline. This is separate from
// `MatrixNativeConnectionBanner` because sync-state recovery can lag the
// actual transport by several seconds, and Compound design uses distinct
// visuals for "no network" vs "recovering sync".
struct MatrixNativeOfflineBanner: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    let isVisible: Bool

    var body: some View {
        Group {
            if isVisible {
                HStack(spacing: WestreemTokens.Spacing.s) {
                    Image(systemName: "wifi.slash")
                        .font(WestreemTokens.Typography.bodyEmphasized)
                    Text("You're offline. Vibes will catch up when you reconnect.")
                        .font(WestreemTokens.Typography.caption)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Color.black)
                .padding(.horizontal, WestreemTokens.Spacing.l)
                .padding(.vertical, WestreemTokens.Spacing.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(C.offlineBanner)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isStaticText)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(
            accessibilityReduceMotion ? nil : WestreemTokens.Easing.standard,
            value: isVisible
        )
    }
}
