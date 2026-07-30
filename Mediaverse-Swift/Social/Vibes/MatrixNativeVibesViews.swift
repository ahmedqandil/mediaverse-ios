import Contacts
import CryptoKit
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Matrix-authoritative Vibes entry point.
///
/// This surface intentionally has no legacy social or handwritten Matrix
/// fallback. If the native rollout/session is unavailable it fails closed and
/// leaves Personal Atmo and The Atmosphere untouched.
struct MatrixNativeVibesRootView: View {
    @EnvironmentObject private var matrixSession: MatrixNativeSessionController
    @State private var spaces: [MatrixVibeSummary] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var pendingInvitationID: String?
    @State private var routedRoom: MatrixWaveSummary?
    @State private var showsPublicDirectory = false
    @State private var showsCreateVibe = false
    @State private var showsSecurity = false

    var body: some View {
        Group {
            if !matrixSession.isReady {
                MatrixNativeSessionGateView(
                    state: matrixSession.lifecycleState,
                    retry: {
                        Task { await matrixSession.retryConnection() }
                    }
                )
            } else if isLoading, spaces.isEmpty {
                MatrixNativeLoadingView(title: "Loading Vibes")
            } else if let errorMessage, spaces.isEmpty {
                MatrixNativeUnavailableView(
                    title: "Vibes unavailable",
                    message: errorMessage,
                    retry: { Task { await load() } }
                )
            } else if spaces.isEmpty {
                ContentUnavailableView {
                    Label("No Vibes yet", systemImage: "person.3.sequence")
                } description: {
                    Text("Vibes you join or are invited to will appear here.")
                }
                .foregroundStyle(C.text)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        MatrixNativeDirectoryHeader(
                            eyebrow: "WESTREEM VIBES",
                            title: "Your Vibes",
                            message: "Spaces and invitations synchronized securely by Vibes."
                        )

                        NavigationLink {
                            MatrixNativeDirectMessagesView()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "bubble.left.and.bubble.right.fill")
                                    .font(.headline)
                                    .foregroundStyle(C.watch)
                                    .frame(width: 42, height: 42)
                                    .background(C.watch.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Messages")
                                        .font(.headline)
                                        .foregroundStyle(C.text)
                                    Text("Private conversations powered by Vibes")
                                        .font(.caption)
                                        .foregroundStyle(C.textMuted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.bold())
                                    .foregroundStyle(C.textTertiary)
                            }
                            .padding(12)
                            .background(C.surface, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(C.borderSubtle))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        let invitations = spaces.filter { $0.membership == .invited }
                        if !invitations.isEmpty {
                            MatrixNativeSectionLabel(title: "Invitations", count: invitations.count)
                            ForEach(invitations) { space in
                                MatrixNativeInvitationRow(
                                    space: space,
                                    isBusy: pendingInvitationID == space.id,
                                    accept: { Task { await respond(to: space, accept: true) } },
                                    decline: { Task { await respond(to: space, accept: false) } }
                                )
                            }
                        }

                        let joined = spaces.filter { $0.membership == .joined }
                        if !joined.isEmpty {
                            MatrixNativeSectionLabel(title: "Vibes", count: joined.count)
                            ForEach(joined) { space in
                                NavigationLink {
                                    MatrixNativeVibeView(space: space)
                                } label: {
                                    MatrixNativeSpaceRow(space: space)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if let errorMessage {
                            Label(errorMessage, systemImage: "wifi.exclamationmark")
                                .font(.footnote)
                                .foregroundStyle(C.textMuted)
                                .padding(.top, 4)
                        }
                    }
                    .padding(.horizontal, C.pagePad)
                    .padding(.top, 18)
                    .padding(.bottom, 110)
                }
                .refreshable { await load() }
            }
        }
        .background(C.bg.ignoresSafeArea())
        .navigationTitle("Vibes")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $routedRoom) { room in
            MatrixNativeWaveRoomView(room: room)
        }
        .navigationDestination(isPresented: $showsPublicDirectory) {
            MatrixNativePublicVibeDirectoryView {
                Task { await load() }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showsSecurity = true
                } label: {
                    Image(systemName: "lock.shield")
                }
                .accessibilityLabel("Vibes security and recovery")

                Button {
                    showsPublicDirectory = true
                } label: {
                    Image(systemName: "safari")
                }
                .accessibilityLabel("Discover public Vibes")

                Button {
                    showsCreateVibe = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Create Vibe")
                .disabled(!matrixSession.isReady)
            }
        }
        .sheet(isPresented: $showsCreateVibe) {
            MatrixNativeRoomCreatorView(mode: .vibe) { _ in
                showsCreateVibe = false
                await load()
            }
            .environmentObject(matrixSession)
        }
        .sheet(isPresented: $showsSecurity) {
            MatrixNativeCryptoSecurityView()
                .environmentObject(matrixSession)
        }
        .task(id: matrixSession.isReady) {
            guard matrixSession.isReady else { return }
            await load()
            await openPendingPushRoute()
        }
        .onReceive(NotificationCenter.default.publisher(for: .matrixRoomRouteRequested)) { notification in
            guard let route = notification.object as? MatrixNativePushRoute else { return }
            Task { await open(route) }
        }
    }

    @MainActor
    private func load() async {
        isLoading = true
        do {
            spaces = try await matrixSession.vibes().spaces
            errorMessage = nil
        } catch {
            errorMessage = MatrixNativeCopy.message(for: error)
        }
        isLoading = false
    }

    @MainActor
    private func respond(to space: MatrixVibeSummary, accept: Bool) async {
        guard pendingInvitationID == nil else { return }
        pendingInvitationID = space.id
        do {
            if accept {
                try await matrixSession.acceptInvite(roomID: space.id)
            } else {
                try await matrixSession.declineInvite(roomID: space.id)
            }
            await load()
        } catch {
            errorMessage = MatrixNativeCopy.message(for: error)
        }
        pendingInvitationID = nil
    }

    @MainActor
    private func openPendingPushRoute() async {
        guard let route = MatrixNativePushRouteStore.shared.consume() else { return }
        await open(route)
    }

    @MainActor
    private func open(_ route: MatrixNativePushRoute) async {
        do {
            routedRoom = try await matrixSession.matrixRoomSummary(roomID: route.roomID)
        } catch {
            errorMessage = "The Vibes conversation from this notification is not available."
        }
    }
}

private struct MatrixNativeVibeView: View {
    let space: MatrixVibeSummary

    @EnvironmentObject private var matrixSession: MatrixNativeSessionController
    @Environment(\.scenePhase) private var scenePhase
    @State private var rooms: [MatrixWaveSummary] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var permissions = MatrixNativeSpacePermissionSnapshot.unavailable
    @State private var showsCreateWave = false
    @State private var showsCreateEvent = false
    @State private var showsInvitations = false
    @State private var showsAffiliations = false

    var body: some View {
        let activeLounges = rooms.filter {
            !$0.isNestedSpace && $0.activeCallParticipantCount > 0
        }
        Group {
            if isLoading, rooms.isEmpty {
                MatrixNativeLoadingView(title: "Loading Waves")
            } else if let errorMessage, rooms.isEmpty {
                MatrixNativeUnavailableView(
                    title: "Waves unavailable",
                    message: errorMessage,
                    retry: { Task { await load() } }
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        MatrixNativeVibeHero(
                            space: space,
                            rooms: rooms,
                            permissions: permissions
                        )
                        if !activeLounges.isEmpty {
                            MatrixNativeSectionLabel(
                                title: "Live lounges",
                                count: activeLounges.count
                            )
                            ForEach(activeLounges) { room in
                                NavigationLink {
                                    MatrixNativeWaveRoomView(
                                        room: room,
                                        opensLiveLounge: true
                                    )
                                } label: {
                                    MatrixNativeLiveLoungeRow(room: room)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        MatrixNativeSectionLabel(title: "Waves", count: rooms.count)

                        if rooms.isEmpty {
                            ContentUnavailableView {
                                Label("No Waves", systemImage: "wave.3.right")
                            } description: {
                                Text("This Vibe does not have any visible rooms yet.")
                            }
                            .foregroundStyle(C.text)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 42)
                        } else {
                            ForEach(rooms) { room in
                                if room.isNestedSpace {
                                    NavigationLink {
                                        MatrixNativeNestedSpaceView(room: room)
                                    } label: {
                                        MatrixNativeWaveRow(room: room)
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    NavigationLink {
                                        MatrixNativeWaveRoomView(room: room)
                                    } label: {
                                        MatrixNativeWaveRow(room: room)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, C.pagePad)
                    .padding(.top, 12)
                    .padding(.bottom, 110)
                }
                .refreshable { await load() }
            }
        }
        .background(C.bg.ignoresSafeArea())
        .navigationTitle(space.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if permissions.mayOpenVibeManagement {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if permissions.mayCreateWave {
                            Button {
                                showsCreateWave = true
                            } label: {
                                Label("Create Wave", systemImage: "plus.bubble")
                            }
                        }
                        if permissions.isJoined {
                            Button {
                                showsCreateEvent = true
                            } label: {
                                Label("Create Event", systemImage: "calendar.badge.plus")
                            }
                        }
                        if permissions.mayInviteMembers {
                            Button {
                                showsInvitations = true
                            } label: {
                                Label("Invite people", systemImage: "person.badge.plus")
                            }
                        }
                        if permissions.isJoined {
                            Button {
                                showsAffiliations = true
                            } label: {
                                Label("Show & Channel affiliations", systemImage: "link")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Vibe management")
                }
            }
        }
        .sheet(isPresented: $showsCreateWave) {
            MatrixNativeRoomCreatorView(mode: .wave(parentSpaceID: space.id)) { _ in
                showsCreateWave = false
                await load()
            }
            .environmentObject(matrixSession)
        }
        .sheet(isPresented: $showsCreateEvent) {
            NavigationStack {
                VibeEventCreatorView(
                    onCreated: { _ in showsCreateEvent = false },
                    preselectedMatrixSpaceID: space.id
                )
                .environmentObject(matrixSession)
            }
        }
        .sheet(isPresented: $showsInvitations) {
            NavigationStack {
                MatrixNativeInviteUsersView(
                    roomID: space.id,
                    destinationName: space.name,
                    destinationType: .vibe
                )
                    .environmentObject(matrixSession)
            }
        }
        .sheet(isPresented: $showsAffiliations) {
            MatrixNativeVibeAffiliationsView(
                matrixSpaceID: space.id,
                vibeName: space.name
            )
        }
        .task(id: space.id) { await load() }
        .task(id: "\(space.id):\(scenePhase)") {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(20))
                    let latest = try await matrixSession
                        .refreshLocalWaveActivity(rooms: rooms)
                    guard !Task.isCancelled else { return }
                    rooms = latest
                } catch is CancellationError {
                    return
                } catch {
                    // The normal load/retry surface owns errors. This loop only
                    // keeps local Matrix call-state badges fresh in foreground.
                }
            }
        }
    }

    @MainActor
    private func load() async {
        isLoading = true
        do {
            rooms = try await matrixSession.waves(spaceID: space.id).rooms
            permissions = try await matrixSession.spacePermissions(spaceID: space.id)
            errorMessage = nil
        } catch {
            permissions = .unavailable
            errorMessage = MatrixNativeCopy.message(for: error)
        }
        isLoading = false
    }
}

private struct MatrixNativeVibeAffiliationsView: View {
    let matrixSpaceID: String
    let vibeName: String

    @Environment(\.dismiss) private var dismiss
    @State private var affiliations: [MatrixVibeAffiliationRecord] = []
    @State private var targetType = MatrixVibeAffiliationEntityType.show
    @State private var query = ""
    @State private var targets: [MatrixVibeAffiliationTarget] = []
    @State private var selectedTarget: MatrixVibeAffiliationTarget?
    @State private var requestNote = ""
    @State private var isLoading = true
    @State private var isSearching = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Affiliations")
                            .font(.title2.bold())
                            .foregroundStyle(C.text)
                        Text("Request a reviewed relationship between \(vibeName) and a WeStreem Show or Channel.")
                            .font(.footnote)
                            .foregroundStyle(C.textMuted)
                    }

                    if isLoading, affiliations.isEmpty {
                        ProgressView("Loading affiliation status…")
                            .tint(C.watch)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else if affiliations.isEmpty {
                        ContentUnavailableView {
                            Label("No affiliation requests", systemImage: "link")
                        } description: {
                            Text("Search below to request the first one.")
                        }
                        .foregroundStyle(C.text)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    } else {
                        MatrixNativeSectionLabel(
                            title: "Current status",
                            count: affiliations.count
                        )
                        ForEach(affiliations) { affiliation in
                            MatrixNativeAffiliationStatusRow(
                                affiliation: affiliation
                            )
                        }
                    }

                    Divider().overlay(C.borderSubtle)
                    Text("Request affiliation")
                        .font(.headline)
                        .foregroundStyle(C.text)

                    Picker("Destination type", selection: $targetType) {
                        ForEach(MatrixVibeAffiliationEntityType.allCases, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextField(
                        "Search \(targetType.label.lowercased())s",
                        text: $query
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(C.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(C.borderSubtle))
                    .accessibilityLabel("Search \(targetType.label)s")

                    if isSearching {
                        ProgressView().tint(C.watch).frame(maxWidth: .infinity)
                    } else {
                        ForEach(targets) { target in
                            Button {
                                selectedTarget = target
                                requestNote = ""
                            } label: {
                                HStack(spacing: 11) {
                                    MatrixNativeAvatar(name: target.name, size: 38)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(target.name)
                                            .font(.subheadline.bold())
                                            .foregroundStyle(C.text)
                                        if let handle = target.handle, !handle.isEmpty {
                                            Text("@\(handle)")
                                                .font(.caption)
                                                .foregroundStyle(C.textMuted)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.bold())
                                        .foregroundStyle(C.textTertiary)
                                }
                                .padding(11)
                                .background(
                                    C.surface,
                                    in: RoundedRectangle(cornerRadius: 12)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .padding(C.pagePad)
                .padding(.bottom, 40)
            }
            .background(C.bg.ignoresSafeArea())
            .navigationTitle("Vibe affiliations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $selectedTarget) { target in
                MatrixNativeAffiliationRequestSheet(
                    target: target,
                    note: $requestNote,
                    isSubmitting: isSubmitting,
                    errorMessage: errorMessage,
                    submit: { Task { await submit(target) } },
                    cancel: { selectedTarget = nil }
                )
                .presentationDetents([.medium])
            }
        }
        .task(id: matrixSpaceID) { await load() }
        .task(id: "\(targetType.rawValue):\(query)") {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await search()
        }
    }

    @MainActor
    private func load() async {
        isLoading = true
        do {
            affiliations = try await APIClient.shared.matrixVibeAffiliations(
                matrixSpaceID: matrixSpaceID
            )
            errorMessage = nil
        } catch {
            // The endpoint enforces the live Matrix power level. A missing
            // rollout or insufficient role is intentionally not bypassed.
            errorMessage = MatrixNativeCopy.message(for: error)
        }
        isLoading = false
    }

    @MainActor
    private func search() async {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 2 else {
            targets = []
            isSearching = false
            return
        }
        isSearching = true
        do {
            targets = try await APIClient.shared.matrixVibeAffiliationTargets(
                matrixSpaceID: matrixSpaceID,
                type: targetType,
                query: normalized
            )
            errorMessage = nil
        } catch {
            targets = []
            errorMessage = MatrixNativeCopy.message(for: error)
        }
        isSearching = false
    }

    @MainActor
    private func submit(_ target: MatrixVibeAffiliationTarget) async {
        guard !isSubmitting else { return }
        isSubmitting = true
        do {
            _ = try await APIClient.shared.requestMatrixVibeAffiliation(
                matrixSpaceID: matrixSpaceID,
                target: target,
                note: requestNote
            )
            selectedTarget = nil
            query = ""
            targets = []
            errorMessage = nil
            await load()
        } catch {
            errorMessage = MatrixNativeCopy.message(for: error)
        }
        isSubmitting = false
    }
}

private struct MatrixNativeAffiliationStatusRow: View {
    let affiliation: MatrixVibeAffiliationRecord

    private var statusColor: Color {
        switch affiliation.status {
        case "APPROVED": C.watch
        case "PENDING": .orange
        case "REJECTED", "REVOKED": .red
        default: C.textMuted
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                MatrixNativeAvatar(name: affiliation.destinationName, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(affiliation.destinationName)
                        .font(.subheadline.bold())
                        .foregroundStyle(C.text)
                    Text(affiliation.entityType.label)
                        .font(.caption)
                        .foregroundStyle(C.textMuted)
                }
                Spacer()
                Text(affiliation.status.capitalized)
                    .font(.caption2.bold())
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        statusColor.opacity(0.12),
                        in: Capsule()
                    )
            }
            if let note = affiliation.reviewNote, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(C.textMuted)
            }
        }
        .padding(12)
        .background(C.surface, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(C.borderSubtle))
        .accessibilityElement(children: .combine)
    }
}

private struct MatrixNativeAffiliationRequestSheet: View {
    let target: MatrixVibeAffiliationTarget
    @Binding var note: String
    let isSubmitting: Bool
    let errorMessage: String?
    let submit: () -> Void
    let cancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Destination") {
                    Text(target.name)
                    if let handle = target.handle, !handle.isEmpty {
                        Text("@\(handle)").foregroundStyle(.secondary)
                    }
                }
                Section("Optional note") {
                    TextField("Why should these be affiliated?", text: $note, axis: .vertical)
                        .lineLimit(3...7)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Request affiliation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel).disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSubmitting ? "Sending…" : "Send", action: submit)
                        .disabled(isSubmitting)
                }
            }
        }
    }
}

private struct MatrixNativeNestedSpaceView: View {
    let room: MatrixWaveSummary

    @EnvironmentObject private var matrixSession: MatrixNativeSessionController
    @State private var children: [MatrixWaveSummary] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading, children.isEmpty {
                MatrixNativeLoadingView(title: "Loading rooms")
            } else if let errorMessage, children.isEmpty {
                MatrixNativeUnavailableView(
                    title: "Rooms unavailable",
                    message: errorMessage,
                    retry: { Task { await load() } }
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(children) { child in
                            NavigationLink {
                                if child.isNestedSpace {
                                    MatrixNativeNestedSpaceView(room: child)
                                } else {
                                    MatrixNativeWaveRoomView(room: child)
                                }
                            } label: {
                                MatrixNativeWaveRow(room: child)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(C.pagePad)
                    .padding(.bottom, 100)
                }
                .refreshable { await load() }
            }
        }
        .background(C.bg.ignoresSafeArea())
        .navigationTitle(room.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: room.id) { await load() }
    }

    @MainActor
    private func load() async {
        isLoading = true
        do {
            children = try await matrixSession.waves(spaceID: room.id).rooms
            errorMessage = nil
        } catch {
            errorMessage = MatrixNativeCopy.message(for: error)
        }
        isLoading = false
    }
}

private struct MatrixNativePublicVibeDirectoryView: View {
    let onMembershipChanged: @MainActor () -> Void

    @EnvironmentObject private var matrixSession: MatrixNativeSessionController
    @State private var query = ""
    @State private var page: MatrixPublicVibeDirectoryPage?
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var joiningID: String?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading, page == nil {
                MatrixNativeLoadingView(title: "Discovering public Vibes")
            } else if let errorMessage, page == nil {
                MatrixNativeUnavailableView(
                    title: "Directory unavailable",
                    message: errorMessage,
                    retry: { Task { await search() } }
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        MatrixNativeDirectoryHeader(
                            eyebrow: "PUBLIC VIBES",
                            title: "Discover Vibes",
                            message: "Search the homeserver directory and join public communities."
                        )

                        if page?.spaces.isEmpty != false {
                            ContentUnavailableView {
                                Label("No public Vibes found", systemImage: "safari")
                            } description: {
                                Text("Try another search or browse again later.")
                            }
                            .foregroundStyle(C.text)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 50)
                        } else {
                            ForEach(page?.spaces ?? []) { space in
                                publicSpaceRow(space)
                            }
                        }

                        if page?.hasMore == true {
                            Button {
                                Task { await loadMore() }
                            } label: {
                                HStack {
                                    Spacer()
                                    if isLoadingMore {
                                        ProgressView().tint(C.watch)
                                    } else {
                                        Label("Load more Vibes", systemImage: "arrow.down")
                                    }
                                    Spacer()
                                }
                                .padding(12)
                            }
                            .buttonStyle(.bordered)
                            .tint(C.watch)
                            .disabled(isLoadingMore)
                        }

                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(C.textMuted)
                        }
                    }
                    .padding(.horizontal, C.pagePad)
                    .padding(.top, 16)
                    .padding(.bottom, 100)
                }
                .refreshable { await search() }
            }
        }
        .background(C.bg.ignoresSafeArea())
        .navigationTitle("Discover Vibes")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search public Vibes")
        .onSubmit(of: .search) { Task { await search() } }
        .task { await search() }
    }

    @ViewBuilder
    private func publicSpaceRow(_ space: MatrixPublicVibeSummary) -> some View {
        HStack(alignment: .top, spacing: 12) {
            MatrixNativeAvatar(
                name: space.name,
                imageURL: space.avatarURL,
                size: 48
            )
            VStack(alignment: .leading, spacing: 5) {
                Text(space.name)
                    .font(.headline)
                    .foregroundStyle(C.text)
                if let topic = space.topic, !topic.isEmpty {
                    Text(topic)
                        .font(.caption)
                        .foregroundStyle(C.textMuted)
                        .lineLimit(3)
                }
                Label(
                    "\(space.joinedMemberCount) members",
                    systemImage: "person.2"
                )
                .font(.caption2)
                .foregroundStyle(C.textTertiary)
            }
            Spacer(minLength: 8)
            if space.membership == .joined {
                Text("Joined")
                    .font(.caption.bold())
                    .foregroundStyle(C.watch)
            } else if space.mayJoin {
                Button(joiningID == space.id ? "Joining…" : "Join") {
                    Task { await join(space) }
                }
                .buttonStyle(.borderedProminent)
                .tint(C.watch)
                .disabled(joiningID != nil)
                .accessibilityLabel("Join \(space.name)")
            } else {
                Text("Invite only")
                    .font(.caption)
                    .foregroundStyle(C.textMuted)
            }
        }
        .padding(13)
        .background(C.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(C.borderSubtle))
    }

    @MainActor
    private func search() async {
        isLoading = true
        do {
            page = try await matrixSession.publicVibes(query: query)
            errorMessage = nil
        } catch {
            errorMessage = MatrixNativeCopy.message(for: error)
        }
        isLoading = false
    }

    @MainActor
    private func loadMore() async {
        guard !isLoadingMore else { return }
        isLoadingMore = true
        do {
            page = try await matrixSession.publicVibes(
                query: query,
                loadNextPage: true
            )
            errorMessage = nil
        } catch {
            errorMessage = MatrixNativeCopy.message(for: error)
        }
        isLoadingMore = false
    }

    @MainActor
    private func join(_ space: MatrixPublicVibeSummary) async {
        guard joiningID == nil else { return }
        joiningID = space.id
        do {
            try await matrixSession.joinPublicVibe(space)
            onMembershipChanged()
            await search()
        } catch {
            errorMessage = MatrixNativeCopy.message(for: error)
        }
        joiningID = nil
    }
}

private enum MatrixNativeRoomCreatorMode {
    case vibe
    case wave(parentSpaceID: String)

    var title: String {
        switch self {
        case .vibe: "Create Vibe"
        case .wave: "Create Wave"
        }
    }

    var noun: String {
        switch self {
        case .vibe: "Vibe"
        case .wave: "Wave"
        }
    }

    var isWave: Bool {
        if case .wave = self { return true }
        return false
    }
}

private struct MatrixNativeRoomCreatorView: View {
    let mode: MatrixNativeRoomCreatorMode
    let onCreated: @MainActor (MatrixNativeCreatedRoom) async -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var matrixSession: MatrixNativeSessionController
    @State private var name = ""
    @State private var topic = ""
    @State private var visibility = MatrixNativeVibeVisibility.publicVibe
    @State private var invitationText = ""
    @State private var encryptWave = false
    @State private var showsSecuritySetup = false
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var partialResult: MatrixNativeCreatedRoom?

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isCreating
            && matrixSession.isReady
    }

    var body: some View {
        NavigationStack {
            Form {
                if !matrixSession.isReady {
                    Section {
                        Button("Reconnect to Vibes") {
                            Task { await matrixSession.retryConnection() }
                        }
                    } header: {
                        Text("Connection")
                    } footer: {
                        Text(
                            "Creating becomes available as soon as your secure Vibes session reconnects."
                        )
                    }
                }
                Section("Identity") {
                    TextField("\(mode.noun) name", text: $name)
                    TextField("Description", text: $topic, axis: .vertical)
                        .lineLimit(3...6)
                }
                Section {
                    Picker("Visibility", selection: $visibility) {
                        Text("Public").tag(MatrixNativeVibeVisibility.publicVibe)
                        Text("Invite only").tag(MatrixNativeVibeVisibility.privateVibe)
                    }
                } header: {
                    Text("Access")
                } footer: {
                    Text(
                        visibility == .publicVibe
                            ? "Public \(mode.noun)s can be listed and joined through WeStreem."
                            : "Only invited WeStreem users can join."
                    )
                }
                if mode.isWave, visibility == .privateVibe {
                    Section {
                        Toggle("End-to-end encrypt this Wave", isOn: $encryptWave)
                    } footer: {
                        Text(
                            "Encrypted Waves stay private and cannot use public discovery, curation, sharing bridges, moderation projections, or Lounges. This cannot be undone."
                        )
                    }
                }
                Section {
                    TextEditor(text: $invitationText)
                        .frame(minHeight: 90)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Initial invitations")
                } footer: {
                    Text("Optional WeStreem member IDs, separated by commas or new lines.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(C.bg)
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isCreating ? "Creating…" : "Create") {
                        Task { await create() }
                    }
                    .disabled(!canCreate)
                }
            }
            .alert(
                "Could not create \(mode.noun)",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .alert(
                "\(mode.noun) created",
                isPresented: Binding(
                    get: { partialResult != nil },
                    set: { if !$0 { partialResult = nil } }
                )
            ) {
                Button("Done") {
                    guard let result = partialResult else { return }
                    partialResult = nil
                    Task {
                        await onCreated(result)
                        dismiss()
                    }
                }
                if partialResult?.registrationPending == true {
                    Button("Retry setup") {
                        Task { await retryRegistration() }
                    }
                }
            } message: {
                if partialResult?.registrationPending == true {
                    Text(
                        "The Wave exists, but WeStreem has not verified it for search, curation and operations yet. Retry setup without creating another \(mode.noun.lowercased())."
                    )
                } else {
                    Text(
                        "The \(mode.noun) is ready, but these invitations failed: "
                            + (partialResult?.failedInvitationUserIDs.joined(separator: ", ") ?? "")
                    )
                }
            }
            .sheet(isPresented: $showsSecuritySetup) {
                MatrixNativeCryptoSecurityView(
                    requiredForAction: true,
                    onReady: {
                        showsSecuritySetup = false
                        Task { await create() }
                    }
                )
                .environmentObject(matrixSession)
            }
        }
    }

    @MainActor
    private func create() async {
        guard !isCreating else { return }
        isCreating = true
        defer { isCreating = false }
        let draft = MatrixNativeRoomCreationDraft(
            name: name,
            topic: topic,
            visibility: visibility,
            inviteUserIDs: MatrixNativeCreationContract.parseInviteUserIDs(
                invitationText
            ),
            isEncrypted: mode.isWave
                && visibility == .privateVibe
                && encryptWave
        )
        do {
            let result: MatrixNativeCreatedRoom
            switch mode {
            case .vibe:
                result = try await matrixSession.createVibe(draft)
            case let .wave(parentSpaceID):
                result = try await matrixSession.createWave(
                    inSpaceID: parentSpaceID,
                    draft: draft
                )
            }
            if result.failedInvitationUserIDs.isEmpty
                && !result.registrationPending {
                await onCreated(result)
                dismiss()
            } else {
                partialResult = result
            }
        } catch let error as MatrixNativeCryptoSecurityError
            where error.requiresGuidedRecovery {
            showsSecuritySetup = true
        } catch {
            errorMessage = MatrixNativeCopy.message(for: error)
        }
    }

    @MainActor
    private func retryRegistration() async {
        guard let partialResult, partialResult.registrationPending else { return }
        isCreating = true
        defer { isCreating = false }
        do {
            let registered = try await matrixSession.registerCreatedRoom(
                partialResult
            )
            self.partialResult = registered
            if registered.failedInvitationUserIDs.isEmpty {
                await onCreated(registered)
                dismiss()
            }
        } catch {
            errorMessage = MatrixNativeCopy.message(for: error)
        }
    }
}

private enum WestreemContactsAccessState: Equatable {
    case notRequested
    case loading
    case authorized
    case limited
    case denied
    case restricted
    case failed(String)
}

private struct WestreemLocalContact: Identifiable, Hashable {
    let id: String
    let displayName: String
    let emailHashes: [String]
    let phoneHashes: [String]
}

private enum WestreemContactPrivacy {
    static func contactsAccessState() -> WestreemContactsAccessState {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .authorized { return .authorized }
        if status == .denied { return .denied }
        if status == .restricted { return .restricted }
        if status == .notDetermined { return .notRequested }
        if #available(iOS 18.0, *), status == .limited { return .limited }
        return .failed("Contacts access is unavailable.")
    }

    static func requestAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            CNContactStore().requestAccess(for: .contacts) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    static func loadContacts() async throws -> [WestreemLocalContact] {
        try await Task.detached(priority: .userInitiated) {
            let keys: [CNKeyDescriptor] = [
                CNContactIdentifierKey as CNKeyDescriptor,
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactOrganizationNameKey as CNKeyDescriptor,
                CNContactEmailAddressesKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor,
            ]
            let request = CNContactFetchRequest(keysToFetch: keys)
            request.unifyResults = true
            var values: [WestreemLocalContact] = []
            var emailHashCount = 0
            var phoneHashCount = 0
            try CNContactStore().enumerateContacts(with: request) { contact, stop in
                let emailHashes = contact.emailAddresses.compactMap {
                    WestreemVibeContactDiscoveryContract.normalizedEmail(
                        $0.value as String
                    )
                }
                .map(digest)
                .filter { _ in
                    guard emailHashCount
                            < WestreemVibeContactDiscoveryContract.maximumHashesPerKind
                    else { return false }
                    emailHashCount += 1
                    return true
                }
                let phoneHashes = contact.phoneNumbers.compactMap {
                    WestreemVibeContactDiscoveryContract.normalizedPhone(
                        $0.value.stringValue
                    )
                }
                .map(digest)
                .filter { _ in
                    guard phoneHashCount
                            < WestreemVibeContactDiscoveryContract.maximumHashesPerKind
                    else { return false }
                    phoneHashCount += 1
                    return true
                }
                guard !emailHashes.isEmpty || !phoneHashes.isEmpty else { return }
                let name = CNContactFormatter.string(
                    from: contact,
                    style: .fullName
                )?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                let organization = contact.organizationName
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                values.append(
                    WestreemLocalContact(
                        id: contact.identifier,
                        displayName: name.flatMap { $0.isEmpty ? nil : $0 }
                            ?? (organization.isEmpty ? "Contact" : organization),
                        emailHashes: Array(Set(emailHashes)),
                        phoneHashes: Array(Set(phoneHashes))
                    )
                )
                if emailHashCount
                        >= WestreemVibeContactDiscoveryContract.maximumHashesPerKind,
                   phoneHashCount
                        >= WestreemVibeContactDiscoveryContract.maximumHashesPerKind {
                    stop.pointee = true
                }
            }
            return values
        }.value
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private struct MatrixNativeInviteUsersView: View {
    enum DestinationType: String {
        case vibe = "Vibe"
        case wave = "Wave"
    }

    let roomID: String
    let destinationName: String
    let destinationType: DestinationType

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var matrixSession: MatrixNativeSessionController
    @State private var query = ""
    @State private var results: [WestreemVibeInviteCandidate] = []
    @State private var selected: [WestreemVibeInviteCandidate] = []
    @State private var contacts: [WestreemVibeContact] = []
    @State private var busyContactUserID: String?
    @State private var existingUserIDs = Set<String>()
    @State private var isLoadingMembers = true
    @State private var isSearching = false
    @State private var isSending = false
    @State private var contactsAccess = WestreemContactsAccessState.notRequested
    @State private var localContacts: [WestreemLocalContact] = []
    @State private var matchedContacts: [WestreemVibeContactMatch] = []
    @State private var unsupportedContactKinds = Set<String>()
    @State private var isLoadingPhoneContacts = false
    @State private var inviteLink: WestreemVibeInviteLink?
    @State private var isCreatingInviteLink = false
    @State private var resultMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        List {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Invite to \(destinationName)")
                                .font(.subheadline.bold())
                            Text(
                                "Search active WeStreem accounts by name or handle. "
                                    + "Followers stay separate and are never added automatically."
                            )
                            .font(.caption)
                            .foregroundStyle(C.textMuted)
                        }
                    } icon: {
                        Image(systemName: destinationType == .vibe ? "person.3" : "wave.3.right")
                            .foregroundStyle(C.watch)
                    }
                }

                Section("Invitation link") {
                    if let inviteLink, let url = URL(string: inviteLink.url) {
                        ShareLink(
                            item: url,
                            subject: Text("Join \(destinationName) on WeStreem"),
                            message: Text("You’re invited to \(destinationName) on WeStreem.")
                        ) {
                            Label("Share invitation link", systemImage: "square.and.arrow.up")
                        }
                        Text("The link expires and has a limited number of uses.")
                            .font(.caption)
                            .foregroundStyle(C.textMuted)
                    } else {
                        Button {
                            Task { await createInviteLink() }
                        } label: {
                            if isCreatingInviteLink {
                                HStack {
                                    ProgressView().tint(C.watch)
                                    Text("Creating link…")
                                }
                            } else {
                                Label("Create invitation link", systemImage: "link.badge.plus")
                            }
                        }
                        .disabled(isCreatingInviteLink)
                    }
                }

                if !selected.isEmpty {
                    Section("Selected · \(selected.count)") {
                        ForEach(selected) { person in
                            candidateRow(person, isSelected: true, isExisting: false)
                        }
                    }
                }

                if !contacts.isEmpty {
                    Section("My Contacts") {
                        ForEach(contacts) { contact in
                            contactRow(contact)
                        }
                    }
                }

                phoneContactsSection

                Section {
                    if isSearching {
                        ProgressView("Finding people…")
                            .tint(C.watch)
                    } else if WestreemVibeInviteSearchContract.normalizedQuery(query) == nil {
                        ContentUnavailableView(
                            "Find people",
                            systemImage: "person.crop.circle.badge.plus",
                            description: Text("Enter at least two characters.")
                        )
                    } else if results.isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else {
                        ForEach(results) { person in
                            let isExisting = existingUserIDs.contains(person.matrixUserId)
                            candidateRow(
                                person,
                                isSelected: selected.contains(where: { $0.id == person.id }),
                                isExisting: isExisting
                            )
                        }
                    }
                } header: {
                    Text("WeStreem people")
                } footer: {
                    Text(
                        "Only active accounts with a ready WeStreem identity can be invited."
                    )
                }

                if let resultMessage {
                    Section {
                        Label(resultMessage, systemImage: "checkmark.circle")
                            .foregroundStyle(C.watch)
                    }
                }
        }
        .scrollContentBackground(.hidden)
        .background(C.bg)
        .navigationTitle("Invite people")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Name or @handle")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isSending ? "Inviting…" : "Invite") {
                    Task { await invite() }
                }
                .disabled(
                    isSending
                        || !WestreemVibeInviteSearchContract.canSubmit(
                            selected.map(\.matrixUserId)
                        )
                )
            }
        }
        .task(id: roomID) {
            await loadExistingMembers()
            await loadContacts()
            refreshContactsPermission()
        }
        .task(id: query) { await search() }
        .alert(
            "WeStreem couldn’t complete that",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func candidateRow(
        _ person: WestreemVibeInviteCandidate,
        isSelected: Bool,
        isExisting: Bool
    ) -> some View {
        HStack(spacing: 12) {
            MatrixNativeAvatar(
                name: person.displayName,
                imageURL: person.avatarUrl,
                size: 44
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(person.displayName)
                    .font(.subheadline.bold())
                    .foregroundStyle(C.text)
                    .lineLimit(1)
                Text("@\(person.handle)")
                    .font(.caption)
                    .foregroundStyle(C.textMuted)
                    .lineLimit(1)
                contactAction(for: person)
            }
            Spacer()
            if isExisting {
                Text("Member")
                    .font(.caption.bold())
                    .foregroundStyle(C.textMuted)
            } else {
                Button {
                    toggle(person)
                } label: {
                    Image(
                        systemName: isSelected
                            ? "checkmark.circle.fill"
                            : "circle"
                    )
                    .font(.title3)
                    .foregroundStyle(isSelected ? C.watch : C.textTertiary)
                }
                .buttonStyle(.plain)
                .disabled(isSending)
                .accessibilityLabel(
                    "\(isSelected ? "Remove" : "Select") \(person.displayName)"
                )
            }
        }
        .contentShape(Rectangle())
        .accessibilityLabel(
            isExisting
                ? "\(person.displayName), already a member"
                : "\(person.displayName), @\(person.handle)"
        )
    }

    @ViewBuilder
    private var phoneContactsSection: some View {
        Section {
            switch contactsAccess {
            case .notRequested:
                Button {
                    Task { await requestAndLoadPhoneContacts() }
                } label: {
                    Label("Find people from Contacts", systemImage: "person.crop.circle.badge.checkmark")
                }
            case .loading:
                ProgressView("Checking Contacts…")
                    .tint(C.watch)
            case .denied:
                Label(
                    "Contacts access is off. You can enable it in Settings.",
                    systemImage: "person.crop.circle.badge.xmark"
                )
                .foregroundStyle(C.textMuted)
                Button("Open Settings") { openAppSettings() }
            case .restricted:
                Label(
                    "Contacts access is restricted on this device.",
                    systemImage: "lock.fill"
                )
                .foregroundStyle(C.textMuted)
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.red)
                Button("Try Again") {
                    Task { await requestAndLoadPhoneContacts() }
                }
            case .authorized, .limited:
                if isLoadingPhoneContacts {
                    ProgressView("Finding people you know…")
                        .tint(C.watch)
                } else {
                    if localContacts.isEmpty {
                        Button {
                            Task { await loadPhoneContacts() }
                        } label: {
                            Label("Check Contacts", systemImage: "arrow.clockwise")
                        }
                    }
                    if contactsAccess == .limited {
                        Label(
                            "Showing only the contacts you allowed WeStreem to access.",
                            systemImage: "person.2.badge.gearshape"
                        )
                        .font(.caption)
                        .foregroundStyle(C.textMuted)
                    }

                    ForEach(matchedContacts) { match in
                        let person = match.inviteCandidate
                        candidateRow(
                            person,
                            isSelected: selected.contains(where: { $0.id == person.id }),
                            isExisting: existingUserIDs.contains(person.matrixUserId)
                        )
                    }

                    if matchedContacts.isEmpty, localContacts.isEmpty {
                        ContentUnavailableView(
                            "No available contacts",
                            systemImage: "person.2.slash",
                            description: Text("Add or allow contacts, then try again.")
                        )
                    } else if !unmatchedLocalContacts.isEmpty {
                        Text("Invite others to WeStreem")
                            .font(.caption.bold())
                            .foregroundStyle(C.textMuted)
                        ForEach(unmatchedLocalContacts.prefix(50)) { contact in
                            HStack {
                                Image(systemName: "person.crop.circle")
                                    .foregroundStyle(C.textMuted)
                                Text(contact.displayName)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Spacer()
                                if let inviteLink,
                                   let url = URL(string: inviteLink.url) {
                                    ShareLink(
                                        item: url,
                                        subject: Text("Join \(destinationName) on WeStreem"),
                                        message: Text(
                                            "You’re invited to \(destinationName) on WeStreem."
                                        )
                                    ) {
                                        Text("Invite")
                                    }
                                    .font(.caption.bold())
                                } else {
                                    Button("Create link") {
                                        Task { await createInviteLink() }
                                    }
                                    .font(.caption.bold())
                                    .disabled(isCreatingInviteLink)
                                }
                            }
                        }
                    }

                    if unsupportedContactKinds.contains("PHONE") {
                        Text(
                            "Phone-only contacts stay on your device and can receive the invitation link through Messages or the share sheet."
                        )
                        .font(.caption)
                        .foregroundStyle(C.textMuted)
                    }
                }
            }
        } header: {
            Text("From Contacts")
        } footer: {
            Text(
                "Contacts are optional. Names and contact details stay on this device; "
                    + "WeStreem receives only one-way hashes for matching. "
                    + "No follower is added as a contact or member automatically."
            )
        }
    }

    @ViewBuilder
    private func contactAction(
        for person: WestreemVibeInviteCandidate
    ) -> some View {
        let status = resolvedContactStatus(for: person)
        if busyContactUserID == person.westreemUserId {
            ProgressView().controlSize(.mini).tint(C.watch)
        } else {
            switch status {
            case .none:
                Button("Add Contact") {
                    Task { await manageContact(person, action: nil) }
                }
                .font(.caption.bold())
                .foregroundStyle(C.watch)
            case .pendingIncoming:
                HStack(spacing: 10) {
                    Button("Accept Contact") {
                        Task { await manageContact(person, action: .accept) }
                    }
                    Button("Decline") {
                        Task { await manageContact(person, action: .decline) }
                    }
                }
                .font(.caption.bold())
            case .pendingOutgoing:
                Label("Contact request sent", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(C.textMuted)
            case .contact:
                Menu {
                    Button(role: .destructive) {
                        Task { await manageContact(person, action: .remove) }
                    } label: {
                        Label("Remove Contact", systemImage: "person.badge.minus")
                    }
                } label: {
                    Label("Contact", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(C.watch)
                }
            }
        }
    }

    @ViewBuilder
    private func contactRow(_ contact: WestreemVibeContact) -> some View {
        let person = candidate(from: contact)
        candidateRow(
            person,
            isSelected: selected.contains(where: { $0.id == person.id }),
            isExisting: existingUserIDs.contains(person.matrixUserId)
        )
    }

    private var unmatchedLocalContacts: [WestreemLocalContact] {
        let matchedHashes = Set(matchedContacts.map(\.matchedEmailHash))
        return localContacts.filter {
            matchedHashes.isDisjoint(with: Set($0.emailHashes))
        }
    }

    private func candidate(
        from contact: WestreemVibeContact
    ) -> WestreemVibeInviteCandidate {
        let status: WestreemVibeContactStatus = switch (
            contact.status,
            contact.direction
        ) {
        case (.accepted, _): .contact
        case (.pending, .incoming): .pendingIncoming
        case (.pending, .outgoing): .pendingOutgoing
        case (.pending, .contact): .contact
        }
        return WestreemVibeInviteCandidate(
            westreemUserId: contact.user.westreemUserId,
            matrixUserId: contact.user.matrixUserId,
            handle: contact.user.handle,
            displayName: contact.user.displayName,
            avatarUrl: contact.user.avatarUrl,
            contactStatus: status
        )
    }

    private func resolvedContactStatus(
        for person: WestreemVibeInviteCandidate
    ) -> WestreemVibeContactStatus {
        guard let contact = contacts.first(where: {
            $0.user.westreemUserId == person.westreemUserId
        }) else {
            return person.contactStatus ?? .none
        }
        return candidate(from: contact).contactStatus ?? .none
    }

    @MainActor
    private func loadContacts() async {
        do {
            contacts = try await APIClient.shared.fetchVibeContacts()
        } catch {
            contacts = []
        }
    }

    @MainActor
    private func manageContact(
        _ person: WestreemVibeInviteCandidate,
        action: WestreemVibeContactAction?
    ) async {
        guard busyContactUserID == nil else { return }
        busyContactUserID = person.westreemUserId
        defer { busyContactUserID = nil }
        do {
            if let action {
                guard let contact = contacts.first(where: {
                    $0.user.westreemUserId == person.westreemUserId
                }) else {
                    await loadContacts()
                    return
                }
                _ = try await APIClient.shared.updateVibeContact(
                    id: contact.id,
                    action: action
                )
            } else {
                _ = try await APIClient.shared.createVibeContact(
                    westreemUserID: person.westreemUserId
                )
            }
            await loadContacts()
            if WestreemVibeInviteSearchContract.normalizedQuery(query) != nil {
                await search()
            }
        } catch {
            errorMessage = "The contact request could not be updated."
        }
    }

    @MainActor
    private func refreshContactsPermission() {
        contactsAccess = WestreemContactPrivacy.contactsAccessState()
    }

    @MainActor
    private func requestAndLoadPhoneContacts() async {
        contactsAccess = .loading
        do {
            let current = WestreemContactPrivacy.contactsAccessState()
            if current == .notRequested {
                _ = try await WestreemContactPrivacy.requestAccess()
            }
            contactsAccess = WestreemContactPrivacy.contactsAccessState()
            guard contactsAccess == .authorized || contactsAccess == .limited else {
                return
            }
            await loadPhoneContacts()
        } catch {
            contactsAccess = .failed("Contacts could not be opened.")
        }
    }

    @MainActor
    private func loadPhoneContacts() async {
        isLoadingPhoneContacts = true
        defer { isLoadingPhoneContacts = false }
        do {
            let values = try await WestreemContactPrivacy.loadContacts()
            let emailHashes = WestreemVibeContactDiscoveryContract.boundedHashes(
                values.flatMap(\.emailHashes)
            )
            let phoneHashes = WestreemVibeContactDiscoveryContract.boundedHashes(
                values.flatMap(\.phoneHashes)
            )
            let response = try await APIClient.shared.matchVibeContacts(
                emailHashes: emailHashes,
                phoneHashes: phoneHashes
            )
            localContacts = values
            matchedContacts = response.matches
            unsupportedContactKinds = Set(response.unsupportedKinds)
        } catch {
            localContacts = []
            matchedContacts = []
            contactsAccess = .failed(
                "Contacts could not be matched right now. No contact details were saved."
            )
        }
    }

    @MainActor
    private func createInviteLink() async {
        guard !isCreatingInviteLink else { return }
        isCreatingInviteLink = true
        defer { isCreatingInviteLink = false }
        do {
            inviteLink = try await APIClient.shared.createVibeInviteLink(
                targetType: destinationType == .vibe ? .space : .room,
                matrixSpaceID: destinationType == .vibe ? roomID : nil,
                matrixRoomID: destinationType == .wave ? roomID : nil
            )
            errorMessage = nil
        } catch {
            errorMessage = "The invitation link could not be created."
        }
    }

    @MainActor
    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        UIApplication.shared.open(url)
    }

    @MainActor
    private func loadExistingMembers() async {
        isLoadingMembers = true
        defer { isLoadingMembers = false }
        existingUserIDs = Set(
            (try? await matrixSession.waveMembers(roomID: roomID))?
                .map(\.userID)
                ?? []
        )
    }

    @MainActor
    private func search() async {
        guard let normalized = WestreemVibeInviteSearchContract.normalizedQuery(query) else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        errorMessage = nil
        do {
            try await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let candidates = try await APIClient.shared.searchVibeInviteCandidates(
                q: normalized
            )
            guard !Task.isCancelled else { return }
            results = candidates
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            errorMessage = "WeStreem people search is temporarily unavailable."
        }
        isSearching = false
    }

    @MainActor
    private func toggle(_ person: WestreemVibeInviteCandidate) {
        guard !existingUserIDs.contains(person.matrixUserId) else { return }
        if let index = selected.firstIndex(where: { $0.id == person.id }) {
            selected.remove(at: index)
        } else if selected.count < WestreemVibeInviteSearchContract.maximumSelection {
            selected.append(person)
        }
        resultMessage = nil
    }

    @MainActor
    private func invite() async {
        let requested = WestreemVibeInviteSearchContract.uniqueSelection(
            selected.map(\.matrixUserId)
        )
        guard
            !isSending,
            WestreemVibeInviteSearchContract.canSubmit(requested)
        else { return }
        isSending = true
        defer { isSending = false }
        do {
            let failures = try await matrixSession.inviteUsers(
                requested,
                roomID: roomID
            )
            let failureSet = Set(failures)
            let sent = selected.filter { !failureSet.contains($0.matrixUserId) }
            let failed = selected.filter { failureSet.contains($0.matrixUserId) }
            let sentCount = sent.count
            resultMessage = "\(sentCount) invitation\(sentCount == 1 ? "" : "s") sent."
            existingUserIDs.formUnion(sent.map(\.matrixUserId))
            selected = failed
            if !failed.isEmpty {
                let names = failed.map(\.displayName).joined(separator: ", ")
                errorMessage = "These people could not be invited: \(names)"
            } else {
                errorMessage = nil
            }
        } catch {
            errorMessage = MatrixNativeCopy.message(for: error)
        }
    }
}

struct MatrixNativeWaveRoomView: View {
    fileprivate struct OptimisticMessage: Identifiable, Equatable {
        let id: String
        let body: String
        let createdAt: Date
        var state: MatrixNativeLocalSendState
    }

    let room: MatrixWaveSummary
    var opensLiveLounge = false

    @EnvironmentObject private var matrixSession: MatrixNativeSessionController
    @Environment(\.dismiss) private var dismissRoom
    @State private var items: [MatrixTimelineItem] = []
    @State private var members: [MatrixNativeWaveMember] = []
    @State private var typingUserIDs: [String] = []
    @State private var optimistic: [OptimisticMessage] = []
    @State private var draft = ""
    @State private var isLoading = true
    @State private var isLoadingHistory = false
    @State private var errorMessage: String?
    @State private var rtcPresented = false
    @State private var secureCallNoticePresented = false
    @State private var showsSecuritySetup = false
    @State private var handledLiveLoungeRoute = false
    @State private var settingsPresented = false
    @State private var pinnedPresented = false
    @State private var threadRoot: MatrixTimelineItem?
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            MatrixNativeConnectionBanner(state: matrixSession.syncState)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        Button {
                            Task { await load(paginate: true) }
                        } label: {
                            if isLoadingHistory {
                                ProgressView().tint(C.watch)
                            } else {
                                Label("Load earlier messages", systemImage: "arrow.up")
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(C.watch)
                        .padding(.vertical, 12)
                        .disabled(isLoadingHistory)

                        if isLoading, items.isEmpty, optimistic.isEmpty {
                            ProgressView().tint(C.watch).padding(.top, 70)
                        } else if items.isEmpty, optimistic.isEmpty {
                            ContentUnavailableView {
                                Label("Start the Wave", systemImage: "bubble.left.and.bubble.right")
                            } description: {
                                Text("Send the first message in this room.")
                            }
                            .foregroundStyle(C.text)
                            .padding(.top, 60)
                        } else {
                            ForEach(items) { item in
                                MatrixNativeMessageRow(
                                    roomID: room.id,
                                    roomIsEncrypted: room.isEncrypted,
                                    item: item,
                                    showsDiscussion: true,
                                    openDiscussion: { threadRoot = item },
                                    addEnergy: { key in
                                        Task { await addEnergy(key, to: item) }
                                    },
                                    edit: { body in
                                        Task { await edit(item, body: body) }
                                    },
                                    redact: {
                                        Task { await redact(item) }
                                    },
                                    report: { reason in
                                        Task { await report(item, reason: reason) }
                                    },
                                    setPinned: { pinned in
                                        Task { await setPinned(item, pinned: pinned) }
                                    },
                                    vote: { optionID in
                                        Task { await vote(item: item, optionID: optionID) }
                                    }
                                )
                                    .id(item.id)
                            }
                            ForEach(optimistic) { message in
                                MatrixNativeOptimisticMessageRow(
                                    message: message,
                                    retry: { Task { await retry(message) } },
                                    remove: { optimistic.removeAll { $0.id == message.id } }
                                )
                                .id(message.id)
                            }
                        }

                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(Color.red)
                                .padding()
                        }
                    }
                    .padding(.vertical, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                .refreshable { await load() }
                .onChange(of: items.count + optimistic.count) { _, _ in
                    if let id = optimistic.last?.id ?? items.last?.id {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }

            MatrixNativeWaveActivityStrip(
                typingUserIDs: typingUserIDs,
                members: members
            )
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MatrixNativeRichComposer(
                roomID: room.id,
                text: $draft,
                isFocused: $composerFocused,
                mentionMembers: members,
                sendText: { mentions in
                    Task { await send(mentions: mentions) }
                },
                sendAttachments: { uploads, caption in
                    Task { await sendAttachments(uploads, caption: caption) }
                },
                sendPoll: { question, options in
                    Task { await sendPoll(question: question, options: options) }
                },
                sendSticker: { upload in
                    Task { await sendSticker(upload) }
                }
            )
        }
        .background(C.bg.ignoresSafeArea())
        .navigationTitle(room.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    pinnedPresented = true
                } label: {
                    Image(systemName: "pin")
                }
                .accessibilityLabel("Pinned Ripples")

                Button {
                    settingsPresented = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Wave settings")

                Button {
                    if room.isEncrypted || room.isDirect {
                        secureCallNoticePresented = true
                    } else {
                        rtcPresented = true
                    }
                } label: {
                    Image(systemName: room.isEncrypted ? "lock.shield" : "video.fill")
                }
                .accessibilityLabel(
                    room.isEncrypted
                        ? "Secure call unavailable until media encryption is verified"
                        : "Open live Wave"
                )
            }
        }
        .fullScreenCover(isPresented: $rtcPresented) {
            MatrixNativeRtcRoomView(room: room)
                .environmentObject(matrixSession)
        }
        .alert("Secure calls are preparing", isPresented: $secureCallNoticePresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(
                "This conversation is encrypted. Voice and video remain unavailable until WeStreem can apply and verify encrypted media keys on both web and iPhone."
            )
        }
        .sheet(isPresented: $settingsPresented) {
            MatrixNativeWaveManagementView(
                room: room,
                didLeave: {
                    settingsPresented = false
                    dismissRoom()
                }
            )
                .environmentObject(matrixSession)
        }
        .sheet(isPresented: $pinnedPresented) {
            MatrixNativePinnedRipplesView(room: room)
                .environmentObject(matrixSession)
        }
        .sheet(isPresented: $showsSecuritySetup) {
            MatrixNativeCryptoSecurityView(
                requiredForAction: true,
                onReady: {
                    showsSecuritySetup = false
                    Task { await load() }
                }
            )
            .environmentObject(matrixSession)
        }
        .navigationDestination(
            isPresented: Binding(
                get: { threadRoot != nil },
                set: { if !$0 { threadRoot = nil } }
            )
        ) {
            if let threadRoot {
                MatrixNativeThreadView(room: room, root: threadRoot)
            }
        }
        .task(id: room.id) {
            await load()
            if opensLiveLounge,
               !handledLiveLoungeRoute,
               !room.isEncrypted,
               !room.isDirect {
                handledLiveLoungeRoute = true
                rtcPresented = true
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                await load(showSpinner: false)
            }
        }
        .task(id: "typing-\(room.id)") {
            do {
                let updates = try await matrixSession.typingUpdates(
                    roomID: room.id
                )
                for await userIDs in updates {
                    guard !Task.isCancelled else { return }
                    typingUserIDs = userIDs
                }
            } catch {
                typingUserIDs = []
            }
        }
        .onChange(of: draft) { _, value in
            let isTyping = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Task { await matrixSession.setTyping(isTyping, roomID: room.id) }
        }
        .onDisappear {
            Task { await matrixSession.setTyping(false, roomID: room.id) }
        }
    }

    @MainActor
    private func load(paginate: Bool = false, showSpinner: Bool = true) async {
        if paginate { isLoadingHistory = true } else if showSpinner { isLoading = true }
        await matrixSession.refreshRuntimeState()
        do {
            let page = try await matrixSession.timeline(roomID: room.id, paginate: paginate)
            items = page.items
            if let loadedMembers = try? await matrixSession.waveMembers(roomID: room.id) {
                members = loadedMembers
            }
            reconcileOptimisticMessages()
            errorMessage = nil
            await matrixSession.markRead(roomID: room.id)
        } catch let error as MatrixNativeCryptoSecurityError
            where error.requiresGuidedRecovery {
            errorMessage = nil
            showsSecuritySetup = true
        } catch {
            errorMessage = MatrixNativeCopy.message(for: error)
        }
        isLoading = false
        isLoadingHistory = false
    }

    @MainActor
    private func send(mentions: [MatrixNativeMentionTarget]) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let transactionID = "westreem-ios-\(UUID().uuidString.lowercased())"
        optimistic.append(OptimisticMessage(
            id: transactionID,
            body: text,
            createdAt: Date(),
            state: .sending
        ))
        draft = ""
        errorMessage = nil
        do {
            try await matrixSession.sendText(
                text,
                mentions: mentions,
                roomID: room.id,
                transactionID: transactionID
            )
            updateOptimistic(transactionID) { $0.state = .sent }
            await load(showSpinner: false)
        } catch {
            updateOptimistic(transactionID) { $0.state = .failed(isRecoverable: true) }
            errorMessage = MatrixNativeCopy.message(for: error)
        }
    }

    @MainActor
    private func sendAttachments(_ uploads: [MatrixNativeUpload], caption: String?) async {
        guard !uploads.isEmpty else { return }
        let transactionID = "westreem-ios-media-\(UUID().uuidString.lowercased())"
        let body = caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        let optimisticBody = body.flatMap { $0.isEmpty ? nil : $0 }
            ?? MatrixNativeMediaCopy.summary(for: uploads)
        optimistic.append(OptimisticMessage(
            id: transactionID,
            body: optimisticBody,
            createdAt: Date(),
            state: .sending
        ))
        errorMessage = nil
        do {
            try await matrixSession.sendAttachments(
                uploads,
                caption: body,
                roomID: room.id,
                transactionID: transactionID
            )
            updateOptimistic(transactionID) { $0.state = .sent }
            optimistic.removeAll { $0.id == transactionID }
            await load(showSpinner: false)
        } catch {
            updateOptimistic(transactionID) {
                $0.state = .failed(isRecoverable: false)
            }
            errorMessage = MatrixNativeMediaCopy.message(for: error)
        }
    }

    @MainActor
    private func sendPoll(question: String, options: [String]) async {
        let transactionID = "westreem-ios-poll-\(UUID().uuidString.lowercased())"
        optimistic.append(OptimisticMessage(
            id: transactionID,
            body: question,
            createdAt: Date(),
            state: .sending
        ))
        errorMessage = nil
        do {
            try await matrixSession.createPoll(
                question: question,
                options: options,
                roomID: room.id,
                transactionID: transactionID
            )
            updateOptimistic(transactionID) { $0.state = .sent }
            optimistic.removeAll { $0.id == transactionID }
            await load(showSpinner: false)
        } catch {
            updateOptimistic(transactionID) {
                $0.state = .failed(isRecoverable: false)
            }
            errorMessage = MatrixNativeMediaCopy.message(for: error)
        }
    }

    @MainActor
    private func sendSticker(_ upload: MatrixNativeUpload) async {
        let transactionID = "westreem-ios-sticker-\(UUID().uuidString.lowercased())"
        optimistic.append(OptimisticMessage(
            id: transactionID,
            body: "Sticker",
            createdAt: Date(),
            state: .sending
        ))
        errorMessage = nil
        do {
            try await matrixSession.sendSticker(
                upload,
                roomID: room.id,
                transactionID: transactionID
            )
            updateOptimistic(transactionID) { $0.state = .sent }
            optimistic.removeAll { $0.id == transactionID }
            await load(showSpinner: false)
        } catch {
            updateOptimistic(transactionID) {
                $0.state = .failed(isRecoverable: false)
            }
            errorMessage = MatrixNativeMediaCopy.message(for: error)
        }
    }

    @MainActor
    private func vote(item: MatrixTimelineItem, optionID: String) async {
        guard item.poll != nil else { return }
        do {
            try await matrixSession.voteInPoll(
                roomID: room.id,
                eventID: item.id,
                optionID: optionID
            )
            await load(showSpinner: false)
        } catch {
            errorMessage = MatrixNativeMediaCopy.message(for: error)
        }
    }

    @MainActor
    private func addEnergy(_ key: String, to item: MatrixTimelineItem) async {
        do {
            _ = try await matrixSession.toggleEnergy(key, item: item, roomID: room.id)
            await load(showSpinner: false)
        } catch {
            errorMessage = MatrixNativeCopy.message(for: error)
        }
    }

    @MainActor
    private func edit(_ item: MatrixTimelineItem, body: String) async {
        do {
            try await matrixSession.editMessage(body, item: item, roomID: room.id)
            await load(showSpinner: false)
        } catch {
            errorMessage = MatrixNativeCopy.message(for: error)
        }
    }

    @MainActor
    private func redact(_ item: MatrixTimelineItem) async {
        do {
            try await matrixSession.redactMessage(item: item, roomID: room.id)
            await load(showSpinner: false)
        } catch {
            errorMessage = MatrixNativeCopy.message(for: error)
        }
    }

    @MainActor
    private func report(_ item: MatrixTimelineItem, reason: String) async {
        do {
            try await matrixSession.reportMessage(
                item: item,
                roomID: room.id,
                reason: reason
            )
        } catch {
            errorMessage = MatrixNativeCopy.message(for: error)
        }
    }

    @MainActor
    private func setPinned(_ item: MatrixTimelineItem, pinned: Bool) async {
        do {
            try await matrixSession.setMessagePinned(
                pinned,
                item: item,
                roomID: room.id
            )
            await load(showSpinner: false)
        } catch {
            errorMessage = MatrixNativeCopy.message(for: error)
        }
    }

    @MainActor
    private func retry(_ message: OptimisticMessage) async {
        updateOptimistic(message.id) { $0.state = .sending }
        do {
            try await matrixSession.retry(transactionID: message.id, roomID: room.id)
            updateOptimistic(message.id) { $0.state = .sent }
            optimistic.removeAll { $0.id == message.id }
            await load(showSpinner: false)
        } catch {
            updateOptimistic(message.id) { $0.state = .failed(isRecoverable: false) }
            errorMessage = "This queued message cannot be retried safely. Remove it and send again."
        }
    }

    private func updateOptimistic(
        _ id: String,
        mutation: (inout OptimisticMessage) -> Void
    ) {
        guard let index = optimistic.firstIndex(where: { $0.id == id }) else { return }
        mutation(&optimistic[index])
    }

    private func reconcileOptimisticMessages() {
        optimistic.removeAll { pending in
            items.contains { item in
                item.isOwn
                    && item.body == pending.body
                    && abs(item.timestamp.timeIntervalSince(pending.createdAt)) < 120
            }
        }
    }
}

private struct MatrixNativePinnedRipplesView: View {
    let room: MatrixWaveSummary

    @EnvironmentObject private var matrixSession: MatrixNativeSessionController
    @Environment(\.dismiss) private var dismiss
    @State private var items: [MatrixTimelineItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading, items.isEmpty {
                    MatrixNativeLoadingView(title: "Loading pinned Ripples")
                } else if let errorMessage, items.isEmpty {
                    MatrixNativeUnavailableView(
                        title: "Pinned Ripples unavailable",
                        message: errorMessage,
                        retry: { Task { await load() } }
                    )
                } else if items.isEmpty {
                    ContentUnavailableView {
                        Label("No pinned Ripples", systemImage: "pin")
                    } description: {
                        Text("Pinned messages will appear here.")
                    }
                    .foregroundStyle(C.text)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(items) { item in
                                MatrixNativeMessageRow(
                                    roomID: room.id,
                                    roomIsEncrypted: room.isEncrypted,
                                    item: item,
                                    showsDiscussion: false,
                                    openDiscussion: {},
                                    addEnergy: { key in
                                        Task {
                                            await perform {
                                                _ = try await matrixSession.toggleEnergy(
                                                    key,
                                                    item: item,
                                                    roomID: room.id
                                                )
                                            }
                                        }
                                    },
                                    edit: { body in
                                        Task {
                                            await perform {
                                                try await matrixSession.editMessage(
                                                    body,
                                                    item: item,
                                                    roomID: room.id
                                                )
                                            }
                                        }
                                    },
                                    redact: {
                                        Task {
                                            await perform {
                                                try await matrixSession.redactMessage(
                                                    item: item,
                                                    roomID: room.id
                                                )
                                            }
                                        }
                                    },
                                    report: { reason in
                                        Task {
                                            await perform(reload: false) {
                                                try await matrixSession.reportMessage(
                                                    item: item,
                                                    roomID: room.id,
                                                    reason: reason
                                                )
                                            }
                                        }
                                    },
                                    setPinned: { pinned in
                                        Task {
                                            await perform {
                                                try await matrixSession.setMessagePinned(
                                                    pinned,
                                                    item: item,
                                                    roomID: room.id
                                                )
                                            }
                                        }
                                    },
                                    vote: { optionID in
                                        Task {
                                            await perform {
                                                try await matrixSession.voteInPoll(
                                                    roomID: room.id,
                                                    eventID: item.id,
                                                    optionID: optionID
                                                )
                                            }
                                        }
                                    }
                                )
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .refreshable { await load() }
                }
            }
            .background(C.bg.ignoresSafeArea())
            .navigationTitle("Pinned Ripples")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task(id: room.id) { await load() }
    }

    @MainActor
    private func load() async {
        isLoading = true
        do {
            items = try await matrixSession.pinnedMessages(roomID: room.id).items
            errorMessage = nil
        } catch {
            errorMessage = MatrixNativeCopy.message(for: error)
        }
        isLoading = false
    }

    @MainActor
    private func perform(
        reload: Bool = true,
        _ action: () async throws -> Void
    ) async {
        do {
            try await action()
            if reload { await load() }
        } catch {
            errorMessage = MatrixNativeCopy.message(for: error)
        }
    }
}

private struct MatrixNativeThreadView: View {
    let room: MatrixWaveSummary
    let root: MatrixTimelineItem

    @EnvironmentObject private var matrixSession: MatrixNativeSessionController
    @State private var items: [MatrixTimelineItem] = []
    @State private var members: [MatrixNativeWaveMember] = []
    @State private var selectedMentions: [MatrixNativeMentionTarget] = []
    @State private var draft = ""
    @State private var isLoading = true
    @State private var isSending = false
    @State private var errorMessage: String?
    @FocusState private var composerFocused: Bool

    private var replies: [MatrixTimelineItem] {
        items.filter { $0.id != root.id }
    }

    private var displayedRoot: MatrixTimelineItem {
        items.first(where: { $0.id == root.id }) ?? root
    }

    private var mentionSuggestions: [MatrixNativeMentionTarget] {
        guard let query = MatrixNativeMentionComposer.query(in: draft) else {
            return []
        }
        let needle = query.lowercased()
        return members
            .filter { !$0.isService && $0.state == .joined }
            .map {
                MatrixNativeMentionTarget(
                    userID: $0.userID,
                    displayName: $0.displayName
                )
            }
            .filter {
                needle.isEmpty
                    || $0.displayName.lowercased().contains(needle)
                    || $0.userID.lowercased().contains(needle)
            }
            .prefix(8)
            .map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            MatrixNativeConnectionBanner(state: matrixSession.syncState)
            ScrollView {
                LazyVStack(spacing: 3) {
                    MatrixNativeMessageRow(
                        roomID: room.id,
                        roomIsEncrypted: room.isEncrypted,
                        item: displayedRoot,
                        showsDiscussion: false,
                        openDiscussion: {},
                        addEnergy: { key in
                            Task { await addEnergy(key, to: displayedRoot) }
                        },
                        edit: { body in
                            Task { await edit(displayedRoot, body: body) }
                        },
                        redact: { Task { await redact(displayedRoot) } },
                        report: { reason in
                            Task { await report(displayedRoot, reason: reason) }
                        },
                        setPinned: { pinned in
                            Task { await setPinned(displayedRoot, pinned: pinned) }
                        },
                        vote: { optionID in
                            Task { await vote(displayedRoot, optionID: optionID) }
                        }
                    )
                    .background(C.surface.opacity(0.42))

                    Divider().overlay(C.borderSubtle)
                        .padding(.vertical, 5)

                    if isLoading, replies.isEmpty {
                        ProgressView().tint(C.watch).padding(.top, 40)
                    } else if replies.isEmpty {
                        Text("No replies yet. Start the discussion.")
                            .font(.footnote)
                            .foregroundStyle(C.textMuted)
                            .padding(.vertical, 34)
                    } else {
                        ForEach(replies) { item in
                            MatrixNativeMessageRow(
                                roomID: room.id,
                                roomIsEncrypted: room.isEncrypted,
                                item: item,
                                showsDiscussion: false,
                                openDiscussion: {},
                                addEnergy: { key in
                                    Task { await addEnergy(key, to: item) }
                                },
                                edit: { body in
                                    Task { await edit(item, body: body) }
                                },
                                redact: { Task { await redact(item) } },
                                report: { reason in
                                    Task { await report(item, reason: reason) }
                                },
                                setPinned: { pinned in
                                    Task { await setPinned(item, pinned: pinned) }
                                },
                                vote: { optionID in
                                    Task { await vote(item, optionID: optionID) }
                                }
                            )
                        }
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(Color.red)
                            .padding()
                    }
                }
                .padding(.vertical, 8)
            }
            .refreshable { await load() }
            .scrollDismissesKeyboard(.interactively)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 7) {
                if !mentionSuggestions.isEmpty {
                    MatrixNativeMentionSuggestions(
                        suggestions: mentionSuggestions,
                        select: selectMention
                    )
                }
                HStack(spacing: 10) {
                    TextField("Reply in discussion", text: $draft, axis: .vertical)
                        .lineLimit(1...5)
                        .textFieldStyle(.plain)
                        .focused($composerFocused)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(C.surface, in: RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(C.borderSubtle))
                        .accessibilityLabel("Discussion reply")

                    Button {
                        Task { await sendReply() }
                    } label: {
                        if isSending {
                            ProgressView().tint(C.bg)
                        } else {
                            Image(systemName: "paperplane.fill")
                        }
                    }
                    .frame(width: 44, height: 44)
                    .background(C.watch, in: Circle())
                    .foregroundStyle(C.bg)
                    .disabled(
                        isSending
                            || MatrixNativeWaveActionPolicy.normalizedMessage(draft) == nil
                    )
                    .accessibilityLabel("Send discussion reply")
                }
            }
            .padding(.horizontal, C.pagePad)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial)
        }
        .background(C.bg.ignoresSafeArea())
        .navigationTitle("Discussion")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: root.id) {
            await load()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                await load(showSpinner: false)
            }
        }
    }

    @MainActor
    private func load(showSpinner: Bool = true) async {
        if showSpinner { isLoading = true }
        do {
            items = try await matrixSession.thread(
                roomID: room.id,
                rootEventID: root.id
            ).items
            if let loadedMembers = try? await matrixSession.waveMembers(roomID: room.id) {
                members = loadedMembers
            }
            errorMessage = nil
        } catch {
            errorMessage = MatrixNativeCopy.message(for: error)
        }
        isLoading = false
    }

    @MainActor
    private func sendReply() async {
        guard let body = MatrixNativeWaveActionPolicy.normalizedMessage(draft) else {
            return
        }
        isSending = true
        errorMessage = nil
        do {
            try await matrixSession.sendThreadReply(
                body,
                roomID: room.id,
                rootEventID: root.id,
                mentions: MatrixNativeMentionComposer.activeTargets(
                    in: body,
                    selected: selectedMentions
                )
            )
            draft = ""
            selectedMentions = []
            await load(showSpinner: false)
        } catch {
            // Preserve the draft. The SDK owns any accepted offline send; when
            // it rejects before queueing, the user can retry without duplicate
            // Westreem state or a recreated Matrix payload.
            errorMessage = MatrixNativeCopy.message(for: error)
        }
        isSending = false
    }

    private func selectMention(_ target: MatrixNativeMentionTarget) {
        draft = MatrixNativeMentionComposer.inserting(target, into: draft)
        selectedMentions.removeAll { $0.userID == target.userID }
        selectedMentions.append(target)
        composerFocused = true
    }

    @MainActor
    private func addEnergy(_ key: String, to item: MatrixTimelineItem) async {
        await perform {
            _ = try await matrixSession.toggleEnergy(key, item: item, roomID: room.id)
        }
    }

    @MainActor
    private func edit(_ item: MatrixTimelineItem, body: String) async {
        await perform {
            try await matrixSession.editMessage(body, item: item, roomID: room.id)
        }
    }

    @MainActor
    private func redact(_ item: MatrixTimelineItem) async {
        await perform {
            try await matrixSession.redactMessage(item: item, roomID: room.id)
        }
    }

    @MainActor
    private func report(_ item: MatrixTimelineItem, reason: String) async {
        await perform(reload: false) {
            try await matrixSession.reportMessage(
                item: item,
                roomID: room.id,
                reason: reason
            )
        }
    }

    @MainActor
    private func setPinned(_ item: MatrixTimelineItem, pinned: Bool) async {
        await perform {
            try await matrixSession.setMessagePinned(
                pinned,
                item: item,
                roomID: room.id
            )
        }
    }

    @MainActor
    private func vote(_ item: MatrixTimelineItem, optionID: String) async {
        await perform {
            try await matrixSession.voteInPoll(
                roomID: room.id,
                eventID: item.id,
                optionID: optionID
            )
        }
    }

    @MainActor
    private func perform(
        reload: Bool = true,
        _ action: () async throws -> Void
    ) async {
        do {
            try await action()
            if reload { await load(showSpinner: false) }
        } catch {
            errorMessage = MatrixNativeCopy.message(for: error)
        }
    }
}

struct MatrixNativeLegacyRouteUnavailableView: View {
    let title: String

    var body: some View {
        MatrixNativeUnavailableView(
            title: title,
            message: "This older social link is no longer supported. Open Vibes and choose the Vibe or Wave instead.",
            retry: nil
        )
        .navigationTitle("Vibes")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MatrixNativeWaveActivityStrip: View {
    let typingUserIDs: [String]
    let members: [MatrixNativeWaveMember]

    private var typingNames: [String] {
        let lookup = Dictionary(
            members.map { ($0.userID, $0.displayName) },
            uniquingKeysWith: { first, _ in first }
        )
        return typingUserIDs.prefix(3).map {
            lookup[$0] ?? "A WeStreem member"
        }
    }

    private var memberStatuses: [String] {
        members.compactMap { member in
            guard member.state == .joined,
                  !member.isService,
                  let status = member.statusText?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !status.isEmpty
            else {
                return nil
            }
            let emoji = member.statusEmoji?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return [emoji, member.displayName, status]
                .compactMap { value in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }
                .joined(separator: " ")
        }
        .prefix(2)
        .map(\.self)
    }

    var body: some View {
        Group {
            if !typingNames.isEmpty {
                Label(
                    "\(typingNames.joined(separator: ", ")) \(typingNames.count == 1 ? "is" : "are") typing…",
                    systemImage: "ellipsis.bubble"
                )
            } else if !memberStatuses.isEmpty {
                Label(
                    memberStatuses.joined(separator: "  ·  "),
                    systemImage: "person.crop.circle"
                )
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(C.textMuted)
        .lineLimit(1)
        .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
        .padding(.horizontal, C.pagePad)
        .accessibilityElement(children: .combine)
    }
}

private struct MatrixNativeMessageRow: View {
    let roomID: String
    let roomIsEncrypted: Bool
    let item: MatrixTimelineItem
    let showsDiscussion: Bool
    let openDiscussion: () -> Void
    let addEnergy: (String) -> Void
    let edit: (String) -> Void
    let redact: () -> Void
    let report: (String) -> Void
    let setPinned: (Bool) -> Void
    let vote: (String) -> Void

    @State private var energyPresented = false
    @State private var editPresented = false
    @State private var reportPresented = false
    @State private var deleteConfirmationPresented = false
    @State private var atmoEchoPresented = false
    @State private var waveEchoPresented = false

    private var hasMoreActions: Bool {
        item.actions.canEdit
            || item.actions.canPin
            || item.actions.canReport
            || item.actions.canRedact
            || canEchoToAtmo
    }

    private var canEchoToAtmo: Bool {
        SocialFeatureConfiguration.runtime().personalAtmoV2Enabled
            && !roomIsEncrypted
            && item.kind != .redacted
            && item.kind != .unableToDecrypt
            && item.reference.remoteEventID != nil
    }

    private var canEchoToWaves: Bool {
        !roomIsEncrypted
            && item.kind != .redacted
            && item.kind != .unableToDecrypt
            && item.reference.remoteEventID != nil
            && (item.westreemReference?.provenance.hopTrace?.count ?? 0) < 8
    }

    private var canNativeShare: Bool {
        item.kind != .redacted
            && item.kind != .unableToDecrypt
            && !item.body.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            MatrixNativeAvatar(
                name: item.senderDisplayName,
                imageURL: item.senderAvatarURL,
                size: 36
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(item.senderDisplayName)
                        .font(.subheadline.bold())
                        .foregroundStyle(C.text)
                        .lineLimit(1)
                    Text(item.timestamp, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(C.textTertiary)
                    if item.isEdited {
                        Text("edited").font(.caption2).foregroundStyle(C.textTertiary)
                    }
                }

                if let reference = item.westreemReference {
                    MatrixNativeWestreemReferenceCard(reference: reference)
                } else {
                    Label {
                        Text(item.body)
                            .font(.body)
                            .foregroundStyle(item.kind == .redacted ? C.textMuted : C.text)
                            .multilineTextAlignment(.leading)
                    } icon: {
                        if item.kind != .text {
                            Image(systemName: MatrixNativeCopy.icon(for: item.kind))
                                .foregroundStyle(C.watch)
                        }
                    }
                    .labelStyle(
                        MatrixConditionalIconLabelStyle(showIcon: item.kind != .text)
                    )

                    MatrixNativeLinkPreviewCard(
                        messageBody: item.body,
                        enabled: !roomIsEncrypted && item.kind == .text
                    )
                }

                if let poll = item.poll {
                    MatrixNativePollCard(poll: poll, vote: vote)
                }

                if !item.media.isEmpty {
                    MatrixNativeMediaStrip(roomID: roomID, media: item.media)
                }

                if !item.replyPreviews.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(item.replyPreviews.prefix(
                            MatrixNativeWaveActionPolicy.replyPreviewLimit
                        )) { reply in
                            Button(action: openDiscussion) {
                                HStack(alignment: .top, spacing: 7) {
                                    Image(systemName: "arrow.turn.down.right")
                                        .font(.caption)
                                        .foregroundStyle(C.watch)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(reply.senderDisplayName)
                                            .font(.caption.bold())
                                            .foregroundStyle(C.text)
                                        Text(reply.body)
                                            .font(.caption)
                                            .foregroundStyle(C.textMuted)
                                            .lineLimit(2)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                "Reply from \(reply.senderDisplayName): \(reply.body)"
                            )
                        }

                        if showsDiscussion,
                           item.threadReplyCount > UInt64(item.replyPreviews.count) {
                            Button(action: openDiscussion) {
                                Label(
                                    "Open discussion",
                                    systemImage: "bubble.left.and.bubble.right.fill"
                                )
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(C.watch)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                "Open discussion with \(item.threadReplyCount) replies"
                            )
                        }
                    }
                    .padding(9)
                    .background(C.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                }

                HStack(spacing: 12) {
                    if item.reactionCount > 0 {
                        Label("\(item.reactionCount) Energy", systemImage: "bolt.fill")
                    }
                    if item.threadReplyCount > 0 {
                        Label("\(item.threadReplyCount) replies", systemImage: "bubble.left.and.bubble.right")
                    }
                    if item.isOwn, item.readReceiptCount > 0 {
                        Label("Read by \(item.readReceiptCount)", systemImage: "checkmark.circle.fill")
                    }
                    if let state = item.localSendState {
                        Text(MatrixNativeCopy.label(for: state))
                    }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(C.textMuted)

                HStack(spacing: 0) {
                    MatrixNativeMessageActionButton(
                        label: item.reactionCount > 0
                            ? "\(item.reactionCount) Energy"
                            : "Add Energy",
                        systemImage: "bolt",
                        enabled: item.actions.canAddEnergy
                    ) {
                        energyPresented = true
                    }

                    MatrixNativeMessageActionButton(
                        label: "Reply",
                        systemImage: "arrowshape.turn.up.left",
                        enabled: item.actions.canReply
                    ) {
                        openDiscussion()
                    }

                    MatrixNativeMessageActionButton(
                        label: "Echo",
                        systemImage: "wave.3.right",
                        enabled: canEchoToWaves
                    ) {
                        waveEchoPresented = true
                    }

                    ShareLink(item: item.body) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(
                                canNativeShare
                                    ? C.textMuted
                                    : C.textTertiary.opacity(0.45)
                            )
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canNativeShare)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Share message")

                    Menu {
                        if item.actions.canEdit {
                            Button {
                                editPresented = true
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                        }
                        if item.actions.canPin {
                            Button {
                                setPinned(!item.actions.isPinned)
                            } label: {
                                Label(
                                    item.actions.isPinned ? "Unpin" : "Pin",
                                    systemImage: item.actions.isPinned
                                        ? "pin.slash"
                                        : "pin"
                                )
                            }
                        }
                        if item.actions.canReport {
                            Button {
                                reportPresented = true
                            } label: {
                                Label("Report", systemImage: "exclamationmark.bubble")
                            }
                        }
                        if canEchoToAtmo {
                            Button {
                                atmoEchoPresented = true
                            } label: {
                                Label("Echo to My Atmo", systemImage: "wave.3.right")
                            }
                        }
                        if item.actions.canRedact {
                            Button(role: .destructive) {
                                deleteConfirmationPresented = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(C.textMuted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .disabled(!hasMoreActions)
                    .accessibilityLabel("More message actions")
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, C.pagePad)
        .padding(.vertical, 9)
        .background(item.isOwn ? C.watch.opacity(0.035) : Color.clear)
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $energyPresented) {
            MatrixNativeEnergyPicker(
                item: item,
                select: {
                    energyPresented = false
                    addEnergy($0)
                }
            )
            .presentationDetents([.height(330), .medium])
        }
        .sheet(isPresented: $editPresented) {
            MatrixNativeEditMessageSheet(
                initialBody: item.body,
                save: {
                    editPresented = false
                    edit($0)
                },
                cancel: { editPresented = false }
            )
            .presentationDetents([.height(300)])
        }
        .sheet(isPresented: $reportPresented) {
            MatrixNativeReportMessageSheet(
                submit: {
                    reportPresented = false
                    report($0)
                },
                cancel: { reportPresented = false }
            )
            .presentationDetents([.height(340)])
        }
        .sheet(isPresented: $atmoEchoPresented) {
            MatrixNativeEchoToAtmoSheet(
                roomID: roomID,
                item: item,
                dismiss: { atmoEchoPresented = false }
            )
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $waveEchoPresented) {
            MatrixNativeEchoToWavesSheet(
                sourceRoomID: roomID,
                sourceIsEncrypted: roomIsEncrypted,
                item: item,
                dismiss: { waveEchoPresented = false }
            )
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog(
            "Delete this message?",
            isPresented: $deleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Delete message", role: .destructive, action: redact)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the message from the Wave. The action cannot be undone.")
        }
    }
}

private struct MatrixNativeEchoToWavesSheet: View {
    let sourceRoomID: String
    let sourceIsEncrypted: Bool
    let item: MatrixTimelineItem
    let dismiss: () -> Void

    @EnvironmentObject private var matrixSession: MatrixNativeSessionController
    @State private var waves: [MatrixWaveSummary] = []
    @State private var selectedRoomIDs = Set<String>()
    @State private var query = ""
    @State private var isLoading = true
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var requestID = UUID().uuidString.lowercased()

    private var visibleWaves: [MatrixWaveSummary] {
        let normalized = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        guard !normalized.isEmpty else { return waves }
        return waves.filter {
            $0.name.lowercased().contains(normalized)
                || ($0.topic?.lowercased().contains(normalized) == true)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Ripple preview") {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.senderDisplayName)
                            .font(.subheadline.bold())
                        Text(item.body)
                            .font(.body)
                            .lineLimit(4)
                    }
                    .accessibilityElement(children: .combine)
                }

                Section {
                    if isLoading {
                        HStack {
                            Spacer()
                            ProgressView().tint(C.watch)
                            Spacer()
                        }
                    } else if visibleWaves.isEmpty {
                        ContentUnavailableView(
                            "No eligible Waves",
                            systemImage: "wave.3.right",
                            description: Text(
                                sourceIsEncrypted
                                    ? "Encrypted Ripples cannot be echoed."
                                    : "Only joined, unencrypted Waves where you may post are shown."
                            )
                        )
                    } else {
                        ForEach(visibleWaves) { wave in
                            Button {
                                toggle(wave.id)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(
                                        systemName: selectedRoomIDs.contains(
                                            wave.id
                                        )
                                            ? "checkmark.circle.fill"
                                            : "circle"
                                    )
                                    .foregroundStyle(
                                        selectedRoomIDs.contains(wave.id)
                                            ? C.watch
                                            : C.textTertiary
                                    )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(wave.name)
                                            .font(.subheadline.bold())
                                            .foregroundStyle(C.text)
                                        if let topic = wave.topic,
                                           !topic.isEmpty {
                                            Text(topic)
                                                .font(.caption)
                                                .foregroundStyle(C.textMuted)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                "\(selectedRoomIDs.contains(wave.id) ? "Selected" : "Select") \(wave.name)"
                            )
                        }
                    }
                } header: {
                    Text("Joined Waves")
                } footer: {
                    Text(
                        "\(selectedRoomIDs.count) selected · up to \(MatrixNativeMatrixEchoContract.maximumDestinations). Encrypted and direct conversations are never included."
                    )
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityLabel("Echo error: \(errorMessage)")
                    }
                }
            }
            .searchable(text: $query, prompt: "Search Waves")
            .navigationTitle("Echo to Waves")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: dismiss)
                        .disabled(isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSending ? "Echoing…" : "Echo") {
                        Task { await echo() }
                    }
                    .disabled(selectedRoomIDs.isEmpty || isSending)
                }
            }
            .task(id: sourceRoomID) {
                await load()
            }
        }
    }

    private func toggle(_ roomID: String) {
        if selectedRoomIDs.contains(roomID) {
            selectedRoomIDs.remove(roomID)
        } else if selectedRoomIDs.count
                    < MatrixNativeMatrixEchoContract.maximumDestinations {
            selectedRoomIDs.insert(roomID)
        }
    }

    @MainActor
    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        guard !sourceIsEncrypted else {
            waves = []
            errorMessage =
                "Encrypted Ripples cannot be echoed until secure cross-Wave forwarding is verified."
            return
        }
        do {
            waves = try await matrixSession.joinedWaveDestinations(
                excludingRoomID: sourceRoomID
            )
            .filter {
                MatrixNativeMatrixEchoContract.canEcho(
                    existingReference: item.westreemReference,
                    to: $0.id
                )
            }
        } catch {
            waves = []
            errorMessage = MatrixNativeCopy.message(for: error)
        }
    }

    @MainActor
    private func echo() async {
        let destinations = waves.map(\.id).filter(selectedRoomIDs.contains)
        guard !destinations.isEmpty, !isSending else { return }
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        do {
            let result = try await matrixSession.echoMessage(
                item,
                sourceRoomID: sourceRoomID,
                sourceIsEncrypted: sourceIsEncrypted,
                destinationRoomIDs: destinations,
                requestID: requestID
            )
            if result.failedRoomIDs.isEmpty {
                dismiss()
            } else {
                selectedRoomIDs = Set(result.failedRoomIDs)
                errorMessage =
                    "Echoed to \(result.deliveredRoomIDs.count) \(result.deliveredRoomIDs.count == 1 ? "Wave" : "Waves"); \(result.failedRoomIDs.count) failed. Retry keeps the same delivery identity."
            }
        } catch {
            errorMessage = MatrixNativeCopy.message(for: error)
        }
    }
}

private struct MatrixNativeEchoToAtmoSheet: View {
    let roomID: String
    let item: MatrixTimelineItem
    let dismiss: () -> Void

    @State private var quote = ""
    @State private var isPublishing = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Ripple preview") {
                    Text(item.senderDisplayName)
                        .font(.subheadline.bold())
                    Text(item.body)
                        .font(.body)
                        .lineLimit(5)
                }
                Section("Optional quote") {
                    TextField("Add your perspective…", text: $quote, axis: .vertical)
                        .lineLimit(2...6)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Echo to My Atmo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: dismiss)
                        .disabled(isPublishing)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isPublishing ? "Echoing…" : "Echo") {
                        Task { await publish() }
                    }
                    .disabled(isPublishing)
                }
            }
        }
    }

    @MainActor
    private func publish() async {
        guard let eventID = item.reference.remoteEventID else {
            errorMessage = "This message has not been confirmed by WeStreem yet."
            return
        }
        isPublishing = true
        errorMessage = nil
        defer { isPublishing = false }
        let cleanQuote = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let repository = WestreemAtmoV2Repository(
                transport: APIClient.shared,
                rollout: AtmoV2Rollout(localEnabled: true)
            )
            _ = try await repository.create(
                AtmoV2PostDraft(
                    echo: AtmoV2EchoDraft(
                        sourceType: "MATRIX_EVENT",
                        sourceId: "\(roomID)|\(eventID)",
                        sourceUrl: nil,
                        quote: cleanQuote.isEmpty ? nil : cleanQuote
                    )
                )
            )
            NotificationCenter.default.post(name: .rippleCreated, object: nil)
            dismiss()
        } catch {
            errorMessage = "This Ripple cannot be shared publicly. It may be private, encrypted, removed, or disabled by the Wave."
        }
    }
}

private struct MatrixNativeMessageActionButton: View {
    let label: String
    let systemImage: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(enabled ? C.textMuted : C.textTertiary.opacity(0.45))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(label)
        .accessibilityHint(enabled ? "Activates this Vibe message action" : "Unavailable")
    }
}

private struct MatrixNativeWestreemReferenceCard: View {
    let reference: MatrixNativeWestreemReferenceV1

    private var destination: URL? {
        MatrixNativeWestreemReferenceContract.safeWestreemURL(
            reference.canonicalURL
        )
    }

    var body: some View {
        Group {
            if let destination {
                Link(destination: destination) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(reference.entityType == "event" ? "WeStreem Event" : "WeStreem content"): \(reference.title)"
        )
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: reference.entityType == "event"
                ? "calendar.badge.clock"
                : "play.rectangle.on.rectangle")
                .font(.title3)
                .foregroundStyle(C.watch)
                .frame(width: 40, height: 40)
                .background(C.watch.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(reference.entityType == "event"
                    ? "WESTREEM EVENT"
                    : "WESTREEM \(reference.entityType.uppercased())")
                    .font(.caption2.bold())
                    .foregroundStyle(C.watch)
                Text(reference.title)
                    .font(.subheadline.bold())
                    .foregroundStyle(C.text)
                    .lineLimit(2)
                if let summary = reference.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(C.textMuted)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
            if destination != nil {
                Image(systemName: "arrow.up.right")
                    .font(.caption.bold())
                    .foregroundStyle(C.textTertiary)
            }
        }
        .padding(12)
        .background(C.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(C.borderSubtle))
    }
}

private struct MatrixNativeWaveManagementView: View {
    let room: MatrixWaveSummary
    let didLeave: () -> Void

    @EnvironmentObject private var matrixSession: MatrixNativeSessionController
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: MatrixNativeWaveManagementSnapshot?
    @State private var name = ""
    @State private var topic = ""
    @State private var access = MatrixNativeWaveAccess.inviteOnly
    @State private var history = MatrixNativeWaveHistory.invited
    @State private var notificationMode = MatrixNativeWaveNotificationMode.mentionsOnly
    @State private var avatarSelection: PhotosPickerItem?
    @State private var avatarUpload: MatrixNativeUpload?
    @State private var removeAvatar = false
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var leaveConfirmationPresented = false
    @State private var errorMessage: String?
    @State private var noticeMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading Wave settings…")
                        .tint(C.watch)
                } else if let snapshot {
                    Form {
                        Section("Wave profile") {
                            TextField("Wave name", text: $name)
                                .disabled(!snapshot.mayEditProfile)
                            TextField("Topic", text: $topic, axis: .vertical)
                                .lineLimit(2...6)
                                .disabled(!snapshot.mayEditProfile)

                            HStack {
                                Label(
                                    avatarUpload == nil
                                        ? (snapshot.avatarURL == nil
                                            ? "No Wave avatar"
                                            : "Current Wave avatar")
                                        : "New avatar selected",
                                    systemImage: "photo.circle"
                                )
                                Spacer()
                                if snapshot.mayEditProfile {
                                    PhotosPicker(
                                        selection: $avatarSelection,
                                        matching: .images
                                    ) {
                                        Text("Choose")
                                    }
                                    .accessibilityLabel("Choose Wave avatar")
                                }
                            }
                            if snapshot.mayEditProfile,
                               snapshot.avatarURL != nil || avatarUpload != nil {
                                Toggle("Remove avatar", isOn: $removeAvatar)
                                    .onChange(of: removeAvatar) { _, value in
                                        if value { avatarUpload = nil }
                                    }
                            }
                            if snapshot.mayEditProfile {
                                Button {
                                    Task { await saveProfile() }
                                } label: {
                                    Label("Save profile", systemImage: "checkmark.circle")
                                }
                                .disabled(
                                    isSaving
                                        || name.trimmingCharacters(
                                            in: .whitespacesAndNewlines
                                        ).isEmpty
                                )
                            }
                        }

                        Section("Access and history") {
                            Picker("Who can join", selection: $access) {
                                ForEach(MatrixNativeWaveAccess.allCases, id: \.self) {
                                    Text(accessLabel($0)).tag($0)
                                }
                            }
                            .disabled(!snapshot.mayEditAccess)

                            Picker("Who can read history", selection: $history) {
                                ForEach(MatrixNativeWaveHistory.allCases, id: \.self) {
                                    Text(historyLabel($0)).tag($0)
                                }
                            }
                            .disabled(!snapshot.mayEditHistory)

                            if snapshot.mayEditAccess && snapshot.mayEditHistory {
                                Button {
                                    Task { await saveAccess() }
                                } label: {
                                    Label("Save access", systemImage: "lock.shield")
                                }
                                .disabled(isSaving)
                            }

                            if snapshot.isEncrypted {
                                Label(
                                    "This Wave is encrypted. Access changes do not expose room keys or history.",
                                    systemImage: "lock.fill"
                                )
                                .font(.footnote)
                                .foregroundStyle(C.textMuted)
                            }
                        }

                        Section("Notifications") {
                            Picker("Notify me", selection: $notificationMode) {
                                ForEach(
                                    MatrixNativeWaveNotificationMode.allCases,
                                    id: \.self
                                ) {
                                    Text(notificationLabel($0)).tag($0)
                                }
                            }
                            Button {
                                Task { await saveNotification() }
                            } label: {
                                Label("Save notifications", systemImage: "bell.badge")
                            }
                            .disabled(isSaving)
                        }

                        Section("People and content") {
                            if snapshot.mayInvite {
                                NavigationLink {
                                    MatrixNativeInviteUsersView(
                                        roomID: room.id,
                                        destinationName: room.name,
                                        destinationType: .wave
                                    )
                                    .environmentObject(matrixSession)
                                } label: {
                                    Label("Invite people", systemImage: "person.badge.plus")
                                }
                            }

                            NavigationLink {
                                MatrixNativeWaveMembersView(
                                    room: room,
                                    permissions: snapshot
                                )
                                .environmentObject(matrixSession)
                            } label: {
                                Label("Members and roles", systemImage: "person.2")
                            }

                            NavigationLink {
                                MatrixNativeWaveSearchView(room: room)
                                    .environmentObject(matrixSession)
                            } label: {
                                Label("Search this Wave", systemImage: "magnifyingglass")
                            }

                            NavigationLink {
                                MatrixNativeWaveRulesView(room: room)
                                    .environmentObject(matrixSession)
                            } label: {
                                Label("Rules", systemImage: "list.number")
                            }
                        }

                        Section {
                            Button(role: .destructive) {
                                leaveConfirmationPresented = true
                            } label: {
                                Label("Leave Wave", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                            .disabled(isSaving)
                        } footer: {
                            Text(
                                "Leaving ends your Wave membership. You may need a new invitation to return."
                            )
                        }

                        if let noticeMessage {
                            Section {
                                Label(noticeMessage, systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(C.watch)
                            }
                        }
                        if let errorMessage {
                            Section {
                                Label(
                                    errorMessage,
                                    systemImage: "exclamationmark.triangle"
                                )
                                .foregroundStyle(Color.red)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                } else {
                    ContentUnavailableView {
                        Label("Settings unavailable", systemImage: "gear.badge.xmark")
                    } description: {
                        Text(errorMessage ?? "WeStreem could not load this Wave.")
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                    }
                }
            }
            .background(C.bg.ignoresSafeArea())
            .navigationTitle("Wave Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task(id: room.id) { await load() }
            .onChange(of: avatarSelection) { _, item in
                guard let item else { return }
                Task { await prepareAvatar(item) }
            }
            .confirmationDialog(
                "Leave this Wave?",
                isPresented: $leaveConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Leave Wave", role: .destructive) {
                    Task { await leave() }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    @MainActor
    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let value = try await matrixSession.waveManagement(roomID: room.id)
            snapshot = value
            name = value.name
            topic = value.topic
            access = value.access
            history = value.history
            notificationMode = value.notificationMode
            errorMessage = nil
        } catch {
            errorMessage = MatrixNativeCopy.message(for: error)
        }
    }

    @MainActor
    private func prepareAvatar(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  !data.isEmpty
            else {
                throw MatrixNativeMediaError.invalidAttachment
            }
            let type = item.supportedContentTypes.first {
                $0.conforms(to: .image) && $0.preferredMIMEType != nil
            }
            guard let mimeType = type?.preferredMIMEType else {
                throw MatrixNativeMediaError.unsupportedAttachment
            }
            avatarUpload = MatrixNativeUpload(
                kind: .image,
                data: data,
                filename: "wave-avatar.\(type?.preferredFilenameExtension ?? "jpg")",
                mimeType: mimeType
            )
            removeAvatar = false
            errorMessage = nil
        } catch {
            avatarUpload = nil
            errorMessage = MatrixNativeCopy.message(for: error)
        }
    }

    @MainActor
    private func saveProfile() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await matrixSession.updateWaveProfile(
                roomID: room.id,
                name: name,
                topic: topic,
                avatar: avatarUpload,
                removeAvatar: removeAvatar
            )
            avatarUpload = nil
            noticeMessage = "Wave profile saved."
            errorMessage = nil
            await load()
        } catch {
            errorMessage = MatrixNativeCopy.message(for: error)
        }
    }

    @MainActor
    private func saveAccess() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await matrixSession.updateWaveAccess(
                roomID: room.id,
                access: access,
                history: history
            )
            noticeMessage = "Wave access saved."
            errorMessage = nil
        } catch {
            errorMessage = MatrixNativeCopy.message(for: error)
        }
    }

    @MainActor
    private func saveNotification() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await matrixSession.updateWaveNotification(
                roomID: room.id,
                mode: notificationMode
            )
            noticeMessage = "Notification preference saved."
            errorMessage = nil
        } catch {
            errorMessage = MatrixNativeCopy.message(for: error)
        }
    }

    @MainActor
    private func leave() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await matrixSession.leaveWave(roomID: room.id)
            didLeave()
        } catch {
            errorMessage = MatrixNativeCopy.message(for: error)
        }
    }

    private func accessLabel(_ value: MatrixNativeWaveAccess) -> String {
        switch value {
        case .publicRoom: "Anyone"
        case .inviteOnly: "Invitation only"
        case .requestToJoin: "Request to join"
        }
    }

    private func historyLabel(_ value: MatrixNativeWaveHistory) -> String {
        switch value {
        case .invited: "From invitation"
        case .joined: "From joining"
        case .shared: "All members"
        case .worldReadable: "Anyone"
        }
    }

    private func notificationLabel(
        _ value: MatrixNativeWaveNotificationMode
    ) -> String {
        switch value {
        case .allMessages: "All messages"
        case .mentionsOnly: "Mentions and keywords"
        case .muted: "Nothing"
        }
    }
}

private struct MatrixNativeWaveMembersView: View {
    let room: MatrixWaveSummary
    let permissions: MatrixNativeWaveManagementSnapshot

    @EnvironmentObject private var matrixSession: MatrixNativeSessionController
    @State private var members: [MatrixNativeWaveMember] = []
    @State private var isLoading = true
    @State private var busyUserID: String?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if isLoading {
                ProgressView("Loading Wave members…")
                    .tint(C.watch)
            } else if members.isEmpty {
                ContentUnavailableView(
                    "No members",
                    systemImage: "person.2.slash",
                    description: Text("This Wave has no active members.")
                )
            } else {
                ForEach(members) { member in
                    HStack(spacing: 12) {
                        MatrixNativeAvatar(
                            name: member.displayName,
                            imageURL: member.avatarURL,
                            size: 42
                        )
                        VStack(alignment: .leading, spacing: 3) {
                            Text(member.displayName)
                                .font(.subheadline.bold())
                            Text(member.userID)
                                .font(.caption)
                                .foregroundStyle(C.textMuted)
                                .lineLimit(1)
                            Text("\(roleLabel(member.role)) · \(stateLabel(member.state))")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(C.watch)
                        }
                        Spacer()
                        if busyUserID == member.userID {
                            ProgressView().tint(C.watch)
                        } else if canManage(member) {
                            Menu {
                                if permissions.mayManageRoles,
                                   member.state == .joined {
                                    Section("Role") {
                                        roleButton(.administrator, member: member)
                                        roleButton(.moderator, member: member)
                                        roleButton(.member, member: member)
                                    }
                                }
                                if permissions.mayKick,
                                   member.state == .joined
                                    || member.state == .invited {
                                    Button(role: .destructive) {
                                        Task { await moderate(.kick, member: member) }
                                    } label: {
                                        Label("Remove from Wave", systemImage: "person.badge.minus")
                                    }
                                }
                                if permissions.mayBan, member.state != .banned {
                                    Button(role: .destructive) {
                                        Task { await moderate(.ban, member: member) }
                                    } label: {
                                        Label("Ban", systemImage: "hand.raised")
                                    }
                                }
                                if permissions.mayBan, member.state == .banned {
                                    Button {
                                        Task { await moderate(.unban, member: member) }
                                    } label: {
                                        Label("Unban", systemImage: "person.badge.plus")
                                    }
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.title3)
                            }
                            .accessibilityLabel("Manage \(member.displayName)")
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.red)
            }
        }
        .scrollContentBackground(.hidden)
        .background(C.bg)
        .navigationTitle("Members")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task(id: room.id) { await load() }
    }

    private func roleButton(
        _ role: MatrixNativeWaveMemberRole,
        member: MatrixNativeWaveMember
    ) -> some View {
        Button {
            Task { await updateRole(role, member: member) }
        } label: {
            Label(
                roleLabel(role),
                systemImage: member.role == role ? "checkmark" : "person.crop.circle"
            )
        }
        .disabled(member.role == role)
    }

    @MainActor
    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            members = try await matrixSession.waveMembers(roomID: room.id)
            errorMessage = nil
        } catch {
            errorMessage = MatrixNativeCopy.message(for: error)
        }
    }

    @MainActor
    private func updateRole(
        _ role: MatrixNativeWaveMemberRole,
        member: MatrixNativeWaveMember
    ) async {
        busyUserID = member.userID
        defer { busyUserID = nil }
        do {
            try await matrixSession.updateWaveMemberRole(
                roomID: room.id,
                userID: member.userID,
                role: role
            )
            await load()
        } catch {
            errorMessage = MatrixNativeCopy.message(for: error)
        }
    }

    @MainActor
    private func moderate(
        _ action: MatrixNativeWaveModerationAction,
        member: MatrixNativeWaveMember
    ) async {
        busyUserID = member.userID
        defer { busyUserID = nil }
        do {
            try await matrixSession.moderateWaveMember(
                roomID: room.id,
                userID: member.userID,
                action: action,
                reason: nil
            )
            await load()
        } catch {
            errorMessage = MatrixNativeCopy.message(for: error)
        }
    }

    private func canManage(_ member: MatrixNativeWaveMember) -> Bool {
        MatrixNativeWaveManagementContract.mayManage(
            isCurrentUser: member.isCurrentUser,
            isService: member.isService,
            role: member.role
        )
            && (permissions.mayManageRoles
                || permissions.mayKick
                || permissions.mayBan)
    }

    private func roleLabel(_ role: MatrixNativeWaveMemberRole) -> String {
        switch role {
        case .creator: "Creator"
        case .administrator: "Administrator"
        case .moderator: "Moderator"
        case .member: "Member"
        }
    }

    private func stateLabel(_ state: MatrixNativeWaveMemberState) -> String {
        switch state {
        case .joined: "Joined"
        case .invited: "Invited"
        case .banned: "Banned"
        case .requested: "Requested"
        }
    }
}

private struct MatrixNativeWaveSearchView: View {
    let room: MatrixWaveSummary

    @EnvironmentObject private var matrixSession: MatrixNativeSessionController
    @State private var query = ""
    @State private var results: [MatrixNativeWaveSearchResult] = []
    @State private var isSearching = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if isSearching {
                ProgressView("Searching Vibes…")
                    .tint(C.watch)
            } else if query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 {
                ContentUnavailableView(
                    "Search this Wave",
                    systemImage: "magnifyingglass",
                    description: Text("Enter at least two characters.")
                )
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ForEach(results) { result in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(result.senderDisplayName)
                                .font(.caption.bold())
                            Spacer()
                            Text(result.timestamp, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(C.textMuted)
                        }
                        Text(result.body)
                            .font(.body)
                            .lineLimit(5)
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.red)
            }
        }
        .scrollContentBackground(.hidden)
        .background(C.bg)
        .navigationTitle("Search Wave")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Messages in \(room.name)")
        .task(id: query) {
            do {
                try await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await search()
            } catch {}
        }
    }

    @MainActor
    private func search() async {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 2 else {
            results = []
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            results = try await matrixSession.searchWave(
                roomID: room.id,
                query: normalized
            )
            errorMessage = nil
        } catch {
            errorMessage = MatrixNativeCopy.message(for: error)
        }
    }
}

private struct MatrixNativeWaveRulesView: View {
    let room: MatrixWaveSummary

    @EnvironmentObject private var matrixSession: MatrixNativeSessionController
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: MatrixNativeWaveRulesSnapshot?
    @State private var draftRules: [MatrixNativeWaveRule] = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading Wave rules…")
                        .tint(C.watch)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Only Vibe members with permission to manage this Wave can change its rules.")
                                .font(.footnote)
                                .foregroundStyle(C.textMuted)

                            if draftRules.isEmpty {
                                ContentUnavailableView {
                                    Label("No Wave rules", systemImage: "list.number")
                                } description: {
                                    Text(snapshot?.mayEdit == true
                                        ? "Add the first structured rule."
                                        : "The moderators have not published rules.")
                                }
                                .foregroundStyle(C.text)
                                .padding(.vertical, 24)
                            }

                            ForEach(Array(draftRules.enumerated()), id: \.element.id) {
                                index, rule in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text("Rule \(index + 1)")
                                            .font(.caption.bold())
                                            .foregroundStyle(C.watch)
                                        Spacer()
                                        if snapshot?.mayEdit == true {
                                            Button {
                                                moveRule(index, by: -1)
                                            } label: {
                                                Image(systemName: "arrow.up")
                                            }
                                            .disabled(index == 0)
                                            Button {
                                                moveRule(index, by: 1)
                                            } label: {
                                                Image(systemName: "arrow.down")
                                            }
                                            .disabled(index == draftRules.count - 1)
                                            Button(role: .destructive) {
                                                draftRules.remove(at: index)
                                                normalizeOrder()
                                            } label: {
                                                Image(systemName: "trash")
                                            }
                                        }
                                    }

                                    if snapshot?.mayEdit == true {
                                        TextEditor(text: ruleBinding(at: index))
                                            .scrollContentBackground(.hidden)
                                            .frame(minHeight: 86)
                                            .padding(8)
                                            .background(
                                                C.bg.opacity(0.45),
                                                in: RoundedRectangle(cornerRadius: 10)
                                            )
                                            .accessibilityLabel("Rule \(index + 1) text")
                                    } else {
                                        Text(rule.text)
                                            .font(.body)
                                            .foregroundStyle(C.text)
                                    }
                                }
                                .padding(12)
                                .background(C.surface, in: RoundedRectangle(cornerRadius: 14))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(C.borderSubtle)
                                )
                            }

                            if snapshot?.mayEdit == true,
                               draftRules.count < MatrixNativeWaveRulesContract.maximumRules {
                                Button {
                                    draftRules.append(
                                        MatrixNativeWaveRule(
                                            id: UUID().uuidString.lowercased(),
                                            text: "",
                                            order: draftRules.count
                                        )
                                    )
                                } label: {
                                    Label("Add rule", systemImage: "plus.circle.fill")
                                }
                                .font(.subheadline.bold())
                                .foregroundStyle(C.watch)
                            }

                            if let state = snapshot?.state {
                                Text("Revision \(state.revision) · Updated \(state.updatedAt)")
                                    .font(.caption2)
                                    .foregroundStyle(C.textTertiary)
                            }

                            if let errorMessage {
                                Label(errorMessage, systemImage: "exclamationmark.triangle")
                                    .font(.footnote)
                                    .foregroundStyle(Color.red)
                            }
                        }
                        .padding(C.pagePad)
                    }
                }
            }
            .background(C.bg.ignoresSafeArea())
            .navigationTitle("Wave Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if snapshot?.mayEdit == true {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            Task { await save() }
                        }
                        .disabled(isSaving || !draftIsValid)
                    }
                }
            }
        }
        .task(id: room.id) { await load() }
    }

    private var draftIsValid: Bool {
        let test = MatrixNativeWaveRulesState(
            revision: max((snapshot?.state?.revision ?? 0) + 1, 1),
            rules: draftRules,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            updatedByWestreemUserID: matrixSession.currentWestreemUserID ?? ""
        )
        return (try? MatrixNativeWaveRulesContract.validate(test)) != nil
    }

    private func ruleBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { draftRules.indices.contains(index) ? draftRules[index].text : "" },
            set: { value in
                guard draftRules.indices.contains(index) else { return }
                let rule = draftRules[index]
                draftRules[index] = MatrixNativeWaveRule(
                    id: rule.id,
                    text: String(value.prefix(
                        MatrixNativeWaveRulesContract.maximumRuleTextLength
                    )),
                    locale: rule.locale,
                    order: rule.order
                )
            }
        )
    }

    private func moveRule(_ index: Int, by offset: Int) {
        let target = index + offset
        guard draftRules.indices.contains(index), draftRules.indices.contains(target) else {
            return
        }
        draftRules.swapAt(index, target)
        normalizeOrder()
    }

    private func normalizeOrder() {
        draftRules = draftRules.enumerated().map { index, rule in
            MatrixNativeWaveRule(
                id: rule.id,
                text: rule.text,
                locale: rule.locale,
                order: index
            )
        }
    }

    @MainActor
    private func load() async {
        isLoading = true
        do {
            let value = try await matrixSession.waveRules(roomID: room.id)
            snapshot = value
            draftRules = (value.state?.rules ?? []).sorted { $0.order < $1.order }
            errorMessage = nil
        } catch {
            errorMessage = MatrixNativeCopy.message(for: error)
        }
        isLoading = false
    }

    @MainActor
    private func save() async {
        guard snapshot?.mayEdit == true else { return }
        isSaving = true
        normalizeOrder()
        do {
            try await matrixSession.updateWaveRules(
                draftRules,
                currentRevision: snapshot?.state?.revision ?? 0,
                roomID: room.id
            )
            await load()
        } catch {
            errorMessage = MatrixNativeCopy.message(for: error)
        }
        isSaving = false
    }
}

private struct MatrixNativeEnergyPicker: View {
    let item: MatrixTimelineItem
    let select: (String) -> Void

    var body: some View {
        NavigationStack {
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 10
            ) {
                ForEach(MatrixNativeEnergyOption.all) { option in
                    let summary = item.energy.first { $0.key == option.id }
                    Button {
                        select(option.id)
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: option.systemImage)
                                .foregroundStyle(C.watch)
                            Text(option.label)
                                .foregroundStyle(C.text)
                            Spacer()
                            if summary?.isSelectedByCurrentUser == true {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(C.watch)
                            } else if let count = summary?.count, count > 0 {
                                Text("\(count)")
                                    .font(.caption.bold())
                                    .foregroundStyle(C.textMuted)
                            }
                        }
                        .padding(12)
                        .background(C.surface, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(C.borderSubtle))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        summary?.isSelectedByCurrentUser == true
                            ? "Remove \(option.label) Energy"
                            : "Add \(option.label) Energy"
                    )
                }
            }
            .padding(C.pagePad)
            .background(C.bg.ignoresSafeArea())
            .navigationTitle("Add Energy")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct MatrixNativeEditMessageSheet: View {
    let initialBody: String
    let save: (String) -> Void
    let cancel: () -> Void

    @State private var bodyText: String

    init(
        initialBody: String,
        save: @escaping (String) -> Void,
        cancel: @escaping () -> Void
    ) {
        self.initialBody = initialBody
        self.save = save
        self.cancel = cancel
        _bodyText = State(initialValue: initialBody)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                TextEditor(text: $bodyText)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 130)
                    .background(C.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(C.borderSubtle))
                    .accessibilityLabel("Edited message")
                Spacer()
            }
            .padding(C.pagePad)
            .background(C.bg.ignoresSafeArea())
            .navigationTitle("Edit message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let normalized =
                            MatrixNativeWaveActionPolicy.normalizedMessage(bodyText) {
                            save(normalized)
                        }
                    }
                    .disabled(
                        MatrixNativeWaveActionPolicy.normalizedMessage(bodyText) == nil
                    )
                }
            }
        }
    }
}

private struct MatrixNativeReportMessageSheet: View {
    let submit: (String) -> Void
    let cancel: () -> Void

    @State private var reason = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Tell Vibe moderators what is wrong. The message and this reason will be included in the report.")
                    .font(.footnote)
                    .foregroundStyle(C.textMuted)
                TextEditor(text: $reason)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 140)
                    .background(C.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(C.borderSubtle))
                    .accessibilityLabel("Report reason")
                Spacer()
            }
            .padding(C.pagePad)
            .background(C.bg.ignoresSafeArea())
            .navigationTitle("Report message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Report") {
                        if let normalized =
                            MatrixNativeWaveActionPolicy.normalizedReportReason(reason) {
                            submit(normalized)
                        }
                    }
                    .disabled(
                        MatrixNativeWaveActionPolicy.normalizedReportReason(reason) == nil
                    )
                }
            }
        }
    }
}

private struct MatrixNativeOptimisticMessageRow: View {
    let message: MatrixNativeWaveRoomView.OptimisticMessage
    let retry: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            MatrixNativeAvatar(name: "You", size: 36)
            VStack(alignment: .leading, spacing: 5) {
                Text("You").font(.subheadline.bold()).foregroundStyle(C.text)
                Text(message.body).font(.body).foregroundStyle(C.text)
                HStack(spacing: 10) {
                    Text(MatrixNativeCopy.label(for: message.state))
                    if case let .failed(recoverable) = message.state {
                        if recoverable {
                            Button("Retry", action: retry).fontWeight(.semibold)
                        }
                        Button("Remove", action: remove)
                    }
                }
                .font(.caption)
                .foregroundStyle(MatrixNativeCopy.isFailure(message.state) ? Color.red : C.textMuted)
            }
            Spacer()
        }
        .padding(.horizontal, C.pagePad)
        .padding(.vertical, 9)
        .background(C.watch.opacity(0.035))
        .accessibilityElement(children: .combine)
    }
}

private struct MatrixNativeDirectoryHeader: View {
    let eyebrow: String
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow).font(.caption2.bold()).tracking(1.5).foregroundStyle(C.watch)
            Text(title).font(.title2.bold()).foregroundStyle(C.text)
            Text(message).font(.subheadline).foregroundStyle(C.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8)
    }
}

private struct MatrixNativeVibeHero: View {
    let space: MatrixVibeSummary
    let rooms: [MatrixWaveSummary]
    let permissions: MatrixNativeSpacePermissionSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                MatrixNativeAvatar(
                    name: space.name,
                    imageURL: space.avatarURL,
                    size: 64
                )
                VStack(alignment: .leading, spacing: 5) {
                    Text(space.name).font(.title3.bold()).foregroundStyle(C.text)
                    if let topic = space.topic, !topic.isEmpty {
                        Text(topic)
                            .font(.footnote)
                            .foregroundStyle(C.textMuted)
                            .lineLimit(4)
                    } else {
                        Text("A WeStreem community")
                            .font(.footnote)
                            .foregroundStyle(C.textMuted)
                    }
                }
                Spacer()
                Image(systemName: "person.3.sequence.fill")
                    .foregroundStyle(C.watch)
            }

            HStack(spacing: 8) {
                MatrixNativeVibeMetric(
                    value: "\(space.joinedMemberCount)",
                    label: "Members",
                    systemImage: "person.2"
                )
                MatrixNativeVibeMetric(
                    value: "\(rooms.filter { !$0.isNestedSpace }.count)",
                    label: "Waves",
                    systemImage: "wave.3.right"
                )
                MatrixNativeVibeMetric(
                    value: "\(rooms.filter(\.isNestedSpace).count)",
                    label: "Groups",
                    systemImage: "folder"
                )
                MatrixNativeVibeMetric(
                    value: "\(rooms.filter { $0.activeCallParticipantCount > 0 }.count)",
                    label: "Live",
                    systemImage: "waveform"
                )
            }

            HStack(spacing: 7) {
                Label("Verified Vibe", systemImage: "checkmark.shield")
                if permissions.mayCreateWave {
                    Label("Can create Waves", systemImage: "plus.bubble")
                }
                if permissions.mayInviteMembers {
                    Label("Can invite", systemImage: "person.badge.plus")
                }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(C.textMuted)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        }
        .padding(16)
        .background(C.surface, in: RoundedRectangle(cornerRadius: C.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: C.cardRadius).stroke(C.borderSubtle))
    }
}

private struct MatrixNativeVibeMetric: View {
    let value: String
    let label: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .foregroundStyle(C.watch)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.subheadline.bold()).foregroundStyle(C.text)
                Text(label).font(.caption2).foregroundStyle(C.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(C.bg.opacity(0.42), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

private struct MatrixNativeSpaceRow: View {
    let space: MatrixVibeSummary

    var body: some View {
        HStack(spacing: 12) {
            MatrixNativeAvatar(
                name: space.name,
                imageURL: space.avatarURL,
                size: 48
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(space.name).font(.headline).foregroundStyle(C.text)
                Text(space.topic?.isEmpty == false ? space.topic! : "Open Vibe")
                    .font(.caption).foregroundStyle(C.textMuted).lineLimit(2)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(C.textTertiary)
        }
        .padding(13)
        .background(C.surface, in: RoundedRectangle(cornerRadius: C.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: C.cardRadius).stroke(C.borderSubtle))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this Vibe's Waves")
    }
}

private struct MatrixNativeInvitationRow: View {
    let space: MatrixVibeSummary
    let isBusy: Bool
    let accept: () -> Void
    let decline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                MatrixNativeAvatar(
                    name: space.name,
                    imageURL: space.avatarURL,
                    size: 44
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(space.name).font(.headline).foregroundStyle(C.text)
                    Text("Invited to join this Vibe").font(.caption).foregroundStyle(C.textMuted)
                }
                Spacer()
            }
            HStack(spacing: 10) {
                Button("Accept", action: accept)
                    .buttonStyle(.borderedProminent).tint(C.watch)
                Button("Decline", action: decline)
                    .buttonStyle(.bordered).tint(C.textMuted)
            }
            .disabled(isBusy)
        }
        .padding(13)
        .background(C.surface, in: RoundedRectangle(cornerRadius: C.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: C.cardRadius).stroke(C.watch.opacity(0.35)))
    }
}

private struct MatrixNativeWaveRow: View {
    let room: MatrixWaveSummary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: room.isNestedSpace ? "folder" : "number")
                .font(.headline.weight(.semibold))
                .foregroundStyle(C.watch)
                .frame(width: 38, height: 38)
                .background(C.watch.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text(room.name).font(.headline).foregroundStyle(C.text)
                if let topic = room.topic, !topic.isEmpty {
                    Text(topic).font(.caption).foregroundStyle(C.textMuted).lineLimit(2)
                } else {
                    Text(room.isNestedSpace ? "Nested Vibe" : "Wave room")
                        .font(.caption).foregroundStyle(C.textMuted)
                }
            }
            Spacer()
            if room.activeCallParticipantCount > 0 {
                Label(
                    "Live \(room.activeCallParticipantCount)",
                    systemImage: room.activeCallIntent == .video
                        ? "video.fill"
                        : "waveform"
                )
                .font(.caption2.bold())
                .foregroundStyle(C.watch)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(C.watch.opacity(0.12), in: Capsule())
            }
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(C.textTertiary)
        }
        .padding(12)
        .background(C.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(C.borderSubtle))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct MatrixNativeLiveLoungeRow: View {
    let room: MatrixWaveSummary

    private var loungeLabel: String {
        switch room.activeCallIntent {
        case .video: return "Video lounge"
        case .audio: return "Voice lounge"
        case nil: return "Live lounge"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: room.activeCallIntent == .video ? "video.fill" : "waveform")
                .font(.headline)
                .foregroundStyle(C.watch)
                .frame(width: 42, height: 42)
                .background(C.watch.opacity(0.14), in: Circle())
                .overlay(alignment: .topTrailing) {
                    Circle().fill(C.watch).frame(width: 9, height: 9)
                        .overlay(C.bg, in: Circle().stroke(lineWidth: 2))
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(room.name).font(.headline).foregroundStyle(C.text)
                Text(
                    "\(room.activeCallParticipantCount) live · "
                        + loungeLabel
                )
                .font(.caption)
                .foregroundStyle(C.textMuted)
                if !room.activeCallParticipants.isEmpty {
                    HStack(spacing: 5) {
                        HStack(spacing: -5) {
                            ForEach(room.activeCallParticipants) { participant in
                                MatrixNativeAvatar(
                                    name: participant.displayName,
                                    imageURL: participant.avatarURL,
                                    size: 20
                                )
                            }
                        }
                        Text(
                            room.activeCallParticipants
                                .map(\.displayName)
                                .joined(separator: ", ")
                                + (room.activeCallParticipantCount
                                    > room.activeCallParticipants.count
                                    ? " +\(room.activeCallParticipantCount - room.activeCallParticipants.count)"
                                    : "")
                        )
                        .font(.caption2)
                        .foregroundStyle(C.textMuted)
                        .lineLimit(1)
                    }
                }
            }
            Spacer()
            Text("Join")
                .font(.caption.bold())
                .foregroundStyle(C.watch)
        }
        .padding(12)
        .background(C.watch.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(C.watch.opacity(0.25)))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this live lounge")
    }
}

struct MatrixNativeAvatar: View {
    let name: String
    var imageURL: String? = nil
    let size: CGFloat
    @EnvironmentObject private var matrixSession: MatrixNativeSessionController
    @State private var matrixImage: UIImage?

    var body: some View {
        Group {
            if let matrixImage {
                Image(uiImage: matrixImage)
                    .resizable()
                    .scaledToFill()
            } else if let remoteURL {
                AsyncImage(url: remoteURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    initials
                }
            } else {
                initials
            }
        }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.30))
            .overlay(RoundedRectangle(cornerRadius: size * 0.30).stroke(C.borderSubtle))
            .accessibilityHidden(true)
            .task(id: imageURL) {
                matrixImage = nil
                guard let imageURL, imageURL.hasPrefix("mxc://") else { return }
                guard let data = try? await matrixSession.avatarData(avatarURL: imageURL) else {
                    return
                }
                matrixImage = UIImage(data: data)
            }
    }

    private var remoteURL: URL? {
        guard let imageURL,
              let url = URL(string: imageURL),
              ["https", "http"].contains(url.scheme?.lowercased() ?? "")
        else { return nil }
        return url
    }

    private var initials: some View {
        Text(String(name.trimmingCharacters(in: .whitespacesAndNewlines).first ?? "V").uppercased())
            .font(.system(size: size * 0.38, weight: .bold))
            .foregroundStyle(C.watch)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                LinearGradient(
                    colors: [C.watch.opacity(0.22), Color.indigo.opacity(0.18)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }
}

private struct MatrixNativeSectionLabel: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text(title).font(.headline).foregroundStyle(C.text)
            Spacer()
            Text("\(count)").font(.caption.bold()).foregroundStyle(C.textMuted)
        }
        .padding(.top, 6)
    }
}

private struct MatrixNativeConnectionBanner: View {
    let state: MatrixNativeSyncState

    var body: some View {
        if state != .running {
            HStack(spacing: 7) {
                Image(systemName: state == .offline ? "wifi.slash" : "arrow.triangle.2.circlepath")
                Text(MatrixNativeCopy.label(for: state))
                Spacer()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(C.textMuted)
            .padding(.horizontal, C.pagePad)
            .padding(.vertical, 7)
            .background(C.elevated)
            .accessibilityElement(children: .combine)
        }
    }
}

private struct MatrixNativeSessionGateView: View {
    let state: MatrixSessionLifecycleState
    let retry: () -> Void

    var body: some View {
        switch state {
        case .restoring, .requestingSession, .authorizing:
            MatrixNativeLoadingView(title: "Connecting to Vibes")
        case .failed(let error):
            MatrixNativeUnavailableView(
                title: "Vibes unavailable",
                message: MatrixNativeCopy.message(for: error),
                retry: retry
            )
        case .disabled:
            MatrixNativeUnavailableView(
                title: "Connect to Vibes",
                message: "Your secure Vibes session has not connected yet.",
                retry: retry
            )
        default:
            MatrixNativeUnavailableView(
                title: "Vibes disconnected",
                message: "Reconnect your WeStreem session to continue.",
                retry: retry
            )
        }
    }
}

private struct MatrixNativeLoadingView: View {
    let title: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView().tint(C.watch).controlSize(.large)
            Text(title).font(.headline).foregroundStyle(C.text)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(C.bg)
        .accessibilityElement(children: .combine)
    }
}

private struct MatrixNativeUnavailableView: View {
    let title: String
    let message: String
    let retry: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "person.3.fill")
        } description: {
            Text(message)
        } actions: {
            if let retry {
                Button("Try Again", action: retry)
                    .buttonStyle(.borderedProminent)
                    .tint(C.watch)
            }
        }
        .foregroundStyle(C.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(C.bg)
    }
}

private struct MatrixConditionalIconLabelStyle: LabelStyle {
    let showIcon: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            if showIcon { configuration.icon }
            configuration.title
        }
    }
}

private enum MatrixNativeCopy {
    static func message(for error: Error) -> String {
        if let action = error as? MatrixNativeWaveActionError {
            return action.localizedDescription
        }
        if let rules = error as? MatrixNativeWaveRulesReadError {
            switch rules {
            case .invalidCanonicalState:
                return "These Wave rules are invalid. A moderator must repair the newest revision."
            case .incompleteHistory:
                return "Vibes could not verify the complete Wave rules history. Sync and try again."
            case .staleRevision:
                return "Another moderator updated these rules. Reload before saving your changes."
            }
        }
        if let validation = error as? MatrixNativeCreationValidationError {
            switch validation {
            case .invalidName:
                return "Enter a name between 1 and 255 characters."
            case .topicTooLong:
                return "The description must be 4,000 characters or fewer."
            case .tooManyInvitations:
                return "Invite no more than 100 people at once."
            case .invalidMatrixUserID(let userID):
                return "\(userID.isEmpty ? "An invitation" : userID) is not a valid WeStreem member ID."
            }
        }
        guard let foundation = error as? MatrixSessionFoundationError else {
            return "Vibes could not synchronize. Check your connection and try again."
        }
        switch foundation {
        case .disabled:
            return "Vibes is not currently available. Try connecting again."
        case .authenticationCancelled:
            return "Vibes sign-in was cancelled."
        case .invalidWestreemUserID, .identityMismatch:
            return "Your WeStreem identity could not be verified for Vibes."
        case .invalidHomeserver, .invalidSSOConfiguration, .invalidSSOCallback:
            return "The Vibes connection is not configured safely."
        case .unavailable:
            return "Vibes is temporarily unavailable. Your queued messages remain securely on this device."
        }
    }

    static func icon(for kind: MatrixNativeMessageKind) -> String {
        switch kind {
        case .image, .gallery: "photo"
        case .audio: "waveform"
        case .video: "video"
        case .file: "doc"
        case .poll: "chart.bar"
        case .sticker: "face.smiling"
        case .location: "location"
        case .unableToDecrypt: "lock.trianglebadge.exclamationmark"
        case .redacted: "trash"
        default: "text.bubble"
        }
    }

    static func label(for state: MatrixNativeLocalSendState) -> String {
        switch state {
        case .sending: "Sending…"
        case .failed(let recoverable): recoverable ? "Not sent — retry available" : "Not sent"
        case .sent: "Sent"
        }
    }

    static func isFailure(_ state: MatrixNativeLocalSendState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    static func label(for state: MatrixNativeSyncState) -> String {
        switch state {
        case .running: "Connected"
        case .offline: "Offline — messages will stay queued"
        case .recovering(let attempt): "Reconnecting (attempt \(attempt))"
        case .failed: "Vibes sync needs attention"
        case .starting: "Connecting…"
        case .stopped, .disabled: "Vibes sync paused"
        }
    }
}
