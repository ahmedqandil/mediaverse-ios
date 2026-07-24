import PhotosUI
import SwiftUI
import UIKit

struct ChannelSettingsView: View {
    let channelId: String
    var onSaved: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var channel: BackstageChannelSettings?
    @State private var name = ""
    @State private var avatarUrl = ""
    @State private var bannerUrl = ""
    @State private var selectedAvatarItem: PhotosPickerItem?
    @State private var selectedBannerItem: PhotosPickerItem?
    @State private var avatarPreviewImage: UIImage?
    @State private var bannerPreviewImage: UIImage?
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var isUploadingAvatar = false
    @State private var isUploadingBanner = false
    @State private var errorMessage: String?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                C.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if isLoading {
                            loadingState
                        } else if channel != nil {
                            settingsForm
                        } else {
                            loadFailureState
                        }
                    }
                    .frame(width: max(0, geo.size.width - C.pagePad * 2), alignment: .topLeading)
                    .padding(C.pagePad)
                }
                .scrollIndicators(.hidden)
            }
        }
        .navigationTitle("Channel Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(isSaving ? "Saving..." : "Save") {
                    Task { await save() }
                }
                .disabled(isLoading || isSaving || isUploadingAvatar || isUploadingBanner || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .foregroundStyle(C.watch)
            }
        }
        .task { await loadChannel() }
        .onChange(of: selectedAvatarItem) { _, item in
            guard let item else { return }
            Task { await uploadSelectedImage(item, type: .avatar) }
        }
        .onChange(of: selectedBannerItem) { _, item in
            guard let item else { return }
            Task { await uploadSelectedImage(item, type: .banner) }
        }
    }

    private var settingsForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            channelPreviewCard

            fieldGroup("Channel display name") {
                TextField("Channel display name", text: $name)
                    .textFieldStyle(.plain)
                    .foregroundStyle(C.text)
                    .padding(12)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay { RoundedRectangle(cornerRadius: 10).stroke(C.border, lineWidth: 1) }
            }

            fieldGroup("Profile image") {
                imageUploadControl(
                    title: "Choose profile image",
                    url: $avatarUrl,
                    pickerItem: $selectedAvatarItem,
                    previewImage: avatarPreviewImage,
                    existingURL: C.mediaURL(avatarUrl),
                    isUploading: isUploadingAvatar,
                    aspectRatio: 1,
                    clearPreview: { avatarPreviewImage = nil }
                )
            }

            fieldGroup("Banner image") {
                imageUploadControl(
                    title: "Choose banner image",
                    url: $bannerUrl,
                    pickerItem: $selectedBannerItem,
                    previewImage: bannerPreviewImage,
                    existingURL: C.mediaURL(bannerUrl),
                    isUploading: isUploadingBanner,
                    aspectRatio: 16.0 / 6.0,
                    clearPreview: { bannerPreviewImage = nil }
                )
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Color.red.opacity(0.9))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var channelPreviewCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            bannerPreview(height: 128)

            HStack(alignment: .center, spacing: 12) {
                avatarPreview(size: 72)
                    .overlay { Circle().stroke(C.bg, lineWidth: 4) }
                    .offset(y: -18)
                    .padding(.bottom, -18)

                VStack(alignment: .leading, spacing: 5) {
                    Text(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Channel name" : name)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(C.text)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        if let handle = channel?.handle, !handle.isEmpty {
                            Text("@\(handle)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(C.textMuted)
                                .lineLimit(1)
                        }
                        if let status = channel?.status, !status.isEmpty {
                            Text(status.capitalized)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(C.watch)
                                .padding(.horizontal, 8)
                                .frame(height: 22)
                                .background(C.watch.opacity(0.12), in: Capsule())
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(C.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(C.border, lineWidth: 1) }
    }

    private var loadFailureState: some View {
        VStack(alignment: .leading, spacing: 12) {
            MediaverseIcon(name: "alert-circle", fallbackSystemName: "exclamationmark.triangle")
                .frame(width: 28, height: 28)
                .foregroundStyle(C.watch)
            Text("Could not load channel settings")
                .font(.headline.weight(.semibold))
                .foregroundStyle(C.text)
            Text(errorMessage ?? "Check your connection and try again.")
                .font(.caption)
                .foregroundStyle(C.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Button("Retry") {
                Task { await loadChannel() }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(C.watch)
            .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(C.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(C.border, lineWidth: 1) }
    }

    private var loadingState: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 10).fill(C.elevated).frame(height: 46)
            RoundedRectangle(cornerRadius: 10).fill(C.elevated).aspectRatio(16.0 / 6.0, contentMode: .fit)
            HStack(spacing: 12) {
                Circle().fill(C.elevated).frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).fill(C.elevated).frame(width: 150, height: 12)
                    RoundedRectangle(cornerRadius: 4).fill(C.elevated).frame(width: 90, height: 10)
                }
            }
        }
        .redacted(reason: .placeholder)
    }

    private func imageUploadControl(
        title: String,
        url: Binding<String>,
        pickerItem: Binding<PhotosPickerItem?>,
        previewImage: UIImage?,
        existingURL: URL?,
        isUploading: Bool,
        aspectRatio: CGFloat,
        clearPreview: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if aspectRatio == 1 {
                avatarPreview(previewImage: previewImage, existingURL: existingURL, size: 96)
            } else {
                mediaPreview(previewImage: previewImage, existingURL: existingURL, aspectRatio: aspectRatio)
            }

            HStack(spacing: 10) {
                PhotosPicker(selection: pickerItem, matching: .images, photoLibrary: .shared()) {
                    HStack(spacing: 8) {
                        if isUploading {
                            ProgressView().tint(.black)
                        } else {
                            MediaverseIcon(name: "image", fallbackSystemName: "photo")
                                .frame(width: 15, height: 15)
                        }
                        Text(isUploading ? "Uploading..." : title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(C.watch)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .frame(maxWidth: .infinity)
                .disabled(isUploading || isSaving)

                if !url.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Clear") {
                        url.wrappedValue = ""
                        clearPreview()
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(C.textMuted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .disabled(isUploading || isSaving)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func bannerPreview(height: CGFloat) -> some View {
        mediaPreview(previewImage: bannerPreviewImage, existingURL: C.mediaURL(bannerUrl), aspectRatio: 16.0 / 6.0)
            .frame(height: height)
    }

    private func avatarPreview(size: CGFloat) -> some View {
        avatarPreview(previewImage: avatarPreviewImage, existingURL: C.mediaURL(avatarUrl), size: size)
    }

    @ViewBuilder
    private func avatarPreview(previewImage: UIImage?, existingURL: URL?, size: CGFloat) -> some View {
        ZStack {
            if let previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFill()
            } else if let existingURL {
                CachedRemoteImage(
                    url: existingURL,
                    targetSize: CGSize(width: size, height: size)
                ) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    avatarPlaceholder
                }
            } else {
                avatarPlaceholder
            }
        }
        .frame(width: size, height: size)
        .background(Color.white.opacity(0.05))
        .clipShape(Circle())
        .overlay { Circle().stroke(C.border, lineWidth: 1) }
    }

    private func mediaPreview(previewImage: UIImage?, existingURL: URL?, aspectRatio: CGFloat) -> some View {
        Color.white.opacity(0.05)
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    previewMediaContent(previewImage: previewImage, existingURL: existingURL)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                }
            }
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: aspectRatio == 1 ? 12 : 10))
            .overlay { RoundedRectangle(cornerRadius: aspectRatio == 1 ? 12 : 10).stroke(C.border, lineWidth: 1) }
    }

    @ViewBuilder
    private func previewMediaContent(previewImage: UIImage?, existingURL: URL?) -> some View {
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

    private var previewPlaceholder: some View {
        ZStack {
            Color.white.opacity(0.05)
            MediaverseIcon(name: "image", fallbackSystemName: "photo")
                .frame(width: 28, height: 28)
                .foregroundStyle(C.textMuted)
        }
    }

    private var avatarPlaceholder: some View {
        ZStack {
            Color.white.opacity(0.05)
            MediaverseIcon(name: "user", fallbackSystemName: "person")
                .frame(width: 26, height: 26)
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

    private enum ChannelImageType: String {
        case avatar
        case banner
    }

    private func loadChannel() async {
        isLoading = true
        errorMessage = nil
        do {
            let fetched = try await APIClient.shared.fetchBackstageChannel(channelId: channelId)
            channel = fetched
            name = fetched.name
            avatarUrl = fetched.avatarUrl ?? ""
            bannerUrl = fetched.bannerUrl ?? ""
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func uploadSelectedImage(_ item: PhotosPickerItem, type: ChannelImageType) async {
        setUploading(true, for: type)
        errorMessage = nil
        defer { setUploading(false, for: type) }

        do {
            guard let rawData = try await item.loadTransferable(type: Data.self),
                  let sourceImage = UIImage(data: rawData),
                  let uploadData = preparedJPEGData(from: sourceImage, maxPixel: type == .avatar ? 1200 : 1800)
            else {
                throw APIError.invalidResponse("Could not read the selected image.")
            }
            let uploadedURL = try await APIClient.shared.uploadBackstageImage(
                channelId: channelId,
                type: type.rawValue,
                imageData: uploadData
            )
            switch type {
            case .avatar:
                avatarUrl = uploadedURL
                avatarPreviewImage = sourceImage
                selectedAvatarItem = nil
            case .banner:
                bannerUrl = uploadedURL
                bannerPreviewImage = sourceImage
                selectedBannerItem = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setUploading(_ uploading: Bool, for type: ChannelImageType) {
        switch type {
        case .avatar: isUploadingAvatar = uploading
        case .banner: isUploadingBanner = uploading
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
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        isSaving = true
        errorMessage = nil
        do {
            let updated = try await APIClient.shared.updateBackstageChannel(
                channelId: channelId,
                name: trimmedName,
                avatarUrl: nilIfEmpty(avatarUrl),
                bannerUrl: nilIfEmpty(bannerUrl)
            )
            channel = updated
            name = updated.name
            avatarUrl = updated.avatarUrl ?? ""
            bannerUrl = updated.bannerUrl ?? ""
            onSaved?()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }

    private func nilIfEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
