import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

private struct VibeEventTemplateIcon: View {
    let name: String?

    var body: some View {
        Image(systemName: symbol)
    }

    private var symbol: String {
        switch name {
        case "messages-square": "message.fill"
        case "play-circle": "play.circle.fill"
        case "sparkles": "sparkles"
        case "circle-help": "questionmark.circle.fill"
        case "users": "person.3.fill"
        case "panel-top": "rectangle.split.3x1.fill"
        case "presentation": "rectangle.inset.filled.and.person.filled"
        case "mic-2": "mic.fill"
        case "megaphone": "megaphone.fill"
        case "party-popper": "party.popper.fill"
        case "radio": "dot.radiowaves.left.and.right"
        case "lock": "lock.fill"
        case "plus": "plus"
        default: "calendar.badge.plus"
        }
    }
}

struct VibeEventsView: View {
    private enum Scope: String, CaseIterable, Identifiable {
        case upcoming
        case live
        case myVibes = "my-vibes"
        case shows
        case channels
        var id: String { rawValue }
        var label: String {
            switch self {
            case .upcoming: "For You"
            case .live: "Live Now"
            case .myVibes: "From Your Vibes"
            case .shows: "Shows"
            case .channels: "Channels"
            }
        }
    }

    @State private var scope: Scope = .upcoming
    @State private var events = [VibeEventCardModel]()
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var showsCreator = false
    @State private var availableScopes: Set<Scope> = [.upcoming]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                header
                scopePills
                content
            }
            .padding(.horizontal, C.pagePad)
            .padding(.bottom, 110)
        }
        .background(C.bg)
        .navigationTitle("Events")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task(id: scope) { await load() }
        .task { await discoverAvailableScopes() }
        .sheet(isPresented: $showsCreator) {
            NavigationStack {
                VibeEventCreatorView { event in
                    showsCreator = false
                    Task { await load() }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 5) {
                Text("DISCOVER TOGETHER")
                    .font(.system(size: 11, weight: .black))
                    .tracking(1.5)
                    .foregroundStyle(C.watch)
                Text("Live moments from Vibes")
                    .font(.system(size: 25, weight: .black, design: .rounded))
                    .foregroundStyle(C.text)
            }
            Spacer()
            Button { showsCreator = true } label: {
                Label("Create", systemImage: "plus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(C.watch, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 12)
    }

    private var scopePills: some View {
        WestreemHorizontalScrollView(showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Scope.allCases.filter { availableScopes.contains($0) || $0 == scope }) { item in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { scope = item }
                    } label: {
                        Text(item.label)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(scope == item ? Color.black : C.textMuted)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(scope == item ? Color.white : C.surface, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if loading {
            ForEach(0..<4, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 18)
                    .fill(C.surface)
                    .aspectRatio(1.3, contentMode: .fit)
                    .redacted(reason: .placeholder)
            }
        } else if let errorMessage {
            ContentUnavailableView("Events couldn’t load", systemImage: "wifi.exclamationmark", description: Text(errorMessage))
                .foregroundStyle(C.text)
        } else if events.isEmpty {
            ContentUnavailableView("No Events here yet", systemImage: "calendar.badge.plus", description: Text("Try another view or create the first gathering for your Vibe."))
                .foregroundStyle(C.text)
        } else {
            ForEach(events) { event in
                NavigationLink(value: AppRoute.event(event.slug)) {
                    VibeEventCardView(event: event)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @MainActor private func load() async {
        loading = true
        errorMessage = nil
        do {
            let requestedScope = scope == .shows || scope == .channels ? "upcoming" : scope.rawValue
            let loaded = try await APIClient.shared.fetchVibeEvents(scope: requestedScope)
            switch scope {
            case .shows: events = loaded.filter { $0.affiliatedShow != nil }
            case .channels: events = loaded.filter { $0.affiliatedChannel != nil }
            default: events = loaded
            }
        }
        catch { events = []; errorMessage = error.localizedDescription }
        loading = false
    }

    @MainActor private func discoverAvailableScopes() async {
        async let upcomingRequest = try? APIClient.shared.fetchVibeEvents(scope: "upcoming")
        async let liveRequest = try? APIClient.shared.fetchVibeEvents(scope: "live")
        async let vibesRequest = try? APIClient.shared.fetchVibeEvents(scope: "my-vibes")
        let upcoming = await upcomingRequest ?? []
        let live = await liveRequest ?? []
        let fromVibes = await vibesRequest ?? []
        var scopes: Set<Scope> = []
        if !upcoming.isEmpty { scopes.insert(.upcoming) }
        if !live.isEmpty { scopes.insert(.live) }
        if !fromVibes.isEmpty { scopes.insert(.myVibes) }
        if upcoming.contains(where: { $0.affiliatedShow != nil }) { scopes.insert(.shows) }
        if upcoming.contains(where: { $0.affiliatedChannel != nil }) { scopes.insert(.channels) }
        availableScopes = scopes.isEmpty ? [.upcoming] : scopes
        if !availableScopes.contains(scope) { scope = availableScopes.first ?? .upcoming }
    }
}

struct VibeEventCardView: View {
    let event: VibeEventCardModel
    private var start: Date? { event.startsAt.vibeEventDate }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                AsyncImage(url: C.mediaURL(event.coverUrl)) { phase in
                    if case .success(let image) = phase { image.resizable().scaledToFill() }
                    else { LinearGradient(colors: [C.watch.opacity(0.35), Color.purple.opacity(0.25), Color.indigo.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing) }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 9, contentMode: .fill)
                .clipped()
                HStack {
                    Label(event.status == "LIVE" ? "LIVE NOW" : event.status == "COMPLETED" ? "REPLAY" : "UPCOMING", systemImage: event.status == "LIVE" ? "dot.radiowaves.left.and.right" : "calendar")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(event.status == "LIVE" ? Color.red : Color.black.opacity(0.65), in: Capsule())
                    Spacer()
                    if event.visibility == "INVITE_ONLY" {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .padding(8)
                            .background(.black.opacity(0.65), in: Circle())
                    }
                }
                .padding(12)
            }
            VStack(alignment: .leading, spacing: 7) {
                if let start {
                    Text(start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(C.watch)
                }
                Text(event.title)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(C.text)
                    .lineLimit(2)
                Text(event.summary)
                    .font(.subheadline)
                    .foregroundStyle(C.textMuted)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    AsyncImage(url: C.mediaURL(event.club.avatarUrl)) { image in image.resizable().scaledToFill() } placeholder: { Circle().fill(C.surfaceAlt) }
                        .frame(width: 28, height: 28).clipShape(Circle())
                    Text(event.club.name).font(.caption.weight(.semibold)).foregroundStyle(C.textMuted).lineLimit(1)
                    Spacer()
                    if event.goingCount > 0 {
                        Label("\(event.goingCount) going", systemImage: "person.2.fill")
                            .font(.caption)
                            .foregroundStyle(C.textMuted)
                    }
                }
                if let show = event.affiliatedShow, let title = show.title {
                    Label(title, systemImage: "play.rectangle.fill")
                        .font(.caption)
                        .foregroundStyle(C.textMuted)
                        .lineLimit(1)
                }
                if let channel = event.affiliatedChannel, let name = channel.name {
                    Label(name, systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption)
                        .foregroundStyle(C.textMuted)
                        .lineLimit(1)
                }
            }
            .padding(15)
        }
        .background(C.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(C.borderSubtle, lineWidth: 1))
    }
}

struct VibeEventDetailView: View {
    let slug: String
    var analyticsSource: String = "direct"
    @Environment(\.openURL) private var openURL
    @State private var response: VibeEventDetailResponse?
    @State private var loading = true
    @State private var rsvpBusy = false
    @State private var errorMessage: String?
    @State private var showsManager = false
    @State private var showsRippleReport = false
    @State private var didTrackView = false
    @State private var analyticsSessionID = UUID().uuidString

    var body: some View {
        ScrollView {
            if loading {
                ProgressView().tint(C.watch).frame(maxWidth: .infinity).padding(.top, 120)
            } else if let response {
                eventContent(response)
            } else {
                ContentUnavailableView("Event unavailable", systemImage: "calendar.badge.exclamationmark", description: Text(errorMessage ?? "This Event could not be found."))
                    .foregroundStyle(C.text).padding(.top, 100)
            }
        }
        .background(C.bg)
        .navigationTitle("Event")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if response?.capabilities.canManage == true {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Manage") { showsManager = true }
                        .foregroundStyle(C.watch)
                }
            }
        }
        .sheet(isPresented: $showsManager) {
            if let event = response?.event {
                NavigationStack {
                    VibeEventManagerView(event: event) {
                        showsManager = false
                        Task { await load() }
                    }
                }
            }
        }
        .sheet(isPresented: $showsRippleReport) {
            if let ripple = response?.event.associatedPost {
                RippleReportSheet(postId: ripple.id, vibeSlug: response?.event.club.slug ?? "")
            }
        }
        .task {
            await load()
            if response != nil, !didTrackView {
                didTrackView = true
                await track("view")
            }
        }
        .refreshable { await load() }
    }

    @ViewBuilder private func eventContent(_ response: VibeEventDetailResponse) -> some View {
        let event = response.event
        VStack(alignment: .leading, spacing: 18) {
            AsyncImage(url: C.mediaURL(event.coverUrl)) { phase in
                if case .success(let image) = phase { image.resizable().scaledToFill() }
                else { LinearGradient(colors: [C.watch.opacity(0.35), Color.indigo.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing) }
            }
            .aspectRatio(16 / 9, contentMode: .fill).clipped()
            VStack(alignment: .leading, spacing: 16) {
                Text(event.status == "LIVE" ? "LIVE NOW" : event.status)
                    .font(.caption2.weight(.black)).foregroundStyle(event.status == "LIVE" ? Color.red : C.watch)
                Text(event.title).font(.system(size: 30, weight: .black, design: .rounded)).foregroundStyle(C.text)
                HStack(spacing: 10) {
                    AsyncImage(url: C.mediaURL(event.club.avatarUrl)) { image in image.resizable().scaledToFill() } placeholder: { Circle().fill(C.surface) }
                        .frame(width: 42, height: 42).clipShape(Circle())
                    Text(event.club.name).font(.headline).foregroundStyle(C.text)
                }
                infoCard(event)
                Text(event.summary).font(.title3.weight(.medium)).foregroundStyle(C.text)
                if let description = event.description, !description.isEmpty {
                    Text(description).font(.body).foregroundStyle(C.textMuted)
                }
                if !event.topics.isEmpty {
                    WestreemHorizontalScrollView(showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(event.topics, id: \.self) { topic in
                                Text(topic)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(C.textMuted)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(C.surface, in: Capsule())
                            }
                        }
                    }
                }
                if !event.agenda.isEmpty {
                    Text("Agenda").font(.title3.bold()).foregroundStyle(C.text)
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(event.agenda) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).font(.subheadline.bold()).foregroundStyle(C.text)
                                if let detail = item.detail, !detail.isEmpty {
                                    Text(detail).font(.caption).foregroundStyle(C.textMuted)
                                }
                            }
                        }
                    }
                }
                if !event.hosts.isEmpty {
                    Text("Hosts").font(.title3.bold()).foregroundStyle(C.text)
                    ForEach(event.hosts) { host in
                        HStack(spacing: 12) {
                            AsyncImage(url: C.mediaURL(host.user.image)) { image in image.resizable().scaledToFill() } placeholder: { Circle().fill(C.surfaceAlt) }
                                .frame(width: 44, height: 44).clipShape(Circle())
                            VStack(alignment: .leading) {
                                Text(host.user.name ?? host.user.handle ?? "Host").font(.subheadline.bold()).foregroundStyle(C.text)
                                Text(host.role.replacingOccurrences(of: "_", with: " ").capitalized).font(.caption).foregroundStyle(C.textMuted)
                            }
                        }
                    }
                }
                if let show = event.affiliatedShow, let title = show.title {
                    Label("Affiliated with \(title)", systemImage: "play.rectangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(C.textMuted)
                }
                if let channel = event.affiliatedChannel, let name = channel.name {
                    Label("Affiliated with \(name)", systemImage: "dot.radiowaves.left.and.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(C.textMuted)
                }
                if let ripple = event.associatedPost {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Event conversation").font(.title3.bold()).foregroundStyle(C.text)
                        HStack(spacing: 18) {
                            if ripple.energyCount > 0 { Label("\(ripple.energyCount) Energy", systemImage: "bolt.fill") }
                            if ripple.commentCount > 0 { Label("\(ripple.commentCount) Comments", systemImage: "bubble.left") }
                            if ripple.echoCount > 0 { Label("\(ripple.echoCount) Echoes", systemImage: "wave.3.right") }
                        }
                        .font(.caption)
                        .foregroundStyle(C.textMuted)
                        CommentThreadView(
                            target: .ripple(ripple.id),
                            inputPosition: .top,
                            showsHeader: false,
                            autoFocusComposer: false,
                            onCountChange: { _ in }
                        )
                        Button {
                            showsRippleReport = true
                        } label: {
                            Label("Report Ripple", systemImage: "flag")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(C.textMuted)
                        }
                    }
                }
                if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(.red) }
            }
            .padding(.horizontal, C.pagePad)
        }
        .padding(.bottom, 100)
    }

    private func infoCard(_ event: VibeEventDetailModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let date = event.startsAt.vibeEventDate {
                Label(date.formatted(.dateTime.weekday(.wide).month(.wide).day().hour().minute()), systemImage: "calendar")
            }
            Label(event.capacity.map { "\(event.goingCount) going · \($0) capacity" } ?? "\(event.goingCount) going", systemImage: "person.2")
            if event.visibility == "INVITE_ONLY" { Label("Invite only", systemImage: "lock.fill") }
            if response?.capabilities.canRsvp == true {
                HStack {
                    Button(event.rsvps.first?.status == "GOING" ? "Going ✓" : "Going") { Task { await rsvp("GOING") } }
                        .buttonStyle(EventPrimaryButtonStyle())
                    Button(event.rsvps.first?.status == "INTERESTED" ? "Interested ✓" : "Interested") { Task { await rsvp("INTERESTED") } }
                        .buttonStyle(EventSecondaryButtonStyle())
                }.disabled(rsvpBusy)
                if event.rsvps.first != nil {
                    Button("Not going") { Task { await rsvp("NOT_GOING") } }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(C.textMuted)
                        .disabled(rsvpBusy)
                }
            }
            let now = Date()
            let insideLiveWindow = event.status == "LIVE"
                || ((event.startsAt.vibeEventDate ?? .distantFuture) <= now
                    && (event.endsAt.vibeEventDate ?? .distantPast) >= now)
            let destination = event.status == "COMPLETED"
                ? event.replayUrl
                : insideLiveWindow ? event.onlineUrl : nil
            if let destination, let url = URL(string: destination) {
                Button {
                    Task {
                        await track(event.status == "COMPLETED" ? "replay_start" : "join")
                        openURL(url)
                    }
                } label: { Label(event.status == "COMPLETED" ? "Watch replay" : "Join online", systemImage: "video.fill") }
                    .buttonStyle(EventSecondaryButtonStyle())
            }
        }
        .font(.subheadline)
        .foregroundStyle(C.textMuted)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(C.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    @MainActor private func load() async {
        loading = response == nil
        do { response = try await APIClient.shared.fetchVibeEvent(slug: slug); errorMessage = nil }
        catch { if response == nil { errorMessage = error.localizedDescription } }
        loading = false
    }

    @MainActor private func rsvp(_ status: String) async {
        rsvpBusy = true
        do {
            _ = try await APIClient.shared.updateVibeEventRSVP(slug: slug, status: status)
            await track("rsvp")
            await load()
        }
        catch { errorMessage = error.localizedDescription }
        rsvpBusy = false
    }

    private func track(_ action: String) async {
        try? await APIClient.shared.trackVibeEventAnalytics(
            slug: slug,
            action: action,
            source: analyticsSource,
            sessionID: analyticsSessionID
        )
    }
}

struct VibeEventInviteView: View {
    let token: String
    @Environment(\.dismiss) private var dismiss
    @State private var invite: VibeEventInvitePreview?
    @State private var loading = true
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var acceptedSlug: String?

    var body: some View {
        VStack(spacing: 0) {
            if loading {
                ProgressView().tint(C.watch)
            } else if let invite {
                ScrollView {
                    VStack(spacing: 20) {
                        AsyncImage(url: C.mediaURL(invite.event.coverUrl)) { phase in
                            if case .success(let image) = phase { image.resizable().scaledToFill() }
                            else { LinearGradient(colors: [C.watch.opacity(0.35), Color.indigo.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing) }
                        }
                        .aspectRatio(16 / 9, contentMode: .fill).clipped()
                        Text("PRIVATE EVENT INVITATION").font(.caption2.weight(.black)).tracking(1.4).foregroundStyle(C.watch)
                        Text(invite.event.title).font(.system(size: 28, weight: .black, design: .rounded)).foregroundStyle(C.text).multilineTextAlignment(.center)
                        Text(invite.event.summary).font(.body).foregroundStyle(C.textMuted).multilineTextAlignment(.center)
                        Text("Hosted by \(invite.event.club.name)").font(.subheadline).foregroundStyle(C.textTertiary)
                        HStack(spacing: 12) {
                            Button("Decline") { Task { await respond(accept: false) } }.buttonStyle(EventSecondaryButtonStyle())
                            Button("Accept invitation") { Task { await respond(accept: true) } }.buttonStyle(EventPrimaryButtonStyle())
                        }.disabled(busy)
                        if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(.red) }
                    }
                    .padding(.bottom, 80)
                }
            } else {
                ContentUnavailableView("Invitation unavailable", systemImage: "envelope.badge.fill", description: Text(errorMessage ?? "This invitation is no longer valid."))
                    .foregroundStyle(C.text)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(C.bg)
        .navigationTitle("Event invitation")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $acceptedSlug) { VibeEventDetailView(slug: $0) }
        .task { await load() }
    }

    @MainActor private func load() async {
        do { invite = try await APIClient.shared.fetchVibeEventInvite(token: token) }
        catch { errorMessage = error.localizedDescription }
        loading = false
    }

    @MainActor private func respond(accept: Bool) async {
        busy = true
        do {
            let response = try await APIClient.shared.respondToVibeEventInvite(token: token, accept: accept)
            if response.accepted { acceptedSlug = response.eventSlug } else { dismiss() }
        } catch { errorMessage = error.localizedDescription }
        busy = false
    }
}

private struct EventPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.bold()).foregroundStyle(Color.black)
            .frame(maxWidth: .infinity).padding(.vertical, 11)
            .background(C.watch.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 11))
    }
}
private struct EventSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.bold()).foregroundStyle(C.text)
            .frame(maxWidth: .infinity).padding(.vertical, 11)
            .background(C.surfaceAlt.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 11))
    }
}

struct VibeEventCreatorView: View {
    fileprivate enum AffiliationPicker: String, Identifiable {
        case show = "Show"
        case channel = "Channel"
        var id: String { rawValue }
    }
    let onCreated: (CreatedVibeEvent) -> Void
    var preselectedVibeSlug: String? = nil
    var editEvent: VibeEventDetailModel? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var templates = [VibeEventTemplateModel]()
    @State private var vibes = [VibeSummary]()
    @State private var selectedTemplate: VibeEventTemplateModel?
    @State private var selectedVibeID = ""
    @State private var title = ""
    @State private var summary = ""
    @State private var details = ""
    @State private var coverURL = ""
    @State private var coverFocusX = 50.0
    @State private var coverFocusY = 50.0
    @State private var coverItem: PhotosPickerItem?
    @State private var uploadingCover = false
    @State private var startsAt = Date().addingTimeInterval(86_400)
    @State private var duration = 60
    @State private var onlineURL = ""
    @State private var accessInstructions = ""
    @State private var inviteOnly = false
    @State private var capacity = ""
    @State private var hasRSVPDeadline = false
    @State private var rsvpDeadline = Date().addingTimeInterval(43_200)
    @State private var topicsText = ""
    @State private var agenda = [VibeEventAgendaInput]()
    @State private var affiliatedShowID = ""
    @State private var affiliatedChannelID = ""
    @State private var replayURL = ""
    @State private var shows = [ShowBrowseCard]()
    @State private var channels = [ChannelBrowseCard]()
    @State private var busy = false
    @State private var creatorLoading = true
    @State private var creatorLoadError: String?
    @State private var errorMessage: String?
    @State private var affiliationPicker: AffiliationPicker?

    var body: some View {
        Group {
            if creatorLoading {
                ProgressView("Loading Event templates…")
                    .tint(C.watch)
                    .foregroundStyle(C.textMuted)
            } else if let creatorLoadError {
                ContentUnavailableView(
                    "Event setup couldn’t load",
                    systemImage: "calendar.badge.exclamationmark",
                    description: Text(creatorLoadError)
                )
                .foregroundStyle(C.text)
            } else if let template = selectedTemplate {
                editor(template)
            } else {
                templateGallery
            }
        }
        .background(C.bg)
        .navigationTitle(editEvent != nil ? "Edit Event" : selectedTemplate == nil ? "Create Event" : "Event details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(editEvent != nil || selectedTemplate == nil ? "Close" : "Templates") {
                    if editEvent != nil || selectedTemplate == nil { dismiss() } else { selectedTemplate = nil }
                }.foregroundStyle(C.watch)
            }
        }
        .sheet(item: $affiliationPicker) { picker in
            NavigationStack {
                EventAffiliationPicker(
                    kind: picker,
                    shows: shows,
                    channels: channels,
                    selectedID: picker == .show ? affiliatedShowID : affiliatedChannelID
                ) { id in
                    if picker == .show { affiliatedShowID = id }
                    else { affiliatedChannelID = id }
                    affiliationPicker = nil
                }
            }
        }
        .task {
            creatorLoading = true
            creatorLoadError = nil
            do {
                async let templatesRequest = APIClient.shared.fetchVibeEventTemplates()
                async let vibesRequest = APIClient.shared.fetchManagedCommunityVibes()
                async let showsRequest = APIClient.shared.fetchShowsBrowse()
                async let channelsRequest = APIClient.shared.fetchChannels()
                templates = try await templatesRequest
                vibes = try await vibesRequest
                shows = (try? await showsRequest) ?? []
                channels = (try? await channelsRequest) ?? []
                guard !templates.isEmpty else {
                    creatorLoadError = "No Event templates are currently available."
                    creatorLoading = false
                    return
                }
                if selectedVibeID.isEmpty {
                    selectedVibeID = vibes.first(where: { $0.slug == preselectedVibeSlug })?.id
                        ?? vibes.first?.id
                        ?? ""
                }
                if let event = editEvent {
                    selectedTemplate = templates.first(where: { $0.slug == "blank" }) ?? templates.first
                    selectedVibeID = event.club.id ?? selectedVibeID
                    title = event.title
                    summary = event.summary
                    details = event.description ?? ""
                    coverURL = event.coverUrl ?? ""
                    startsAt = event.startsAt.vibeEventDate ?? startsAt
                    if let start = event.startsAt.vibeEventDate, let end = event.endsAt.vibeEventDate {
                        duration = max(1, Int(end.timeIntervalSince(start) / 60))
                    }
                    onlineURL = event.onlineUrl ?? ""
                    accessInstructions = event.accessInstructions ?? ""
                    inviteOnly = event.visibility == "INVITE_ONLY"
                    capacity = event.capacity.map(String.init) ?? ""
                    if let deadline = event.rsvpDeadline?.vibeEventDate {
                        hasRSVPDeadline = true
                        rsvpDeadline = deadline
                    }
                    topicsText = event.topics.joined(separator: ", ")
                    agenda = event.agenda.map { .init(id: $0.id, title: $0.title, detail: $0.detail) }
                    affiliatedShowID = event.affiliatedShow?.id ?? ""
                    affiliatedChannelID = event.affiliatedChannel?.id ?? ""
                    replayURL = event.replayUrl ?? ""
                }
            } catch {
                creatorLoadError = error.localizedDescription
            }
            creatorLoading = false
        }
    }

    private var templateGallery: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(templates) { template in
                    Button {
                        duration = template.defaultDuration
                        inviteOnly = template.allowedVisibility == ["INVITE_ONLY"]
                        selectedTemplate = template
                    } label: {
                        VStack(alignment: .leading, spacing: 9) {
                            VibeEventTemplateIcon(name: template.icon)
                                .font(.title2).foregroundStyle(C.watch)
                            Spacer()
                            if template.recommended { Text("RECOMMENDED").font(.system(size: 8, weight: .black)).foregroundStyle(C.watch) }
                            Text(template.name).font(.headline).foregroundStyle(C.text)
                            Text(template.description).font(.caption).foregroundStyle(C.textMuted).lineLimit(3)
                        }
                        .padding(14).frame(maxWidth: .infinity, minHeight: 180, alignment: .leading)
                        .background(LinearGradient(colors: [C.watch.opacity(0.18), C.surface], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(C.borderSubtle))
                    }.buttonStyle(.plain)
                }
            }.padding(C.pagePad)
        }
    }

    private func editor(_ template: VibeEventTemplateModel) -> some View {
        Form {
            Section("Basics") {
                Picker("Hosting Vibe", selection: $selectedVibeID) { ForEach(vibes) { Text($0.name).tag($0.id) } }
                    .disabled(editEvent != nil)
                TextField("Event title", text: $title)
                TextField("Summary", text: $summary, axis: .vertical).lineLimit(3...5)
                TextField("About", text: $details, axis: .vertical).lineLimit(4...8)
                if !coverURL.isEmpty {
                    AsyncImage(url: C.mediaURL(coverURL)) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Rectangle().fill(C.surfaceAlt)
                    }
                    .aspectRatio(16 / 9, contentMode: .fill)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                PhotosPicker(selection: $coverItem, matching: .images) {
                    Label(uploadingCover ? "Uploading cover…" : "Choose cover image", systemImage: "photo")
                }
                .disabled(uploadingCover)
                .onChange(of: coverItem) { _, item in
                    guard let item else { return }
                    Task { await uploadCover(item) }
                }
                VStack(alignment: .leading) {
                    Text("Cover focal position").font(.caption).foregroundStyle(C.textMuted)
                    HStack { Text("Horizontal"); Slider(value: $coverFocusX, in: 0...100) }
                    HStack { Text("Vertical"); Slider(value: $coverFocusY, in: 0...100) }
                }
            }
            Section("Schedule") {
                DatePicker("Starts", selection: $startsAt, in: Date()...)
                Picker("Duration", selection: $duration) { ForEach([30,45,60,75,90,120,180], id: \.self) { Text("\($0) minutes").tag($0) } }
            }
            Section("Online experience") {
                TextField("https://", text: $onlineURL).textInputAutocapitalization(.never).keyboardType(.URL)
                TextField("Access instructions", text: $accessInstructions, axis: .vertical).lineLimit(2...5)
            }
            Section("Access and RSVP") {
                Toggle("Invite only", isOn: $inviteOnly).disabled(template.allowedVisibility == ["INVITE_ONLY"])
                TextField("Capacity (optional)", text: $capacity).keyboardType(.numberPad)
                Toggle("RSVP deadline", isOn: $hasRSVPDeadline)
                if hasRSVPDeadline {
                    DatePicker("Deadline", selection: $rsvpDeadline, in: Date()...startsAt)
                }
            }
            Section("Topics and agenda") {
                TextField("Topics, separated by commas", text: $topicsText)
                ForEach($agenda) { $item in
                    TextField("Agenda title", text: $item.title)
                    TextField("Details (optional)", text: Binding(
                        get: { item.detail ?? "" },
                        set: { item.detail = $0.isEmpty ? nil : $0 }
                    ))
                }
                .onDelete { agenda.remove(atOffsets: $0) }
                Button("Add agenda item") {
                    agenda.append(.init(id: UUID().uuidString, title: "", detail: nil))
                }
            }
            Section("Affiliations") {
                Button {
                    affiliationPicker = .show
                } label: {
                    HStack {
                        Text("Show").foregroundStyle(C.text)
                        Spacer()
                        Text(shows.first(where: { $0.id == affiliatedShowID })?.title ?? "None")
                            .foregroundStyle(C.textMuted)
                        Image(systemName: "chevron.right").foregroundStyle(C.textTertiary)
                    }
                }
                Button {
                    affiliationPicker = .channel
                } label: {
                    HStack {
                        Text("Channel").foregroundStyle(C.text)
                        Spacer()
                        Text(channels.first(where: { $0.id == affiliatedChannelID })?.name ?? "None")
                            .foregroundStyle(C.textMuted)
                        Image(systemName: "chevron.right").foregroundStyle(C.textTertiary)
                    }
                }
            }
            Section("Replay") {
                TextField("Replay URL (optional)", text: $replayURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
            }
            Section("Preview") {
                VStack(alignment: .leading, spacing: 8) {
                    if !coverURL.isEmpty {
                        AsyncImage(url: C.mediaURL(coverURL)) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Rectangle().fill(C.surfaceAlt)
                        }
                        .aspectRatio(16 / 9, contentMode: .fill)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    Text(title.isEmpty ? "Event title" : title)
                        .font(.headline)
                        .foregroundStyle(C.text)
                    Text(summary.isEmpty ? "Your Event summary will appear here." : summary)
                        .font(.subheadline)
                        .foregroundStyle(C.textMuted)
                    Label(
                        startsAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()),
                        systemImage: "calendar"
                    )
                    .font(.caption)
                    .foregroundStyle(C.watch)
                    if inviteOnly {
                        Label("Invite only", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(C.textMuted)
                    }
                }
            }
            if vibes.isEmpty { Section { Text("You need to manage a community Vibe before creating an Event.").foregroundStyle(.orange) } }
            if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
            Section {
                Button { Task { await save(status: editEvent?.status ?? "SCHEDULED") } } label: {
                    HStack { Spacer(); if busy { ProgressView() } else { Text(editEvent == nil ? "Publish Event" : "Save changes").fontWeight(.bold) }; Spacer() }
                }.disabled(busy || vibes.isEmpty || title.trimmingCharacters(in: .whitespaces).isEmpty || summary.trimmingCharacters(in: .whitespaces).isEmpty)
                if editEvent == nil {
                    Button("Save draft") { Task { await save(status: "DRAFT") } }
                    .disabled(busy || vibes.isEmpty || title.trimmingCharacters(in: .whitespaces).isEmpty || summary.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .tint(C.watch)
    }

    @MainActor private func save(status: String) async {
        guard let template = selectedTemplate else { return }
        busy = true; errorMessage = nil
        let end = startsAt.addingTimeInterval(TimeInterval(duration * 60))
        let request = CreateVibeEventRequest(
            templateId: template.id, clubId: selectedVibeID, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines), description: details.isEmpty ? nil : details,
            coverUrl: coverURL.isEmpty ? nil : coverURL,
            coverFocus: "\(Int(coverFocusX))% \(Int(coverFocusY))% scale",
            startsAt: ISO8601DateFormatter.vibeEvent.string(from: startsAt), endsAt: ISO8601DateFormatter.vibeEvent.string(from: end),
            timeZone: TimeZone.current.identifier, onlineUrl: onlineURL.isEmpty ? nil : onlineURL,
            accessInstructions: accessInstructions.isEmpty ? nil : accessInstructions,
            visibility: inviteOnly ? "INVITE_ONLY" : "PUBLIC", capacity: Int(capacity),
            rsvpDeadline: hasRSVPDeadline ? ISO8601DateFormatter.vibeEvent.string(from: rsvpDeadline) : nil,
            topics: topicsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            agenda: agenda.filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
            affiliatedShowId: affiliatedShowID.isEmpty ? nil : affiliatedShowID,
            affiliatedChannelId: affiliatedChannelID.isEmpty ? nil : affiliatedChannelID,
            replayUrl: replayURL.isEmpty ? nil : replayURL,
            status: status
        )
        do {
            if let event = editEvent {
                let updated = try await APIClient.shared.updateVibeEvent(slug: event.slug, request: request)
                onCreated(.init(id: updated.id, slug: updated.slug))
            } else {
                let event = try await APIClient.shared.createVibeEvent(request)
                onCreated(event)
            }
        }
        catch { errorMessage = error.localizedDescription }
        busy = false
    }

    @MainActor private func uploadCover(_ item: PhotosPickerItem) async {
        guard let vibe = vibes.first(where: { $0.id == selectedVibeID }) else {
            errorMessage = "Choose the hosting Vibe before adding a cover."
            return
        }
        uploadingCover = true
        defer { uploadingCover = false; coverItem = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw NSError(domain: "VibeEvent", code: 1, userInfo: [NSLocalizedDescriptionKey: "The selected cover could not be read."])
            }
            let mimeType = item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg"
            let uploaded = try await LegacySocialAPIAdapter(transport: APIClient.shared)
                .uploadVibeProfileImage(toVibe: vibe.slug, data: data, mimeType: mimeType)
            coverURL = uploaded.imageURL
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct EventAffiliationPicker: View {
    let kind: VibeEventCreatorView.AffiliationPicker
    let shows: [ShowBrowseCard]
    let channels: [ChannelBrowseCard]
    let selectedID: String
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filteredShows: [ShowBrowseCard] {
        guard !query.isEmpty else { return shows }
        return shows.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private var filteredChannels: [ChannelBrowseCard] {
        guard !query.isEmpty else { return channels }
        return channels.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.handle.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            Button {
                onSelect("")
            } label: {
                HStack {
                    Label("No affiliation", systemImage: "nosign")
                    Spacer()
                    if selectedID.isEmpty { Image(systemName: "checkmark").foregroundStyle(C.watch) }
                }
            }
            if kind == .show {
                ForEach(filteredShows) { show in
                    selectionRow(id: show.id, title: show.title, subtitle: nil, image: show.coverUrl)
                }
            } else {
                ForEach(filteredChannels) { channel in
                    selectionRow(id: channel.id, title: channel.name, subtitle: "@\(channel.handle)", image: channel.avatarUrl)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(C.bg)
        .searchable(text: $query, prompt: "Search \(kind.rawValue.lowercased())s")
        .navigationTitle("Select \(kind.rawValue)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }.foregroundStyle(C.watch)
            }
        }
    }

    private func selectionRow(id: String, title: String, subtitle: String?, image: String?) -> some View {
        Button {
            onSelect(id)
        } label: {
            HStack(spacing: 12) {
                SocialIdentityAvatar(image: image, name: title, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(C.text)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(C.textMuted)
                    }
                }
                Spacer()
                if selectedID == id { Image(systemName: "checkmark").foregroundStyle(C.watch) }
            }
        }
    }
}

struct VibeEventVibeSection: View {
    let vibeSlug: String
    let canManage: Bool
    @State private var events = [VibeEventCardModel]()
    @State private var loading = true
    @State private var showsCreator = false

    var body: some View {
        Group {
            if loading {
                ProgressView()
                    .tint(C.watch)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            } else if !events.isEmpty || canManage {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Events")
                            .font(.title3.bold())
                            .foregroundStyle(C.text)
                        Spacer()
                        if canManage {
                            Button {
                                showsCreator = true
                            } label: {
                                Label("Create Event", systemImage: "calendar.badge.plus")
                                    .font(.caption.bold())
                                    .foregroundStyle(C.watch)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if events.isEmpty {
                        Text("Create the first online Event for this Vibe.")
                            .font(.subheadline)
                            .foregroundStyle(C.textMuted)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(events.prefix(3)) { event in
                            NavigationLink(value: AppRoute.event(event.slug)) {
                                VibeEventCardView(event: event)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, C.pagePad)
            }
        }
        .task(id: vibeSlug) { await load() }
        .sheet(isPresented: $showsCreator) {
            NavigationStack {
                VibeEventCreatorView(onCreated: { _ in
                    showsCreator = false
                    Task { await load() }
                }, preselectedVibeSlug: vibeSlug)
            }
        }
    }

    @MainActor private func load() async {
        loading = true
        async let live = try? APIClient.shared.fetchVibeEvents(scope: "live", vibe: vibeSlug)
        async let upcoming = try? APIClient.shared.fetchVibeEvents(scope: "upcoming", vibe: vibeSlug)
        async let past = try? APIClient.shared.fetchVibeEvents(scope: "past", vibe: vibeSlug)
        let combined = await ((live ?? []) + (upcoming ?? []) + (past ?? []))
        var seen = Set<String>()
        events = combined.filter { seen.insert($0.id).inserted }
        loading = false
    }
}

struct VibeEventManagerView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case edit = "Edit"
        case hosts = "Hosts"
        case invitations = "Invites"
        case attendees = "Attendees"
        case analytics = "Analytics"
        var id: String { rawValue }
    }

    let event: VibeEventDetailModel
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .edit

    var body: some View {
        VStack(spacing: 0) {
            Picker("Event management", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()
            Group {
                switch tab {
                case .edit:
                    VibeEventCreatorView(
                        onCreated: { _ in onSaved() },
                        preselectedVibeSlug: event.club.slug,
                        editEvent: event
                    )
                case .hosts:
                    VibeEventHostsManager(slug: event.slug)
                case .invitations:
                    VibeEventInvitesManager(slug: event.slug)
                case .attendees:
                    VibeEventAttendeesManager(slug: event.slug)
                case .analytics:
                    VibeEventAnalyticsManager(slug: event.slug)
                }
            }
        }
        .background(C.bg)
        .navigationTitle("Manage Event")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }.foregroundStyle(C.watch)
            }
        }
    }
}

private struct VibeEventAnalyticsManager: View {
    let slug: String
    @State private var analytics: VibeEventAnalyticsSummary?
    @State private var loading = true
    @State private var errorMessage: String?

    private var metrics: [(String, Int, String)] {
        guard let analytics else { return [] }
        return [
            ("Views", analytics.viewCount, "eye"),
            ("Joins", analytics.joinCount, "video.fill"),
            ("Going", analytics.goingCount, "person.2.fill"),
            ("Interested", analytics.interestedCount, "star.fill"),
            ("Waitlisted", analytics.waitlistCount, "clock.fill"),
            ("Comments", analytics.commentCount, "bubble.left.fill"),
            ("Echoes", analytics.echoCount, "wave.3.right"),
            ("Energy", analytics.energyCount, "bolt.fill")
        ]
    }

    var body: some View {
        ScrollView {
            if loading {
                ProgressView("Loading analytics…")
                    .tint(C.watch)
                    .padding(.top, 80)
            } else if let errorMessage {
                ContentUnavailableView(
                    "Analytics unavailable",
                    systemImage: "chart.bar.xaxis",
                    description: Text(errorMessage)
                )
                .foregroundStyle(C.text)
                .padding(.top, 60)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(metrics, id: \.0) { metric in
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: metric.2).foregroundStyle(C.watch)
                            Text(metric.1.formatted())
                                .font(.title2.bold())
                                .foregroundStyle(C.text)
                            Text(metric.0.uppercased())
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(C.textMuted)
                        }
                        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
                        .padding(14)
                        .background(C.surface, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(C.borderSubtle))
                    }
                }
                .padding(C.pagePad)
            }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    @MainActor private func load() async {
        loading = analytics == nil
        do {
            analytics = try await APIClient.shared.fetchVibeEventAnalytics(slug: slug)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }
}

private struct VibeEventHostsManager: View {
    let slug: String
    @State private var hosts = [VibeEventHostModel]()
    @State private var query = ""
    @State private var results = [SearchResultPerson]()
    @State private var role = "CO_HOST"
    @State private var loading = true
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section("Current hosts") {
                if loading { ProgressView() }
                else if hosts.isEmpty { Text("No hosts have been assigned.").foregroundStyle(C.textMuted) }
                ForEach(hosts) { host in
                    HStack {
                        SocialIdentityAvatar(image: host.user.image, name: host.user.name ?? host.user.handle, size: 38)
                        VStack(alignment: .leading) {
                            Text(host.user.name ?? host.user.handle ?? "Host")
                            Text(host.role.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(.caption).foregroundStyle(C.textMuted)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            Task { await remove(host.user.id) }
                        } label: { Image(systemName: "trash") }
                    }
                }
            }
            Section("Add a host or co-host") {
                Picker("Role", selection: $role) {
                    Text("Host").tag("HOST")
                    Text("Co-host").tag("CO_HOST")
                    Text("Speaker").tag("SPEAKER")
                    Text("Moderator").tag("MODERATOR")
                }
                TextField("Search people", text: $query)
                    .textInputAutocapitalization(.never)
                    .onSubmit { Task { await search() } }
                    .task(id: query) {
                        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard cleaned.count >= 2 else {
                            results = []
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled else { return }
                        await search()
                    }
                ForEach(results) { person in
                    Button {
                        Task { await add(person.id) }
                    } label: {
                        HStack {
                            SocialIdentityAvatar(image: person.image, name: person.name ?? person.handle, size: 36)
                            Text(person.name ?? person.handle ?? "Person")
                            Spacer()
                            Image(systemName: "plus.circle.fill").foregroundStyle(C.watch)
                        }
                    }
                    .disabled(busy)
                }
            }
            if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
        }
        .scrollContentBackground(.hidden)
        .task { await load() }
    }

    @MainActor private func load() async {
        loading = true
        do { hosts = try await APIClient.shared.fetchVibeEventHosts(slug: slug); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
        loading = false
    }
    @MainActor private func search() async {
        do { results = try await APIClient.shared.search(q: query, type: "people").people ?? [] }
        catch { errorMessage = error.localizedDescription }
    }
    @MainActor private func add(_ userID: String) async {
        busy = true
        do { try await APIClient.shared.addVibeEventHost(slug: slug, userID: userID, role: role); await load(); results = [] }
        catch { errorMessage = error.localizedDescription }
        busy = false
    }
    @MainActor private func remove(_ userID: String) async {
        busy = true
        do { try await APIClient.shared.removeVibeEventHost(slug: slug, userID: userID); await load() }
        catch { errorMessage = error.localizedDescription }
        busy = false
    }
}

private struct VibeEventInvitesManager: View {
    let slug: String
    @State private var invites = [VibeEventInviteModel]()
    @State private var email = ""
    @State private var maxUses = 1
    @State private var hasExpiration = true
    @State private var expiration = Date().addingTimeInterval(7 * 86_400)
    @State private var latestInviteURL: String?
    @State private var loading = true
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section("New invitation") {
                TextField("Email address", text: $email)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                Stepper("Maximum uses: \(maxUses)", value: $maxUses, in: 1...1000)
                Toggle("Expires", isOn: $hasExpiration)
                if hasExpiration { DatePicker("Expiration", selection: $expiration, in: Date()...) }
                Button("Create invitation") { Task { await create() } }
                    .disabled(busy || !email.contains("@"))
                if let latestInviteURL, let url = URL(string: C.baseURL + latestInviteURL) {
                    ShareLink(item: url) { Label("Share invitation", systemImage: "square.and.arrow.up") }
                }
            }
            Section("Invitations") {
                if loading { ProgressView() }
                else if invites.isEmpty { Text("No invitations yet.").foregroundStyle(C.textMuted) }
                ForEach(invites) { invite in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(invite.invitedUser?.name ?? invite.invitedEmail ?? "Invitation")
                            Text("\(invite.status.capitalized) · \(invite.useCount)/\(invite.maxUses) used")
                                .font(.caption).foregroundStyle(C.textMuted)
                        }
                        Spacer()
                        if invite.status != "REVOKED" {
                            Button(role: .destructive) { Task { await revoke(invite.id) } } label: {
                                Image(systemName: "xmark.circle")
                            }
                        }
                    }
                }
            }
            if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
        }
        .scrollContentBackground(.hidden)
        .task { await load() }
    }

    @MainActor private func load() async {
        loading = true
        do { invites = try await APIClient.shared.fetchVibeEventInvites(slug: slug); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
        loading = false
    }
    @MainActor private func create() async {
        busy = true
        do {
            let result = try await APIClient.shared.createVibeEventInvite(
                slug: slug,
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                expiresAt: hasExpiration ? ISO8601DateFormatter.vibeEvent.string(from: expiration) : nil,
                maxUses: maxUses
            )
            latestInviteURL = result.inviteUrl
            email = ""
            await load()
        } catch { errorMessage = error.localizedDescription }
        busy = false
    }
    @MainActor private func revoke(_ id: String) async {
        do { try await APIClient.shared.revokeVibeEventInvite(slug: slug, inviteID: id); await load() }
        catch { errorMessage = error.localizedDescription }
    }
}

private struct VibeEventAttendeesManager: View {
    let slug: String
    @State private var status = "ALL"
    @State private var attendees = [VibeEventAttendeeModel]()
    @State private var loading = true
    @State private var errorMessage: String?
    private let statuses = ["ALL", "GOING", "INTERESTED", "WAITLISTED", "NOT_GOING", "CANCELLED"]

    var body: some View {
        List {
            Section {
                Picker("RSVP status", selection: $status) {
                    ForEach(statuses, id: \.self) {
                        Text($0.replacingOccurrences(of: "_", with: " ").capitalized).tag($0)
                    }
                }
            }
            Section("Attendees") {
                if loading { ProgressView() }
                else if attendees.isEmpty { Text("No attendees in this group.").foregroundStyle(C.textMuted) }
                ForEach(attendees) { attendee in
                    HStack {
                        SocialIdentityAvatar(image: attendee.user.image, name: attendee.user.name ?? attendee.user.handle, size: 38)
                        VStack(alignment: .leading) {
                            Text(attendee.user.name ?? attendee.user.handle ?? "Attendee")
                            Text(attendee.status.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(.caption).foregroundStyle(C.textMuted)
                        }
                    }
                }
            }
            if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
        }
        .scrollContentBackground(.hidden)
        .task(id: status) { await load() }
    }

    @MainActor private func load() async {
        loading = true
        do {
            attendees = try await APIClient.shared.fetchVibeEventAttendees(
                slug: slug,
                status: status == "ALL" ? nil : status
            )
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
        loading = false
    }
}
