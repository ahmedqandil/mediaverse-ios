import SwiftUI

struct AtmosphereView: View {
    @StateObject private var model = AtmosphereViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            MediaverseUnderlineTabStrip(
                items: AtmosphereViewModel.Tab.allCases.map {
                    MediaverseTabItem(id: $0.id, label: $0.title)
                },
                selectedID: model.selectedTab.id,
                fillsWidth: true,
                horizontalPadding: 0
            ) { id in
                guard let tab = AtmosphereViewModel.Tab(rawValue: id) else { return }
                model.select(tab)
            }
            content
        }
        .background(C.bg.ignoresSafeArea())
        .task { await model.loadIfNeeded() }
    }

    private var header: some View {
        HStack {
            Text("The Atmosphere")
                .font(.title2.bold())
                .foregroundStyle(C.text)
            Spacer()
        }
        .padding(.horizontal, C.pagePad)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(C.bg)
    }

    @ViewBuilder
    private var content: some View {
        switch model.stateByTab[model.selectedTab] ?? .idle {
        case .idle, .loading:
            loading
        case .failed(let message):
            unavailable(message)
        case .loaded:
            loadedTab
        }
    }

    private var loading: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: C.cardRadius)
                        .fill(C.surface)
                        .frame(height: 180)
                }
            }
            .padding(C.pagePad)
        }
        .accessibilityLabel("Loading \(model.selectedTab.title)")
    }

    private func unavailable(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn’t load \(model.selectedTab.title)", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") {
                Task { await model.reload() }
            }
            .buttonStyle(.borderedProminent)
            .tint(C.watch)
        }
        .foregroundStyle(C.text)
    }

    @ViewBuilder
    private var loadedTab: some View {
        switch model.selectedTab {
        case .atmosphere:
            simpleFeed(model.atmosphereItems)
        case .discover:
            simpleRipples(model.discoveredRipples)
        case .myVibes:
            simpleVibes(model.myVibes)
        }
    }

    private func simpleFeed(_ items: [AtmosphereFeedItem]) -> some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    switch item {
                    case .ripple(let ripple):
                        RippleCard(ripple: ripple)
                    case .video(let video):
                        AtmosphereVideoPlaceholder(video: video)
                    case .excludedEpisode, .excludedShort, .unsupported:
                        EmptyView()
                    }
                }
            }
            .padding(C.pagePad)
            .padding(.bottom, C.bottomMenuClearance)
        }
        .refreshable { await model.reload(.atmosphere) }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView(
                    "Your Atmosphere is quiet",
                    systemImage: "wind",
                    description: Text("Follow people and Vibes to see their Ripples here.")
                )
            }
        }
    }

    private func simpleRipples(_ ripples: [Ripple]) -> some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(ripples) { RippleCard(ripple: $0) }
            }
            .padding(C.pagePad)
            .padding(.bottom, C.bottomMenuClearance)
        }
        .refreshable { await model.reload(.discover) }
    }

    private func simpleVibes(_ vibes: [VibeSummary]) -> some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(vibes) { vibe in
                    HStack(spacing: 12) {
                        Circle()
                            .fill(C.elevated)
                            .frame(width: 48, height: 48)
                            .overlay(Text(String(vibe.name.prefix(1))).font(.headline))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(vibe.name).font(.headline)
                            Text("\(vibe.followerCount) followers")
                                .font(.caption)
                                .foregroundStyle(C.textMuted)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(C.surface, in: RoundedRectangle(cornerRadius: C.cardRadius))
                }
            }
            .padding(C.pagePad)
            .padding(.bottom, C.bottomMenuClearance)
        }
        .refreshable { await model.reload(.myVibes) }
    }
}

private struct AtmosphereVideoPlaceholder: View {
    let video: AtmosphereVideo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 10)
                .fill(C.elevated)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(Image(systemName: "play.fill").foregroundStyle(C.watch))
            Text(video.title).font(.headline)
            if video.views > 0 {
                Text("\(video.views) views").font(.caption).foregroundStyle(C.textMuted)
            }
        }
        .padding(12)
        .background(C.surface, in: RoundedRectangle(cornerRadius: C.cardRadius))
    }
}
