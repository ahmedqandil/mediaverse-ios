import SwiftUI

struct StudioView: View {

    @State private var productions = [StudioProduction]()
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showCreate = false

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    if isLoading {
                        loadingList
                    } else if let errorMessage {
                        errorState(errorMessage)
                    } else if productions.isEmpty {
                        emptyState
                    } else {
                        productionList
                    }
                }
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("Studio")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(C.text)
                }
            }
        }
        .sheet(isPresented: $showCreate) {
            StudioCreateProductionSheet { production in
                productions.insert(production, at: 0)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("AI Studio")
                .font(.title2.bold())
                .foregroundStyle(C.text)
            Text("Create productions, break down scenes, and run the AI pipeline.")
                .font(.subheadline)
                .foregroundStyle(C.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, C.pagePad)
        .padding(.top, 8)
    }

    private var productionList: some View {
        LazyVStack(spacing: 12) {
            ForEach(productions) { production in
                NavigationLink {
                    StudioProductionDetailView(productionId: production.id)
                } label: {
                    StudioProductionCard(production: production)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, C.pagePad)
    }

    private var loadingList: some View {
        VStack(spacing: 12) {
            ForEach(0..<4, id: \.self) { _ in
                RoundedRectangle(cornerRadius: C.cardRadius)
                    .fill(C.surface)
                    .frame(height: 172)
                    .overlay {
                        RoundedRectangle(cornerRadius: C.cardRadius)
                            .stroke(C.border, lineWidth: 1)
                    }
                    .shimmering()
            }
        }
        .padding(.horizontal, C.pagePad)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 44))
                .foregroundStyle(Color.white.opacity(0.22))
            Text("No productions yet")
                .font(.headline)
                .foregroundStyle(C.text)
            Text("Create a production to begin script breakdown, scenes, shots, and pipeline runs.")
                .font(.caption)
                .foregroundStyle(C.textMuted)
                .multilineTextAlignment(.center)
            Button {
                showCreate = true
            } label: {
                Label("New Production", systemImage: "plus")
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 18)
                    .frame(height: 40)
                    .background(Color(hex: "#C77DFF"))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(C.pagePad)
        .frame(maxWidth: .infinity, minHeight: 340)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(Color.orange.opacity(0.8))
            Text(message)
                .font(.caption)
                .foregroundStyle(C.textMuted)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await load() }
            }
            .font(.subheadline.bold())
            .foregroundStyle(Color.black)
            .padding(.horizontal, 18)
            .frame(height: 38)
            .background(C.watch)
            .clipShape(Capsule())
        }
        .padding(C.pagePad)
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    @MainActor
    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let response = try await APIClient.shared.fetchStudioProductions()
            productions = response.productions
            errorMessage = response.error
        } catch {
            productions = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct StudioProductionCard: View {
    let production: StudioProduction

    private var sceneCount: Int { production._count?.scenes ?? production.scenes.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        StudioBadge(label: production.status, color: statusColor)
                        StudioBadge(label: production.genre, color: .neutral)
                        StudioBadge(label: production.language.uppercased(), color: .neutral)
                    }

                    Text(production.title)
                        .font(.headline)
                        .foregroundStyle(C.text)
                        .lineLimit(2)

                    if let arTitle = production.arTitle, !arTitle.isEmpty {
                        Text(arTitle)
                            .font(.subheadline)
                            .foregroundStyle(C.textMuted)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .environment(\.layoutDirection, .rightToLeft)
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(C.textMuted.opacity(0.5))
            }

            if let synopsis = production.synopsis, !synopsis.isEmpty {
                Text(synopsis)
                    .font(.caption)
                    .foregroundStyle(C.textMuted)
                    .lineLimit(2)
            }

            VStack(alignment: .leading, spacing: 7) {
                ForEach(production.scenes.prefix(3)) { scene in
                    HStack(spacing: 8) {
                        Image(systemName: "video")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.28))
                            .frame(width: 18)
                        Text("\(scene.sequence). \(scene.title)")
                            .font(.caption)
                            .foregroundStyle(C.text.opacity(0.72))
                            .lineLimit(1)
                        Spacer()
                        StudioBadge(label: scene.status, color: .neutral)
                    }
                }

                if production.scenes.isEmpty {
                    Text("No scenes yet")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.24))
                        .italic()
                } else if production.scenes.count > 3 {
                    Text("+\(production.scenes.count - 3) more scenes")
                        .font(.caption2)
                        .foregroundStyle(C.textMuted.opacity(0.7))
                }
            }

            HStack {
                Text("\(sceneCount) \(sceneCount == 1 ? "scene" : "scenes")")
                    .font(.caption)
                    .foregroundStyle(C.textMuted)
                Spacer()
                Text([production.country, production.dialect].compactMap { value in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(C.textMuted.opacity(0.7))
            }
            .padding(.top, 2)
        }
        .padding(16)
        .background(C.surface)
        .clipShape(RoundedRectangle(cornerRadius: C.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: C.cardRadius)
                .stroke(C.border, lineWidth: 1)
        }
    }

    private var statusColor: StudioBadge.ColorRole {
        switch production.status.uppercased() {
        case "COMPLETE", "ACTIVE", "REVIEWED": return .green
        case "RENDERING", "BREAKDOWN": return .purple
        case "FAILED": return .red
        default: return .yellow
        }
    }
}

private struct StudioProductionDetailView: View {
    let productionId: String

    @State private var production: StudioProduction?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var concept = ""
    @State private var culturalConstraints = true
    @State private var episodeSec = 60.0
    @State private var isBreakingDown = false

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if isLoading {
                        ProgressView().tint(Color(hex: "#C77DFF"))
                            .frame(maxWidth: .infinity, minHeight: 300)
                    } else if let errorMessage {
                        detailError(errorMessage)
                    } else if let production {
                        detailHeader(production)
                        breakdownPanel(production)
                        scenesSection(production)
                    }
                }
                .padding(.horizontal, C.pagePad)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("Production")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func detailHeader(_ production: StudioProduction) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                StudioBadge(label: production.status, color: statusColor(production.status))
                StudioBadge(label: production.genre, color: .neutral)
                StudioBadge(label: production.language.uppercased(), color: .neutral)
            }

            Text(production.title)
                .font(.title2.bold())
                .foregroundStyle(C.text)
                .lineLimit(3)

            if let arTitle = production.arTitle, !arTitle.isEmpty {
                Text(arTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(C.textMuted)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .environment(\.layoutDirection, .rightToLeft)
            }

            if let synopsis = production.synopsis, !synopsis.isEmpty {
                Text(synopsis)
                    .font(.subheadline)
                    .foregroundStyle(C.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Label("\(production.scenes.count) \(production.scenes.count == 1 ? "scene" : "scenes")", systemImage: "video")
                Spacer()
                Text([production.country, production.dialect].compactMap { value in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }.joined(separator: " · "))
            }
            .font(.caption)
            .foregroundStyle(C.textMuted)
        }
    }

    private func breakdownPanel(_ production: StudioProduction) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Script Breakdown", systemImage: "wand.and.stars")
                    .font(.headline)
                    .foregroundStyle(C.text)
                Spacer()
                StudioBadge(label: "AI", color: .purple)
            }

            Text("Convert a concept into scenes, shots, and dialogue for this production.")
                .font(.caption)
                .foregroundStyle(C.textMuted)

            TextEditor(text: $concept)
                .scrollContentBackground(.hidden)
                .foregroundStyle(C.text)
                .frame(minHeight: 120)
                .padding(8)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.10), lineWidth: 1) }
                .overlay(alignment: .topLeading) {
                    if concept.isEmpty {
                        Text("Paste the episode concept or logline...")
                            .font(.caption)
                            .foregroundStyle(C.textMuted.opacity(0.5))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }

            Toggle("Cultural constraints", isOn: $culturalConstraints)
                .font(.subheadline)
                .foregroundStyle(C.text)
                .tint(Color(hex: "#C77DFF"))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Episode length")
                    Spacer()
                    Text("\(Int(episodeSec))s")
                }
                .font(.caption)
                .foregroundStyle(C.textMuted)
                Slider(value: $episodeSec, in: 30...180, step: 15)
                    .tint(Color(hex: "#C77DFF"))
            }

            Button {
                Task { await runBreakdown(production) }
            } label: {
                if isBreakingDown {
                    ProgressView().tint(.black)
                } else {
                    Label("Generate Breakdown", systemImage: "sparkles")
                }
            }
            .font(.subheadline.bold())
            .foregroundStyle(Color.black)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(Color(hex: "#C77DFF"))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .disabled(isBreakingDown)
        }
        .padding(16)
        .background(C.surface)
        .clipShape(RoundedRectangle(cornerRadius: C.cardRadius))
        .overlay { RoundedRectangle(cornerRadius: C.cardRadius).stroke(C.border, lineWidth: 1) }
    }

    private func scenesSection(_ production: StudioProduction) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scenes")
                .font(.headline)
                .foregroundStyle(C.text)

            if production.scenes.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "video")
                        .font(.system(size: 34))
                        .foregroundStyle(Color.white.opacity(0.22))
                    Text("No scenes yet")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(C.text)
                    Text("Run script breakdown to create scenes, shots, and dialogue.")
                        .font(.caption)
                        .foregroundStyle(C.textMuted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
                .background(C.surface)
                .clipShape(RoundedRectangle(cornerRadius: C.cardRadius))
                .overlay { RoundedRectangle(cornerRadius: C.cardRadius).stroke(C.border, lineWidth: 1) }
            } else {
                VStack(spacing: 10) {
                    ForEach(production.scenes) { scene in
                        NavigationLink {
                            StudioSceneDetailView(sceneId: scene.id)
                        } label: {
                            HStack(spacing: 12) {
                                Text("\(scene.sequence)")
                                    .font(.caption.bold())
                                    .foregroundStyle(Color.black)
                                    .frame(width: 28, height: 28)
                                    .background(Color(hex: "#C77DFF"))
                                    .clipShape(Circle())
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(scene.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(C.text)
                                    Text(scene.slug)
                                        .font(.caption2)
                                        .foregroundStyle(C.textMuted)
                                        .lineLimit(1)
                                }
                                Spacer()
                                StudioBadge(label: scene.status, color: .neutral)
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(C.textMuted.opacity(0.5))
                            }
                            .padding(12)
                            .background(C.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay { RoundedRectangle(cornerRadius: 8).stroke(C.border, lineWidth: 1) }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func detailError(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(Color.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(C.textMuted)
                .multilineTextAlignment(.center)
            Button("Retry") { Task { await load() } }
                .font(.subheadline.bold())
                .foregroundStyle(Color.black)
                .padding(.horizontal, 18)
                .frame(height: 38)
                .background(C.watch)
                .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    @MainActor
    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            production = try await APIClient.shared.fetchStudioProduction(id: productionId)
            if concept.isEmpty {
                concept = production?.synopsis ?? ""
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    @MainActor
    private func runBreakdown(_ production: StudioProduction) async {
        let trimmed = concept.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Concept is required for breakdown."
            return
        }
        isBreakingDown = true
        errorMessage = nil
        do {
            try await APIClient.shared.runStudioBreakdown(
                productionId: production.id,
                concept: trimmed,
                genre: production.genre,
                dialect: production.dialect ?? "khaleeji",
                episodeSec: Int(episodeSec),
                culturalConstraints: culturalConstraints
            )
            self.production = try await APIClient.shared.fetchStudioProduction(id: production.id)
        } catch {
            errorMessage = error.localizedDescription
        }
        isBreakingDown = false
    }

    private func statusColor(_ status: String) -> StudioBadge.ColorRole {
        switch status.uppercased() {
        case "COMPLETE", "ACTIVE", "REVIEWED": return .green
        case "RENDERING", "BREAKDOWN": return .purple
        case "FAILED": return .red
        default: return .yellow
        }
    }
}

private struct StudioSceneDetailView: View {
    let sceneId: String

    @State private var scene: StudioSceneDetail?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if isLoading {
                        ProgressView().tint(Color(hex: "#C77DFF"))
                            .frame(maxWidth: .infinity, minHeight: 300)
                    } else if let errorMessage {
                        sceneError(errorMessage)
                    } else if let scene {
                        sceneHeader(scene)
                        shotsSection(scene)
                    }
                }
                .padding(.horizontal, C.pagePad)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("Scene")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func sceneHeader(_ scene: StudioSceneDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                StudioBadge(label: scene.status, color: .neutral)
                StudioBadge(label: "\(scene.shots.count) shots", color: .purple)
            }

            Text("\(scene.sequence). \(scene.title)")
                .font(.title2.bold())
                .foregroundStyle(C.text)
                .lineLimit(3)

            if let arTitle = scene.arTitle, !arTitle.isEmpty {
                Text(arTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(C.textMuted)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .environment(\.layoutDirection, .rightToLeft)
            }

            if let synopsis = scene.synopsis, !synopsis.isEmpty {
                Text(synopsis)
                    .font(.subheadline)
                    .foregroundStyle(C.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let location = scene.locationDesc, !location.isEmpty {
                Label(location, systemImage: "mappin.and.ellipse")
                    .font(.caption)
                    .foregroundStyle(C.textMuted)
            }

            if let visualBrief = scene.visualBrief, !visualBrief.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Visual Brief")
                        .font(.system(size: 10, weight: .bold))
                        .textCase(.uppercase)
                        .foregroundStyle(C.textMuted)
                    Text(visualBrief)
                        .font(.caption)
                        .foregroundStyle(C.text.opacity(0.76))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(C.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(C.border, lineWidth: 1) }
            }
        }
    }

    private func shotsSection(_ scene: StudioSceneDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shots")
                .font(.headline)
                .foregroundStyle(C.text)

            if scene.shots.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 34))
                        .foregroundStyle(Color.white.opacity(0.22))
                    Text("No shots yet")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(C.text)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
                .background(C.surface)
                .clipShape(RoundedRectangle(cornerRadius: C.cardRadius))
                .overlay { RoundedRectangle(cornerRadius: C.cardRadius).stroke(C.border, lineWidth: 1) }
            } else {
                VStack(spacing: 12) {
                    ForEach(scene.shots) { shot in
                        StudioShotCard(shot: shot)
                    }
                }
            }
        }
    }

    private func sceneError(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(Color.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(C.textMuted)
                .multilineTextAlignment(.center)
            Button("Retry") { Task { await load() } }
                .font(.subheadline.bold())
                .foregroundStyle(Color.black)
                .padding(.horizontal, 18)
                .frame(height: 38)
                .background(C.watch)
                .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    @MainActor
    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            scene = try await APIClient.shared.fetchStudioScene(id: sceneId)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct StudioShotCard: View {
    let shot: StudioShot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Text("\(shot.sequence)")
                    .font(.caption.bold())
                    .foregroundStyle(Color.black)
                    .frame(width: 28, height: 28)
                    .background(typeColor)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        StudioBadge(label: shot.type, color: .neutral)
                        StudioBadge(label: shot.status ?? "DRAFT", color: .neutral)
                        if shot.lipCritical {
                            StudioBadge(label: "lip", color: .purple)
                        }
                    }

                    Text(shot.action?.isEmpty == false ? shot.action! : shot.shotSlug)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(C.text)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Text("\(String(format: "%.0f", shot.durationSec))s")
                        if let emotion = shot.emotion, !emotion.isEmpty {
                            Text(".")
                            Text(emotion)
                        }
                        if let videoStatus = shot.videoStatus, !videoStatus.isEmpty {
                            Text(".")
                            Text(videoStatus)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(C.textMuted)
                }
            }

            if let location = shot.locationDesc, !location.isEmpty {
                Label(location, systemImage: "location")
                    .font(.caption)
                    .foregroundStyle(C.textMuted)
            }

            if !shot.characterIds.isEmpty {
                Text(shot.characterIds.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(C.textMuted.opacity(0.75))
            }

            ForEach(shot.dialogues) { dialogue in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(dialogue.characterId)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color(hex: "#C77DFF"))
                        Spacer()
                        if let emotion = dialogue.emotion, !emotion.isEmpty {
                            Text(emotion)
                                .font(.caption2)
                                .foregroundStyle(C.textMuted)
                        }
                    }
                    Text(dialogue.arText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(C.text)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .environment(\.layoutDirection, .rightToLeft)
                    if let english = dialogue.enText, !english.isEmpty {
                        Text(english)
                            .font(.caption)
                            .foregroundStyle(C.textMuted)
                    }
                }
                .padding(10)
                .background(Color.black.opacity(0.20))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(14)
        .background(C.surface)
        .clipShape(RoundedRectangle(cornerRadius: C.cardRadius))
        .overlay { RoundedRectangle(cornerRadius: C.cardRadius).stroke(C.border, lineWidth: 1) }
    }

    private var typeColor: Color {
        switch shot.type {
        case "wide": return .blue
        case "closeup": return Color(hex: "#C77DFF")
        case "ots": return .green
        case "insert": return .yellow
        default: return C.watch
        }
    }
}

private struct StudioCreateProductionSheet: View {
    let onCreate: (StudioProduction) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var arTitle = ""
    @State private var synopsis = ""
    @State private var genre = "drama"
    @State private var country = "SA"
    @State private var dialect = "najdi"
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let genres = ["drama", "thriller", "romance", "comedy", "family", "historical"]
    private let countries: [(String, String, [(String, String)])] = [
        ("SA", "Saudi Arabia", [("najdi", "Najdi"), ("hijazi", "Hijazi"), ("gulf", "Gulf")]),
        ("AE", "United Arab Emirates", [("emirati", "Emirati"), ("gulf", "Gulf")]),
        ("KW", "Kuwait", [("kuwaiti", "Kuwaiti"), ("gulf", "Gulf")]),
        ("EG", "Egypt", [("egyptian", "Egyptian")]),
        ("LB", "Lebanon", [("levantine", "Levantine")])
    ]

    private var dialects: [(String, String)] {
        countries.first { $0.0 == country }?.2 ?? []
    }

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("New Production")
                            .font(.headline)
                            .foregroundStyle(C.text)
                        Spacer()
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(C.textMuted)
                                .frame(width: 34, height: 34)
                                .background(Color.white.opacity(0.08))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }

                    StudioTextField(title: "Title (EN) *", text: $title, placeholder: "e.g. The Betrayal")
                    StudioTextField(title: "Title (AR)", text: $arTitle, placeholder: "الخيانة", rightToLeft: true)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Synopsis")
                            .font(.system(size: 10, weight: .bold))
                            .textCase(.uppercase)
                            .foregroundStyle(C.textMuted)
                        TextEditor(text: $synopsis)
                            .scrollContentBackground(.hidden)
                            .foregroundStyle(C.text)
                            .frame(minHeight: 88)
                            .padding(8)
                            .background(Color.white.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.10), lineWidth: 1) }
                    }

                    StudioPicker(title: "Genre", selection: $genre, options: genres.map { ($0, $0) })

                    HStack(spacing: 10) {
                        StudioPicker(title: "Country", selection: $country, options: countries.map { ($0.0, $0.1) })
                            .onChange(of: country) { _, _ in
                                dialect = dialects.first?.0 ?? ""
                            }
                        StudioPicker(title: "Dialect", selection: $dialect, options: dialects)
                    }

                    Text("Dialect is used for AI-written dialogue and cast voice matching.")
                        .font(.caption2)
                        .foregroundStyle(C.textMuted.opacity(0.75))

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    HStack(spacing: 12) {
                        Button("Cancel") { dismiss() }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(C.textMuted)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 10))

                        Button {
                            Task { await create() }
                        } label: {
                            if isSaving {
                                ProgressView().tint(.black)
                            } else {
                                Text("Create")
                            }
                        }
                        .font(.subheadline.bold())
                        .foregroundStyle(Color.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color(hex: "#C77DFF"))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .disabled(isSaving)
                    }
                    .padding(.top, 4)
                }
                .padding(C.pagePad)
            }
        }
    }

    @MainActor
    private func create() async {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            errorMessage = "Title is required"
            return
        }

        isSaving = true
        errorMessage = nil
        do {
            let production = try await APIClient.shared.createStudioProduction(
                title: trimmedTitle,
                arTitle: arTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                synopsis: synopsis.trimmingCharacters(in: .whitespacesAndNewlines),
                genre: genre,
                country: country,
                dialect: dialect
            )
            onCreate(production)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}

private struct StudioTextField: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    var rightToLeft = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .textCase(.uppercase)
                .foregroundStyle(C.textMuted)
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.sentences)
                .foregroundStyle(C.text)
                .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight)
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.10), lineWidth: 1) }
        }
    }
}

private struct StudioPicker: View {
    let title: String
    @Binding var selection: String
    let options: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .textCase(.uppercase)
                .foregroundStyle(C.textMuted)
            Picker(title, selection: $selection) {
                ForEach(options, id: \.0) { value, label in
                    Text(label).tag(value)
                }
            }
            .pickerStyle(.menu)
            .tint(C.text)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.10), lineWidth: 1) }
        }
    }
}

private struct StudioBadge: View {
    enum ColorRole { case green, yellow, red, purple, neutral }

    let label: String
    let color: ColorRole

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(background)
            .clipShape(Capsule())
    }

    private var foreground: Color {
        switch color {
        case .green: return .green
        case .yellow: return .yellow
        case .red: return .red
        case .purple: return Color(hex: "#C77DFF")
        case .neutral: return C.textMuted
        }
    }

    private var background: Color {
        switch color {
        case .green: return .green.opacity(0.15)
        case .yellow: return .yellow.opacity(0.15)
        case .red: return .red.opacity(0.15)
        case .purple: return Color(hex: "#C77DFF").opacity(0.15)
        case .neutral: return Color.white.opacity(0.08)
        }
    }
}
