import SwiftUI

struct RentalInfoBar: View {
    let info: RentalInfo

    @State private var now = Date()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("Rental · \(info.productName)")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(C.watch)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(C.watch.opacity(0.20))
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                if let countdown = countdownText {
                    HStack(spacing: 0) {
                        Text(info.firstPlayedAt != nil ? "Playback window: " : "Rental expires in ")
                        Text(countdown)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.white.opacity(0.85))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.60))
                }

                if let playsLeft {
                    Text(playsLeft > 0 ? "\(playsLeft) play\(playsLeft == 1 ? "" : "s") left" : "No plays remaining")
                        .font(.system(size: 11))
                        .foregroundStyle(playsLeft == 0 ? Color.red.opacity(0.85) : Color.white.opacity(0.60))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(C.watch.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(C.watch.opacity(0.20), lineWidth: 1)
        }
        .onReceive(timer) { value in
            now = value
        }
    }

    private var countdownText: String? {
        guard let date = activeExpiryDate else { return nil }
        let diff = max(0, Int(floor(date.timeIntervalSince(now))))
        guard diff > 0 else { return "Expired" }

        let days = diff / 86400
        let hours = (diff % 86400) / 3600
        let minutes = (diff % 3600) / 60
        let seconds = diff % 60

        if days > 0 { return "\(days)d \(hours)h left" }
        if hours > 0 { return "\(hours)h \(minutes)m left" }
        if minutes > 0 { return "\(minutes)m \(seconds)s left" }
        return "\(seconds)s left"
    }

    private var activeExpiryDate: Date? {
        let activeExpiry = info.firstPlayedAt != nil ? info.playbackExpiresAt : info.validTo
        guard let activeExpiry else { return nil }
        return Self.parseISO(activeExpiry)
    }

    private var playsLeft: Int? {
        info.maxPlays.map { max(0, $0 - info.playsUsed) }
    }

    private static func parseISO(_ string: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractionalFormatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

extension RentalInfo {
    init(userRental rental: UserRental) {
        self.init(
            validTo: rental.validTo,
            playbackExpiresAt: rental.playbackExpiresAt,
            firstPlayedAt: rental.firstPlayedAt,
            playsUsed: rental.playsUsed ?? 0,
            maxPlays: rental.terms?.maxPlays,
            playbackWindowSecs: rental.terms?.playbackWindowSecs,
            productName: rental.product?.name ?? rental.product?.title ?? "Rental"
        )
    }
}
