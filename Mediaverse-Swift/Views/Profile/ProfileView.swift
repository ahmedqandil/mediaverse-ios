import PhotosUI
import SwiftUI
import UIKit

/// User profile — avatar, name, stats, settings rows, context switcher, sign out.
struct ProfileView: View {

    @EnvironmentObject private var auth: AuthManager

    @State private var profile: FullProfile?
    @State private var contexts       = [ActiveContext]()
    @State private var activeCtx: ActiveContext?
    @State private var contextUser: ContextUser?
    @State private var isLoading      = true
    @State private var showCtxSwitcher = false
    @State private var showHistory    = false
    @State private var showCollections = false
    @State private var showEditProfile = false
    @State private var showChannelSettings = false
    @State private var showPairedDevices = false
    @State private var showPartnerRequest = false
    @State private var subscriptions = [UserSubscription]()
    @State private var rentals = [UserRental]()
    @State private var cancellingSubscriptionId: String?
    @State private var notificationCounts = [String: Int]()

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()
            if !auth.isAuthenticated {
                unauthState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 20) {
                            Color.clear
                                .frame(height: 0)
                                .id("profile-top")
                            profileHero
                            quickActions
                            accountSection
                            signOutButton
                        }
                        .padding(.horizontal, C.pagePad)
                        .padding(.top, 8)
                        .padding(.bottom, 32)
                    }
                    .refreshable {
                        C.lightHaptic()
                        await loadAll()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .mainTabScrollToTopRequested)) { notification in
                        guard (notification.object as? String) == "profile" else { return }
                        withAnimation(.easeOut(duration: 0.24)) {
                            proxy.scrollTo("profile-top", anchor: .top)
                        }
                    }
                }
            }
        }
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showCtxSwitcher) {
            ContextSwitcherView(
                contexts: $contexts,
                active: $activeCtx,
                user: contextUser,
                notificationCounts: notificationCounts
            ) { _ in }
        }
        .sheet(isPresented: $showEditProfile) {
            EditProfileSheet(profile: profile) { updated in
                profile = updated
            }
        }
        .sheet(isPresented: $showPartnerRequest) {
            PartnerRequestSheet {
                Task { await loadAll() }
            }
        }
        .navigationDestination(isPresented: $showHistory) {
            WatchHistoryView()
        }
        .navigationDestination(isPresented: $showCollections) {
            CollectionsView()
        }
        .navigationDestination(isPresented: $showChannelSettings) {
            if let channelId = activeChannelId {
                ChannelSettingsView(channelId: channelId) {
                    Task { await loadAll() }
                }
            }
        }
        .navigationDestination(isPresented: $showPairedDevices) {
            PairedDevicesView()
        }
        .task {
            guard auth.isAuthenticated else { isLoading = false; return }
            await loadAll()
        }
        .onAppear {
            // Refresh billing whenever the tab reappears (e.g. returning from watching)
            // so rental status/countdown reflects a just-started playback. .task only
            // fires once for the tab's lifetime, so it can't catch this on its own.
            guard auth.isAuthenticated, !isLoading else { return }
            Task { await loadBilling() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .appContextDidChange)) { _ in
            guard auth.isAuthenticated else { return }
            Task { await loadAll() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .notificationCountsDidChange)) { _ in
            guard auth.isAuthenticated else { return }
            Task { await loadNotificationCounts() }
        }
    }

    // MARK: - Profile header

    private var activeChannelId: String? {
        if activeCtx?.type == "channel", let channelId = activeCtx?.channelId {
            return channelId
        }
        return profile?.channel?.id
    }

    private var activeChannelName: String? {
        if activeCtx?.type == "channel", let name = activeCtx?.name, !name.isEmpty {
            return name
        }
        return profile?.channel?.name
    }

    private var activeChannelSubtitle: String {
        if let name = activeChannelName, !name.isEmpty {
            return "Update \(name)"
        }
        return "Settings and images"
    }

    private var canRequestPartner: Bool {
        profile?.role?.lowercased() == "viewer"
    }

    private var profileHero: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                CachedRemoteImage(
                    url: C.mediaURL(profile?.bannerUrl ?? profile?.channel?.bannerUrl),
                    targetSize: CGSize(width: 700, height: 180)
                ) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    LinearGradient(
                        colors: [C.watch.opacity(0.34), Color.white.opacity(0.08), C.surface],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
                .frame(height: 138)
                .clipped()
                .overlay {
                    LinearGradient(
                        colors: [.black.opacity(0.06), .black.opacity(0.68)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }

                HStack(alignment: .bottom, spacing: 14) {
                    profileAvatar
                        .offset(y: 28)

                    Spacer()

                    Button {
                        showEditProfile = true
                    } label: {
                        HStack(spacing: 6) {
                            MediaverseIcon(name: "edit", fallbackSystemName: "pencil")
                                .frame(width: 13, height: 13)
                            Text("Edit")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(C.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.38))
                        .clipShape(Capsule())
                        .overlay { Capsule().stroke(.white.opacity(0.14), lineWidth: 1) }
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 12)
                }
                .padding(.horizontal, 16)
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile?.name ?? (isLoading ? "Loading..." : auth.currentUser?.name ?? "Profile"))
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(C.text)
                            .lineLimit(1)

                        if let handle = profile?.handle, !handle.isEmpty {
                            Text("@\(handle)")
                                .font(.subheadline)
                                .foregroundStyle(C.textMuted)
                        } else if let email = profile?.email ?? auth.currentUser?.email {
                            Text(email)
                                .font(.subheadline)
                                .foregroundStyle(C.textMuted)
                        }
                    }

                    Spacer()
                    contextChip
                }

                if let bio = profile?.bio, !bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(bio)
                        .font(.subheadline)
                        .foregroundStyle(C.text.opacity(0.74))
                        .lineSpacing(2)
                        .lineLimit(4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 36)
            .padding(.bottom, 16)
        }
        .background(C.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(C.border, lineWidth: 1) }
    }

    private var profileAvatar: some View {
        CachedRemoteImage(
            url: C.mediaURL(profile?.image),
            targetSize: CGSize(width: 92, height: 92)
        ) { img in
            img.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                Circle().fill(C.surfaceAlt)
                MediaverseIcon(name: "user", fallbackSystemName: "person")
                    .frame(width: 34, height: 34)
                    .foregroundStyle(C.textMuted)
            }
        }
        .frame(width: 92, height: 92)
        .clipShape(Circle())
        .overlay { Circle().stroke(C.bg, lineWidth: 5) }
        .overlay { Circle().stroke(C.border, lineWidth: 1) }
    }

    @ViewBuilder
    private var contextChip: some View {
        if let ctx = activeCtx {
            Button {
                if contexts.count > 1 {
                    showCtxSwitcher = true
                }
            } label: {
                HStack(spacing: 6) {
                    MediaverseIcon(name: contextIconName(ctx.type), fallbackSystemName: ctxIcon(ctx.type))
                        .frame(width: 12, height: 12)
                    Text(ctx.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if contexts.count > 1 {
                        MediaverseIcon(name: "chevron-down", fallbackSystemName: "chevron.down")
                            .frame(width: 8, height: 8)
                    }
                }
                .foregroundStyle(C.watch)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(C.watch.opacity(0.12))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Mobile web sections

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Me")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                quickActionTile(iconName: "history", fallbackSystemName: "clock", title: "History", subtitle: "Resume watching") {
                    showHistory = true
                }
                quickActionTile(iconName: "collection", fallbackSystemName: "square.grid.2x2", title: "Collections", subtitle: "Saved clips and shows") {
                    showCollections = true
                }
                if activeChannelId != nil {
                    quickActionTile(iconName: "play", fallbackSystemName: "play.rectangle", title: "Channel", subtitle: activeChannelSubtitle) {
                        showChannelSettings = true
                    }
                }
            }
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Account")
            VStack(spacing: 0) {
                if contexts.count > 1 {
                    accountRow(iconName: "switch", fallbackSystemName: "arrow.triangle.2.circlepath", title: "Switch Context", subtitle: activeCtx?.name) {
                        showCtxSwitcher = true
                    }
                    rowDivider
                }
                accountRow(iconName: "user", fallbackSystemName: "person.crop.circle", title: "Edit Profile", subtitle: "Name and bio") {
                    showEditProfile = true
                }
                rowDivider
                accountRow(iconName: "devices", fallbackSystemName: "tv.and.mediabox", title: "Paired Devices", subtitle: "TVs and living-room apps") {
                    showPairedDevices = true
                }
                rowDivider
                if canRequestPartner {
                    accountRow(iconName: "network", fallbackSystemName: "person.badge.plus", title: "Become a Partner", subtitle: "Apply for creator access") {
                        openPartnerRequest()
                    }
                    rowDivider
                }
                billingHeaderRow
                billingRows
            }
            .background(C.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(C.border, lineWidth: 1) }
        }
    }

    private var billingHeaderRow: some View {
        HStack(spacing: 12) {
            MediaverseIcon(name: "wallet", fallbackSystemName: "creditcard")
                .frame(width: 18, height: 18)
                .foregroundStyle(C.watch)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Billing")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(C.text)
                Text(billingSummaryText)
                    .font(.caption)
                    .foregroundStyle(C.textMuted)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var billingRows: some View {
        if subscriptions.isEmpty && rentals.isEmpty {
            rowDivider
            emptyBillingRow
        } else {
            ForEach(subscriptions) { subscription in
                rowDivider
                subscriptionRow(subscription)
            }
            ForEach(rentals) { rental in
                rowDivider
                rentalRow(rental)
            }
        }
    }

    private var billingSummaryText: String {
        let subscriptionCount = subscriptions.count
        let rentalCount = rentals.count
        switch (subscriptionCount, rentalCount) {
        case (0, 0):
            return "Subscriptions and rentals"
        case (0, 1):
            return "1 rental"
        case (0, _):
            return "\(rentalCount) rentals"
        case (1, 0):
            return "1 subscription"
        case (_, 0):
            return "\(subscriptionCount) subscriptions"
        case (1, 1):
            return "1 subscription · 1 rental"
        case (1, _):
            return "1 subscription · \(rentalCount) rentals"
        case (_, 1):
            return "\(subscriptionCount) subscriptions · 1 rental"
        default:
            return "\(subscriptionCount) subscriptions · \(rentalCount) rentals"
        }
    }

    private var emptyBillingRow: some View {
        HStack(spacing: 12) {
            MediaverseIcon(name: "lock", fallbackSystemName: "lock")
                .frame(width: 18, height: 18)
                .foregroundStyle(C.textMuted)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text("No active billing items")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(C.text)
                Text("Subscriptions and rentals will appear here.")
                    .font(.caption)
                    .foregroundStyle(C.textMuted)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
    }

    private func subscriptionRow(_ subscription: UserSubscription) -> some View {
        HStack(spacing: 12) {
            billingIcon("checkmark.seal", color: C.watch)

            VStack(alignment: .leading, spacing: 3) {
                Text(subscription.product?.name ?? subscription.network?.name ?? "Subscription")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(C.text)
                    .lineLimit(1)
                Text(subscriptionSubtitle(subscription))
                    .font(.caption)
                    .foregroundStyle(C.textMuted)
                    .lineLimit(2)
            }

            Spacer()

            if subscription.cancelAtPeriodEnd == true || subscription.cancelledAt != nil {
                Text("Cancels")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(C.textTertiary)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(Color.white.opacity(0.07), in: Capsule())
            } else {
                Button {
                    Task { await cancel(subscription) }
                } label: {
                    if cancellingSubscriptionId == subscription.id {
                        ProgressView()
                            .scaleEffect(0.72)
                            .tint(C.text)
                            .frame(width: 58, height: 28)
                    } else {
                        Text("Cancel")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(C.text)
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                    }
                }
                .background(Color.white.opacity(0.08), in: Capsule())
                .disabled(cancellingSubscriptionId != nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func rentalRow(_ rental: UserRental) -> some View {
        // Tapping opens the show/movie page (the season-scoped rental's content).
        if let showId = rental.resolvedShowId, !showId.isEmpty {
            NavigationLink(value: AppRoute.show(showId)) {
                rentalRowContent(rental)
            }
            .buttonStyle(.plain)
        } else {
            rentalRowContent(rental)
        }
    }

    private func rentalRowContent(_ rental: UserRental) -> some View {
        HStack(alignment: .top, spacing: 12) {
            billingThumbnail(url: rentalThumbnailURL(rental), fallback: "ticket", color: Color(hex: "#F59E0B"))

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(rentalTitle(rental))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(C.text)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Text(rentalStatusLabel(rental))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(rentalStatusColor(rental))
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(rentalStatusColor(rental).opacity(0.12), in: Capsule())
                }

                if let context = rentalContextText(rental) {
                    Text(context)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(C.text.opacity(0.72))
                        .lineLimit(1)
                }

                VStack(alignment: .leading, spacing: 3) {
                    ForEach(rentalDetailLines(rental), id: \.self) { line in
                        Text(line)
                            .font(.caption2)
                            .foregroundStyle(C.textMuted)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
    }

    private func billingIcon(_ fallback: String, color: Color) -> some View {
        Image(systemName: fallback)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 36, height: 36)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private func billingThumbnail(url: String?, fallback: String, color: Color) -> some View {
        ZStack {
            if let url, let mediaURL = C.mediaURL(url) {
                CachedRemoteImage(
                    url: mediaURL,
                    targetSize: CGSize(width: 46, height: 62)
                ) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    color.opacity(0.12)
                }
            } else {
                color.opacity(0.12)
                Image(systemName: fallback)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(color)
            }
        }
        .frame(width: 46, height: 62)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(C.border, lineWidth: 1) }
    }

    private func subscriptionSubtitle(_ subscription: UserSubscription) -> String {
        var parts = [String]()
        if let networkName = subscription.network?.name, !networkName.isEmpty {
            parts.append(networkName)
        }
        parts.append(subscription.status.capitalized)
        if let end = subscription.currentPeriodEnd {
            parts.append("Renews \(shortDate(end))")
        }
        return parts.joined(separator: " · ")
    }

    private func rentalTitle(_ rental: UserRental) -> String {
        // The show/movie name leads — a movie's episode is generically titled
        // "Feature", so episode.title must never win over the show title.
        rental.resolvedShow?.title
        ?? rental.season?.title
        ?? rental.episode?.title
        ?? rental.product?.name
        ?? "Rental"
    }

    private func rentalContextText(_ rental: UserRental) -> String? {
        // Under the show/movie title, name the specific episode (so two rentals from
        // the same series stay distinguishable), else the product/network.
        if let epTitle = rental.episode?.title, epTitle != rentalTitle(rental) {
            if let sn = rental.episode?.season?.seasonNumber, let en = rental.episode?.episodeNumber {
                return "S\(sn) E\(en) · \(epTitle)"
            }
            return epTitle
        }
        if let seasonTitle = rental.season?.title, seasonTitle != rentalTitle(rental) {
            return seasonTitle
        }
        if let product = rental.product?.name, product != rentalTitle(rental) {
            return product
        }
        return nil
    }

    private func rentalThumbnailURL(_ rental: UserRental) -> String? {
        rental.episode?.thumbnailUrl
        ?? rental.season?.coverUrl
        ?? rental.resolvedShow?.coverUrl
        ?? rental.product?.coverUrl
    }

    private func rentalDetailLines(_ rental: UserRental) -> [String] {
        var lines = [String]()
        if let validTo = rental.validTo {
            lines.append("Rental expires \(shortDate(validTo))")
        }
        if let playbackExpiresAt = rental.playbackExpiresAt {
            lines.append("Playback window ends \(shortDate(playbackExpiresAt))")
        } else if let window = rental.terms?.playbackWindowSecs {
            lines.append("Playback window: \(durationDaysText(window)) after first play")
        }
        if let maxPlays = rental.terms?.maxPlays {
            let used = rental.playsUsed ?? 0
            lines.append("\(max(0, maxPlays - used)) of \(maxPlays) plays left")
        }
        if let firstPlayedAt = rental.firstPlayedAt {
            lines.append("First played \(shortDate(firstPlayedAt))")
        }
        return lines.isEmpty ? ["Rental details will update after playback starts."] : lines
    }

    private func rentalStatusLabel(_ rental: UserRental) -> String {
        let rawStatus = (rental.status ?? "active").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if rawStatus == "expired" || isPast(rental.playbackExpiresAt) || isPast(rental.validTo) {
            return "Expired"
        }
        if rawStatus == "cancelled" || rawStatus == "canceled" {
            return "Canceled"
        }
        if rental.playbackExpiresAt != nil {
            return "Playback window"
        }
        if rental.firstPlayedAt == nil {
            return "Not started"
        }
        return "Active"
    }

    private func rentalStatusColor(_ rental: UserRental) -> Color {
        switch rentalStatusLabel(rental) {
        case "Active", "Playback window": return C.watch
        case "Not started": return Color(hex: "#F59E0B")
        default: return C.textTertiary
        }
    }

    private func isPast(_ value: String?) -> Bool {
        guard let date = parsedDate(value) else { return false }
        return date < Date()
    }

    private func durationDaysText(_ seconds: Int) -> String {
        let days = max(1, Int(ceil(Double(seconds) / 86_400.0)))
        return days == 1 ? "1 day" : "\(days) days"
    }

    private func shortDate(_ value: String) -> String {
        if let date = parsedDate(value) {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
        return value
    }

    private func parsedDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let isoFormatter = ISO8601DateFormatter()
        if let date = isoFormatter.date(from: value) { return date }
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return isoFormatter.date(from: value)
    }

    @MainActor
    private func cancel(_ subscription: UserSubscription) async {
        guard cancellingSubscriptionId == nil else { return }
        cancellingSubscriptionId = subscription.id
        defer { cancellingSubscriptionId = nil }
        do {
            try await APIClient.shared.cancelSubscription(id: subscription.id)
            await loadBilling()
        } catch {
            // Keep the existing subscription visible; the next refresh will reconcile state.
        }
    }

    private func quickActionTile(iconName: String, fallbackSystemName: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                MediaverseIcon(name: iconName, fallbackSystemName: fallbackSystemName)
                    .frame(width: 22, height: 22)
                    .foregroundStyle(C.watch)
                    .frame(width: 42, height: 42)
                    .background(C.watch.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(C.text)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(C.textMuted)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(C.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(C.border, lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }

    private func pillAction(iconName: String, fallbackSystemName: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                MediaverseIcon(name: iconName, fallbackSystemName: fallbackSystemName)
                    .frame(width: 16, height: 16)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(C.watch)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func openPartnerRequest() {
        showPartnerRequest = true
    }

    private func accountRow(iconName: String, fallbackSystemName: String, title: String, subtitle: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                MediaverseIcon(name: iconName, fallbackSystemName: fallbackSystemName)
                    .frame(width: 18, height: 18)
                    .foregroundStyle(C.watch)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(C.text)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(C.textMuted)
                    }
                }
                Spacer()
                MediaverseIcon(name: "chevron-right", fallbackSystemName: "chevron.right")
                    .frame(width: 11, height: 11)
                    .foregroundStyle(C.textMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }

    private var signOutButton: some View {
        Button {
            Task { await auth.signOut() }
        } label: {
            HStack(spacing: 10) {
                MediaverseIcon(name: "logout", fallbackSystemName: "rectangle.portrait.and.arrow.right")
                    .frame(width: 17, height: 17)
                Text("Sign Out")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(Color.red)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.red.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.red.opacity(0.18), lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(C.textMuted)
            .textCase(.uppercase)
            .tracking(0.6)
    }

    private var rowDivider: some View {
        Divider()
            .background(C.border)
            .padding(.leading, 62)
    }

    // MARK: - Unauth

    private var unauthState: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.circle")
                .font(.system(size: 64))
                .foregroundStyle(C.textMuted)
            Text("Sign in to your account")
                .font(.title3.bold())
                .foregroundStyle(C.text)
            Text("Track your watch history, follow shows and channels, and more.")
                .font(.subheadline)
                .foregroundStyle(C.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding(C.pagePad)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Load

    private func loadAll() async {
        isLoading = true
        async let profTask   = APIClient.shared.fetchProfile()
        async let ctxTask    = APIClient.shared.fetchContexts()
        async let subscriptionsTask = APIClient.shared.fetchUserSubscriptions()
        async let rentalsTask = APIClient.shared.fetchUserRentals()
        async let notificationCountsTask = APIClient.shared.fetchNotificationCounts()

        let (profResult, ctxResult, subscriptionsResult, rentalsResult, notificationCountsResult) = (
            try? await profTask,
            try? await ctxTask,
            try? await subscriptionsTask,
            try? await rentalsTask,
            try? await notificationCountsTask
        )

        if let p = profResult { profile = p.profile }
        if let c = ctxResult {
            contexts   = c.contexts
            activeCtx  = SessionStorage.activeContext ?? c.active
            contextUser = c.user
        }
        subscriptions = subscriptionsResult?.subscriptions ?? []
        rentals = rentalsResult?.rentals ?? []
        notificationCounts = notificationCountsResult ?? [:]
        isLoading = false
    }

    private func loadBilling() async {
        async let subscriptionsTask = APIClient.shared.fetchUserSubscriptions()
        async let rentalsTask = APIClient.shared.fetchUserRentals()
        subscriptions = (try? await subscriptionsTask)?.subscriptions ?? subscriptions
        rentals = (try? await rentalsTask)?.rentals ?? rentals
    }

    private func loadNotificationCounts() async {
        notificationCounts = (try? await APIClient.shared.fetchNotificationCounts()) ?? notificationCounts
    }

    private func ctxIcon(_ type: String) -> String {
        switch type {
        case "admin":   return "shield.fill"
        case "network": return "building.2.fill"
        case "channel": return "play.rectangle.fill"
        default:        return "person.fill"
        }
    }

    private func contextIconName(_ type: String) -> String {
        switch type {
        case "admin": return "shield"
        case "network": return "network"
        case "channel": return "play"
        default: return "user"
        }
    }

    private func fmtCount(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

private struct PartnerRequestSheet: View {
    let onSubmitted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @State private var isSubmitting = false
    @State private var didSubmit = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                C.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Partner application")
                                .font(.title3.bold())
                                .foregroundStyle(C.text)
                            Text("Tell the Backstage team why you want creator access. Your request goes to admins for review.")
                                .font(.subheadline)
                                .foregroundStyle(C.textMuted)
                                .lineSpacing(2)
                        }

                        fieldGroup("Reason") {
                            ZStack(alignment: .topLeading) {
                                if reason.isEmpty {
                                    Text("Share your channel idea, audience, or content plans...")
                                        .foregroundStyle(C.textMuted)
                                        .padding(.horizontal, 12)
                                        .padding(.top, 14)
                                }
                                TextEditor(text: $reason)
                                    .frame(minHeight: 160)
                                    .foregroundStyle(C.text)
                                    .scrollContentBackground(.hidden)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .disabled(isSubmitting || didSubmit)
                            }
                            .background(Color.white.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay { RoundedRectangle(cornerRadius: 10).stroke(C.border, lineWidth: 1) }
                        }

                        if didSubmit {
                            statusBanner(
                                iconName: "checkmark.circle.fill",
                                title: "Request sent",
                                message: "Admins will review your application in Backstage.",
                                color: C.watch
                            )
                        } else if let errorMessage {
                            statusBanner(
                                iconName: "exclamationmark.triangle.fill",
                                title: "Could not send request",
                                message: errorMessage,
                                color: .red
                            )
                        }
                    }
                    .padding(C.pagePad)
                }
            }
            .navigationTitle("Become a Partner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(didSubmit ? "Done" : "Cancel") { dismiss() }
                        .foregroundStyle(C.textMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(submitTitle) {
                        Task { await submit() }
                    }
                    .disabled(isSubmitting || didSubmit)
                    .foregroundStyle(C.watch)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var submitTitle: String {
        isSubmitting ? "Sending..." : "Submit"
    }

    private func fieldGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(C.text)
            content()
        }
    }

    private func statusBanner(iconName: String, title: String, message: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(C.text)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(C.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(color.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.22), lineWidth: 1) }
    }

    private func submit() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            try await APIClient.shared.submitPartnerRequest(reason: reason)
            didSubmit = true
            onSubmitted()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct EditProfileSheet: View {
    let profile: FullProfile?
    let onSaved: (FullProfile) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var bio: String
    @State private var image: String
    @State private var bannerUrl: String
    @State private var selectedProfileItem: PhotosPickerItem?
    @State private var selectedBannerItem: PhotosPickerItem?
    @State private var profilePreviewImage: UIImage?
    @State private var bannerPreviewImage: UIImage?
    @State private var uploadingProfileImage = false
    @State private var uploadingBannerImage = false
    @State private var saving = false
    @State private var saveCompleted = false
    @State private var errorMessage: String?

    init(profile: FullProfile?, onSaved: @escaping (FullProfile) -> Void) {
        self.profile = profile
        self.onSaved = onSaved
        _name = State(initialValue: profile?.name ?? "")
        _bio = State(initialValue: profile?.bio ?? "")
        _image = State(initialValue: profile?.image ?? "")
        _bannerUrl = State(initialValue: profile?.bannerUrl ?? "")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                C.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        fieldGroup("Display name") {
                            TextField("Your name", text: $name)
                                .textFieldStyle(.plain)
                                .foregroundStyle(C.text)
                                .padding(12)
                                .background(Color.white.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay { RoundedRectangle(cornerRadius: 10).stroke(C.border, lineWidth: 1) }
                        }

                        fieldGroup("Bio") {
                            ZStack(alignment: .topLeading) {
                                if bio.isEmpty {
                                    Text("A short description about you...")
                                        .foregroundStyle(C.textMuted)
                                        .padding(.horizontal, 12)
                                        .padding(.top, 14)
                                }
                                TextEditor(text: $bio)
                                    .frame(minHeight: 120)
                                    .foregroundStyle(C.text)
                                    .scrollContentBackground(.hidden)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                            }
                            .background(Color.white.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay { RoundedRectangle(cornerRadius: 10).stroke(C.border, lineWidth: 1) }
                        }

                        fieldGroup("Profile image") {
                            imageUploadControl(
                                title: "Choose profile image",
                                url: $image,
                                pickerItem: $selectedProfileItem,
                                previewImage: profilePreviewImage,
                                existingURL: C.mediaURL(image),
                                isUploading: uploadingProfileImage,
                                aspectRatio: 1
                            )
                        }

                        fieldGroup("Banner image") {
                            imageUploadControl(
                                title: "Choose banner image",
                                url: $bannerUrl,
                                pickerItem: $selectedBannerItem,
                                previewImage: bannerPreviewImage,
                                existingURL: C.mediaURL(bannerUrl),
                                isUploading: uploadingBannerImage,
                                aspectRatio: 16.0 / 6.0
                            )
                        }

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(C.pagePad)
                }
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(C.textMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveButtonTitle) {
                        Task { await save() }
                    }
                    .disabled(!canSave)
                    .foregroundStyle(saveCompleted ? .green : (canSave ? C.watch : C.textMuted))
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onChange(of: selectedProfileItem) { _, item in
            guard let item else { return }
            Task { await uploadSelectedImage(item, kind: .profile) }
        }
        .onChange(of: selectedBannerItem) { _, item in
            guard let item else { return }
            Task { await uploadSelectedImage(item, kind: .banner) }
        }
    }

    private var isUploadingImages: Bool {
        uploadingProfileImage || uploadingBannerImage
    }

    private var canSave: Bool {
        !saving && !saveCompleted && !isUploadingImages && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var saveButtonTitle: String {
        if saveCompleted { return "Done" }
        if saving { return "Saving..." }
        if isUploadingImages { return "Uploading..." }
        return "Save"
    }

    private func imageUploadControl(
        title: String,
        url: Binding<String>,
        pickerItem: Binding<PhotosPickerItem?>,
        previewImage: UIImage?,
        existingURL: URL?,
        isUploading: Bool,
        aspectRatio: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            mediaPreview(previewImage: previewImage, existingURL: existingURL, aspectRatio: aspectRatio)

            HStack(spacing: 10) {
                PhotosPicker(selection: pickerItem, matching: .images, photoLibrary: .shared()) {
                    HStack(spacing: 8) {
                        if isUploading {
                            ProgressView()
                                .tint(.black)
                        } else {
                            MediaverseIcon(name: "image", fallbackSystemName: "photo")
                                .frame(width: 15, height: 15)
                        }
                        Text(isUploading ? "Uploading..." : title)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(C.watch)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(isUploading || saving)

                if !url.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Clear") {
                        url.wrappedValue = ""
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(C.textMuted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .disabled(isUploading || saving)
                }
            }

            TextField("Image URL", text: url)
                .textFieldStyle(.plain)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(C.text)
                .padding(12)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).stroke(C.border, lineWidth: 1) }
        }
    }

    @ViewBuilder
    private func mediaPreview(previewImage: UIImage?, existingURL: URL?, aspectRatio: CGFloat) -> some View {
        ZStack {
            if let previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFill()
            } else if let existingURL {
                CachedRemoteImage(
                    url: existingURL,
                    targetSize: CGSize(width: 700, height: 394)
                ) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    previewPlaceholder
                }
            } else {
                previewPlaceholder
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipped()
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: aspectRatio == 1 ? 12 : 10))
        .overlay { RoundedRectangle(cornerRadius: aspectRatio == 1 ? 12 : 10).stroke(C.border, lineWidth: 1) }
    }

    private var previewPlaceholder: some View {
        ZStack {
            Color.white.opacity(0.05)
            MediaverseIcon(name: "image", fallbackSystemName: "photo")
                .frame(width: 28, height: 28)
                .foregroundStyle(C.textMuted)
        }
    }

    private func fieldGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(C.text)
            content()
        }
    }

    private enum ProfileImageKind: String {
        case profile = "avatar"
        case banner
    }

    private func uploadSelectedImage(_ item: PhotosPickerItem, kind: ProfileImageKind) async {
        setUploading(true, for: kind)
        errorMessage = nil
        defer { setUploading(false, for: kind) }

        do {
            guard let rawData = try await item.loadTransferable(type: Data.self),
                  let sourceImage = UIImage(data: rawData),
                  let uploadData = preparedJPEGData(from: sourceImage, maxPixel: kind == .profile ? 1200 : 1800)
            else {
                throw APIError.invalidResponse("Could not read the selected image.")
            }

            let uploadedURL = try await APIClient.shared.uploadProfileBlobImage(
                kind: kind.rawValue,
                imageData: uploadData
            )
            switch kind {
            case .profile:
                image = uploadedURL
                profilePreviewImage = sourceImage
                selectedProfileItem = nil
            case .banner:
                bannerUrl = uploadedURL
                bannerPreviewImage = sourceImage
                selectedBannerItem = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setUploading(_ uploading: Bool, for kind: ProfileImageKind) {
        switch kind {
        case .profile:
            uploadingProfileImage = uploading
        case .banner:
            uploadingBannerImage = uploading
        }
    }

    private func preparedJPEGData(from image: UIImage, maxPixel: CGFloat) -> Data? {
        let largestSide = max(image.size.width, image.size.height)
        let scale = largestSide > maxPixel ? maxPixel / largestSide : 1
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return resized.jpegData(compressionQuality: 0.86)
    }

    private func save() async {
        guard !isUploadingImages else {
            errorMessage = "Wait for image uploads to finish before saving."
            return
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedImage = image.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBanner = bannerUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        saving = true
        errorMessage = nil
        do {
            let resp = try await APIClient.shared.updateProfile(
                name: trimmedName,
                bio: trimmedBio.isEmpty ? nil : trimmedBio,
                image: trimmedImage.isEmpty ? nil : trimmedImage,
                bannerUrl: trimmedBanner.isEmpty ? nil : trimmedBanner
            )
            onSaved(resp.profile)
            saveCompleted = true
            saving = false
            try? await Task.sleep(nanoseconds: 650_000_000)
            dismiss()
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        saving = false
    }
}
