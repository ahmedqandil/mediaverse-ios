import SwiftUI

/// Browse landing — sections for TV Shows, Movies, Microdramas, Following, Collections.
/// Each section leads to a dedicated sub-view.
struct BrowseView: View {

    @State private var searchPresented = false

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    // ── TV Shows ──────────────────────────────────────────
                    BrowseSectionRow(
                        icon: "tv",
                        title: "TV Shows",
                        subtitle: "Series, anime, reality",
                        tintColor: C.watch
                    ) {
                        ShowsBrowseView()
                    }

                    Divider().background(C.border).padding(.horizontal, C.pagePad)

                    // ── Movies ────────────────────────────────────────────
                    BrowseSectionRow(
                        icon: "film",
                        title: "Movies",
                        subtitle: "Films, documentaries, specials",
                        tintColor: Color(hex: "#F59E0B")
                    ) {
                        MoviesBrowseView()
                    }

                    Divider().background(C.border).padding(.horizontal, C.pagePad)

                    // ── Microdramas ───────────────────────────────────────
                    BrowseSectionRow(
                        icon: "iphone",
                        title: "Microdramas",
                        subtitle: "Short vertical series",
                        tintColor: Color(hex: "#8B5CF6")
                    ) {
                        MicrodramasBrowseView()
                    }

                    Divider().background(C.border).padding(.horizontal, C.pagePad)

                    // ── Channels ──────────────────────────────────────────
                    BrowseSectionRow(
                        icon: "rectangle.stack.person.crop",
                        title: "Channels",
                        subtitle: "Creators and networks",
                        tintColor: Color(hex: "#38BDF8")
                    ) {
                        ChannelsBrowseView()
                    }

                    Divider().background(C.border).padding(.horizontal, C.pagePad)

                    // ── Following ─────────────────────────────────────────
                    BrowseSectionRow(
                        icon: "bell",
                        title: "Following",
                        subtitle: "Videos from channels you follow",
                        tintColor: Color(hex: "#10B981")
                    ) {
                        FollowingView()
                    }

                    Divider().background(C.border).padding(.horizontal, C.pagePad)

                    // ── Collections ───────────────────────────────────────
                    BrowseSectionRow(
                        icon: "square.stack",
                        title: "Collections",
                        subtitle: "Your curated lists",
                        tintColor: Color(hex: "#EC4899")
                    ) {
                        CollectionsView()
                    }
                }
                .padding(.top, 8)
            }
        }
        .navigationTitle("Browse")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    searchPresented = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(C.text)
                }
            }
        }
        .sheet(isPresented: $searchPresented) {
            SearchView()
        }
    }
}

// MARK: - Row component

private struct BrowseSectionRow<Destination: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    let tintColor: Color
    @ViewBuilder var destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(tintColor)
                    .frame(width: 44, height: 44)
                    .background(tintColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(C.text)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(C.textMuted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(C.textMuted)
            }
            .padding(.horizontal, C.pagePad)
            .padding(.vertical, 14)
        }
    }
}
