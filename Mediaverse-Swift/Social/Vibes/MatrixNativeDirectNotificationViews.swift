import SwiftUI

struct MatrixNativeDirectMessagesView: View {
    @EnvironmentObject private var matrixSession: MatrixNativeSessionController
    @State private var rooms: [MatrixDirectRoomSummary] = []
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showsNewMessage = false
    @State private var createdRoom: MatrixDirectRoomSummary?
    @State private var pendingInvitationRoomID: String?
    @State private var securityInviteRoom: MatrixDirectRoomSummary?
    @State private var showsInviteSecurity = false

    private var filteredRooms: [MatrixDirectRoomSummary] {
        guard let query = MatrixDirectMessageContract.normalizedSearchQuery(searchText) else {
            return rooms
        }
        return rooms.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.memberMatrixID?.localizedCaseInsensitiveContains(query) == true
        }
    }

    var body: some View {
        Group {
            if isLoading, rooms.isEmpty {
                ProgressView("Loading messages…")
                    .tint(C.watch)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, rooms.isEmpty {
                ContentUnavailableView {
                    Label("Messages unavailable", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                        .tint(C.watch)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if filteredRooms.isEmpty {
                            ContentUnavailableView {
                                Label(
                                    searchText.isEmpty ? "No messages yet" : "No matching messages",
                                    systemImage: "bubble.left.and.bubble.right"
                                )
                            } description: {
                                Text(
                                    searchText.isEmpty
                                        ? "Start a secure conversation with a WeStreem user."
                                        : "Try another name or start a new conversation."
                                )
                            } actions: {
                                Button("New message") { showsNewMessage = true }
                                    .buttonStyle(.borderedProminent)
                                    .tint(C.watch)
                            }
                            .foregroundStyle(C.text)
                            .padding(.top, 70)
                        } else {
                            ForEach(filteredRooms) { room in
                                if room.membership == .invited {
                                    VStack(spacing: 8) {
                                        MatrixDirectMessageRow(room: room)
                                        HStack(spacing: 10) {
                                            Button("Decline") {
                                                Task { await respondToInvitation(room, accept: false) }
                                            }
                                            .buttonStyle(.bordered)

                                            Button("Accept") {
                                                Task { await respondToInvitation(room, accept: true) }
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .tint(C.watch)
                                        }
                                        .disabled(pendingInvitationRoomID != nil)
                                    }
                                    .padding(12)
                                    .background(C.surface, in: RoundedRectangle(cornerRadius: 14))
                                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(C.borderSubtle))
                                } else {
                                    NavigationLink {
                                        MatrixNativeWaveRoomView(room: room.timelineRoom)
                                    } label: {
                                        MatrixDirectMessageRow(room: room)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, C.pagePad)
                    .padding(.vertical, 12)
                    .padding(.bottom, 90)
                }
                .refreshable { await load() }
            }
        }
        .background(C.bg.ignoresSafeArea())
        .navigationTitle("Messages")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search conversations")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsNewMessage = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("New direct message")
            }
        }
        .sheet(isPresented: $showsNewMessage) {
            MatrixNativeNewDirectMessageView { room in
                createdRoom = room
                showsNewMessage = false
                Task { await load() }
            }
        }
        .sheet(isPresented: $showsInviteSecurity) {
            MatrixNativeCryptoSecurityView(
                requiredForAction: true,
                onReady: {
                    guard let room = securityInviteRoom else { return }
                    showsInviteSecurity = false
                    securityInviteRoom = nil
                    Task { await respondToInvitation(room, accept: true) }
                }
            )
            .environmentObject(matrixSession)
        }
        .navigationDestination(item: $createdRoom) { room in
            MatrixNativeWaveRoomView(room: room.timelineRoom)
        }
        .task { await load() }
    }

    @MainActor
    private func load() async {
        isLoading = true
        do {
            rooms = try await matrixSession.directMessages()
            errorMessage = nil
        } catch {
            errorMessage = "Direct messages could not synchronize. Check your connection and try again."
        }
        isLoading = false
    }

    @MainActor
    private func respondToInvitation(
        _ room: MatrixDirectRoomSummary,
        accept: Bool
    ) async {
        guard pendingInvitationRoomID == nil else { return }
        pendingInvitationRoomID = room.id
        do {
            if accept {
                try await matrixSession.acceptInvite(roomID: room.id)
            } else {
                try await matrixSession.declineInvite(roomID: room.id)
            }
            errorMessage = nil
            await load()
        } catch let error as MatrixNativeCryptoSecurityError
            where accept && error.requiresGuidedRecovery {
            securityInviteRoom = room
            showsInviteSecurity = true
        } catch {
            errorMessage = accept
                ? "This secure invitation could not be accepted."
                : "This invitation could not be declined."
        }
        pendingInvitationRoomID = nil
    }
}

private struct MatrixDirectMessageRow: View {
    let room: MatrixDirectRoomSummary

    var body: some View {
        HStack(spacing: 12) {
            MatrixDirectAvatar(name: room.name, imageURL: room.avatarURL, size: 48)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(room.name)
                        .font(.subheadline.weight(room.unreadCount > 0 ? .bold : .semibold))
                        .foregroundStyle(C.text)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if let date = room.lastActivity {
                        Text(date, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(C.textMuted)
                            .lineLimit(1)
                    }
                }

                HStack(spacing: 8) {
                    Text(room.lastMessage ?? "Secure direct message")
                        .font(.caption)
                        .foregroundStyle(room.unreadCount > 0 ? C.text : C.textMuted)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if room.unreadCount > 0 {
                        Text("\(room.unreadCount)")
                            .font(.caption2.bold())
                            .foregroundStyle(C.bg)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(C.watch, in: Capsule())
                    }
                }
            }
        }
        .padding(12)
        .background(C.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(C.borderSubtle))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct MatrixNativeNewDirectMessageView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var matrixSession: MatrixNativeSessionController
    let onCreated: (MatrixDirectRoomSummary) -> Void

    @State private var query = ""
    @State private var results: [SearchResultPerson] = []
    @State private var isSearching = false
    @State private var creatingUserID: String?
    @State private var errorMessage: String?
    @State private var securityTarget: SearchResultPerson?
    @State private var showsSecuritySetup = false

    var body: some View {
        NavigationStack {
            ZStack {
                C.bg.ignoresSafeArea()
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        }

                        if isSearching {
                            ProgressView("Finding people…")
                                .tint(C.watch)
                                .padding(.top, 36)
                        } else if MatrixDirectMessageContract.normalizedSearchQuery(query) == nil {
                            ContentUnavailableView {
                                Label("Find someone", systemImage: "person.crop.circle.badge.plus")
                            } description: {
                                Text("Search WeStreem by name or handle to start a secure direct message.")
                            }
                            .foregroundStyle(C.text)
                            .padding(.top, 40)
                        } else if results.isEmpty {
                            ContentUnavailableView.search(text: query)
                                .foregroundStyle(C.text)
                                .padding(.top, 40)
                        } else {
                            ForEach(results) { person in
                                Button {
                                    Task { await create(person) }
                                } label: {
                                    HStack(spacing: 12) {
                                        MatrixDirectAvatar(
                                            name: person.name ?? person.handle ?? "User",
                                            imageURL: person.image,
                                            size: 46
                                        )
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(person.name ?? person.handle ?? "WeStreem user")
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(C.text)
                                            if let handle = person.handle {
                                                Text("@\(handle)")
                                                    .font(.caption)
                                                    .foregroundStyle(C.textMuted)
                                            }
                                        }
                                        Spacer()
                                        if creatingUserID == person.id {
                                            ProgressView().tint(C.watch)
                                        } else {
                                            Image(systemName: "chevron.right")
                                                .font(.caption.bold())
                                                .foregroundStyle(C.textTertiary)
                                        }
                                    }
                                    .padding(12)
                                    .background(C.surface, in: RoundedRectangle(cornerRadius: 14))
                                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(C.borderSubtle))
                                }
                                .buttonStyle(.plain)
                                .disabled(creatingUserID != nil)
                            }
                        }
                    }
                    .padding(C.pagePad)
                }
            }
            .navigationTitle("New message")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Name or @handle")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task(id: query) { await search() }
            .sheet(isPresented: $showsSecuritySetup) {
                MatrixNativeCryptoSecurityView(
                    requiredForAction: true,
                    onReady: {
                        guard let person = securityTarget else { return }
                        showsSecuritySetup = false
                        securityTarget = nil
                        Task { await create(person) }
                    }
                )
                .environmentObject(matrixSession)
            }
        }
    }

    @MainActor
    private func search() async {
        guard let normalized = MatrixDirectMessageContract.normalizedSearchQuery(query) else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        errorMessage = nil
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        do {
            let response = try await APIClient.shared.search(q: normalized, type: "people")
            guard !Task.isCancelled else { return }
            results = Array((response.people ?? []).prefix(20))
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            errorMessage = "People search is temporarily unavailable."
        }
        isSearching = false
    }

    @MainActor
    private func create(_ person: SearchResultPerson) async {
        guard creatingUserID == nil else { return }
        creatingUserID = person.id
        errorMessage = nil
        do {
            _ = try await matrixSession.prepareEncryptedConversation()
            let room = try await matrixSession.openOrCreateDirectMessage(
                westreemUserID: person.id,
                displayName: person.name ?? person.handle,
                avatarURL: person.image
            )
            onCreated(room)
        } catch let error as MatrixNativeCryptoSecurityError
            where error.requiresGuidedRecovery {
            securityTarget = person
            showsSecuritySetup = true
        } catch let error as MatrixDirectMessageError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = "This secure conversation could not be opened."
        }
        creatingUserID = nil
    }
}

struct MatrixNativeNotificationInboxSection: View {
    @EnvironmentObject private var matrixSession: MatrixNativeSessionController
    @State private var items: [MatrixNotificationSummary] = []
    @State private var isLoading = true

    var body: some View {
        if matrixSession.isReady {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("VIBES")
                        .font(.caption2.bold())
                        .foregroundStyle(C.textMuted)
                    Spacer()
                    if isLoading {
                        ProgressView().controlSize(.mini).tint(C.watch)
                    } else if !items.isEmpty {
                        Text("\(items.count)")
                            .font(.caption2.bold())
                            .foregroundStyle(C.textMuted)
                    }
                }

                ForEach(items) { item in
                    NavigationLink {
                        MatrixNativeWaveRoomView(room: item.room)
                    } label: {
                        MatrixNotificationRow(item: item)
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            Task {
                                await matrixSession.markMatrixNotificationRead(roomID: item.room.id)
                            }
                        }
                    )
                }
            }
            .task { await load() }
        }
    }

    @MainActor
    private func load() async {
        isLoading = true
        items = (try? await matrixSession.matrixNotifications()) ?? []
        isLoading = false
    }
}

private struct MatrixNotificationRow: View {
    let item: MatrixNotificationSummary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            MatrixDirectAvatar(
                name: item.senderName,
                imageURL: item.senderAvatarURL,
                size: 44
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.room.name)
                        .font(.subheadline.bold())
                        .foregroundStyle(C.text)
                        .lineLimit(1)
                    if item.isDirect {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(C.watch)
                            .accessibilityLabel("Direct message")
                    } else if item.hasMention {
                        Text("Mention")
                            .font(.caption2.bold())
                            .foregroundStyle(C.watch)
                    }
                    Spacer()
                    Text(item.createdAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(C.textMuted)
                }
                Text(item.senderName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(C.textMuted)
                    .lineLimit(1)
                Text(item.message)
                    .font(.caption)
                    .foregroundStyle(C.text)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .background(C.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(C.borderSubtle))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct MatrixDirectAvatar: View {
    let name: String
    let imageURL: String?
    let size: CGFloat

    var body: some View {
        MatrixNativeAvatar(name: name, imageURL: imageURL, size: size)
    }
}
