import SwiftUI

/// Browse landing with in-place section tabs.
/// Each tab keeps the section-specific filters/search controls from its destination page.
struct BrowseView: View {

    @State private var selectedSection: BrowseSection = .shows
    @State private var searchPresented = false

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                sectionTabs

                TabView(selection: $selectedSection) {
                    ShowsBrowseView()
                        .tag(BrowseSection.shows)

                    MoviesBrowseView()
                        .tag(BrowseSection.movies)

                    MicrodramasBrowseView()
                        .tag(BrowseSection.microdramas)

                    ChannelsBrowseView()
                        .tag(BrowseSection.channels)

                    FollowingView()
                        .tag(BrowseSection.following)

                    CollectionsView()
                        .tag(BrowseSection.collections)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
        .navigationTitle("Browse")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Browse")
                    .font(.system(size: 17, weight: .bold))
                    .fontDesign(.rounded)
                    .foregroundStyle(C.text)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    searchPresented = true
                } label: {
                    MediaverseIcon(name: "search", fallbackSystemName: "magnifyingglass")
                        .frame(width: 16, height: 16)
                        .foregroundStyle(C.text)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $searchPresented) {
            SearchView()
        }
    }

    private var sectionTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(BrowseSection.allCases) { section in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedSection = section
                        }
                    } label: {
                        Label(section.title, systemImage: section.fallbackIcon)
                            .mediaverseLabelIcon(section.assetIcon, fallback: section.fallbackIcon)
                            .font(.system(size: 13, weight: selectedSection == section ? .bold : .semibold))
                            .foregroundStyle(selectedSection == section ? C.bg : C.textMuted)
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                            .background(selectedSection == section ? C.watch : C.elevated)
                            .clipShape(Capsule())
                            .overlay {
                                Capsule()
                                    .stroke(selectedSection == section ? C.watch.opacity(0.6) : C.border, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(section.title)
                }
            }
            .padding(.horizontal, C.pagePad)
            .padding(.vertical, 10)
        }
        .background(C.bg)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(C.borderSubtle)
                .frame(height: 0.5)
        }
    }
}

private enum BrowseSection: String, CaseIterable, Identifiable {
    case shows
    case movies
    case microdramas
    case channels
    case following
    case collections

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shows: return "Shows"
        case .movies: return "Movies"
        case .microdramas: return "Microdramas"
        case .channels: return "Channels"
        case .following: return "Following"
        case .collections: return "Collections"
        }
    }

    var assetIcon: String {
        switch self {
        case .shows: return "tv"
        case .movies: return "film"
        case .microdramas: return "phone"
        case .channels: return "users"
        case .following: return "notification"
        case .collections: return "library"
        }
    }

    var fallbackIcon: String {
        switch self {
        case .shows: return "tv"
        case .movies: return "film"
        case .microdramas: return "iphone"
        case .channels: return "rectangle.stack.person.crop"
        case .following: return "bell"
        case .collections: return "square.stack"
        }
    }
}
