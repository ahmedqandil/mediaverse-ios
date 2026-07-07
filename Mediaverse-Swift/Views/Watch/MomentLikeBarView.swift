import SwiftUI

// MARK: - MomentLikeBarView
// Mirrors the seek-bar heatmap + "Like Moment" button from VideoPlayer.tsx.
//
// Placed immediately below the AVKit player (on Color.black background).
// Contains:
//   — "Top Moments" label + bezier wave (Canvas) — only shown when data present
//   — Progress track bar with liked-second ticks
//   — ♥ Moment button (green when current second is liked)
//   — Rising heart animation on like tap

private let BUCKET_SIZE: Double = 5   // seconds per bucket — must match server
private let WAVE_H:      CGFloat = 24  // wave canvas height (pts)
private let TRACK_H:     CGFloat = 4   // seek track height

struct MomentLikeBarView: View {
    let buckets: [Int]
    let likedSeconds: [Int]
    let duration: Double
    let currentSec: Int
    let isAuthenticated: Bool
    let onLikeMoment: (Int) -> Void

    @State private var heartOffset:  CGFloat = 0
    @State private var heartOpacity: Double  = 0

    private var hasHeatmap: Bool {
        !buckets.isEmpty && (buckets.max() ?? 0) > 0
    }

    private var isCurrentSecLiked: Bool {
        likedSeconds.contains(currentSec)
    }

    private var uniqueLikedSeconds: [Int] {
        Array(Set(likedSeconds)).sorted()
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {

            // ── Heatmap + track ───────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 0) {

                // "Top Moments" label — only when wave data present
                if hasHeatmap {
                    HStack(spacing: 3) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 7, weight: .bold))
                        Text("Top Moments")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.8)
                            .textCase(.uppercase)
                    }
                    .foregroundStyle(C.watch.opacity(0.55))
                    .padding(.bottom, 3)
                }

                // Wave canvas
                if hasHeatmap {
                    Canvas { ctx, size in
                        drawWave(ctx: ctx, size: size)
                    }
                    .frame(height: WAVE_H)
                    .padding(.bottom, 2)
                }

                // Track + ticks — use GeometryReader only here for width
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .leading) {
                        // Background
                        Capsule().fill(Color.white.opacity(0.2))
                            .frame(height: TRACK_H)
                        // Progress
                        if duration > 0 {
                            let pct = min(1.0, Double(currentSec) / duration)
                            Capsule().fill(C.watch)
                                .frame(width: max(0, CGFloat(pct) * w), height: TRACK_H)
                        }
                        // User-liked moment markers
                        if duration > 0 {
                            ForEach(uniqueLikedSeconds, id: \.self) { sec in
                                let x = min(1.0, Double(sec) / duration) * w
                                likedMomentMarker(isCurrent: sec == currentSec)
                                    .offset(x: CGFloat(x) - 5, y: -8)
                            }
                        }
                    }
                    .frame(height: TRACK_H)
                    .frame(maxWidth: .infinity)
                }
                .frame(height: TRACK_H)
            }

            // ── ♥ Moment button + rising heart ────────────────────────────────
            if isAuthenticated {
                ZStack {
                    Button {
                        onLikeMoment(currentSec)
                        // Trigger rising heart animation
                        heartOffset  = 0
                        heartOpacity = 1
                        withAnimation(.easeOut(duration: 1.2)) {
                            heartOffset  = -52
                            heartOpacity = 0
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isCurrentSecLiked ? "heart.fill" : "heart")
                                .font(.system(size: 12))
                            Text("Moment")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(isCurrentSecLiked ? C.watch : Color.white.opacity(0.75))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(isCurrentSecLiked ? C.watch.opacity(0.20) : Color.white.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .overlay {
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(
                                    isCurrentSecLiked ? C.watch.opacity(0.45) : Color.white.opacity(0.15),
                                    lineWidth: 1
                                )
                        }
                    }
                    .buttonStyle(.plain)

                    // Rising heart on tap
                    Image(systemName: "heart.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(C.watch)
                        .offset(y: heartOffset)
                        .opacity(heartOpacity)
                        .allowsHitTesting(false)
                }
                .frame(width: 80)  // fixed width so track fills remaining space
            }
        }
        .padding(.horizontal, C.pagePad)
    }

    private func likedMomentMarker(isCurrent: Bool) -> some View {
        Image(systemName: "heart.fill")
            .font(.system(size: isCurrent ? 10 : 9, weight: .bold))
            .foregroundStyle(C.watch.opacity(isCurrent ? 0.38 : 0.22))
            .frame(width: 10, height: 10)
            .accessibilityLabel("Liked moment")
    }

    // MARK: - Wave drawing (mirrors VideoPlayer.tsx bezier math exactly)

    private func drawWave(ctx: GraphicsContext, size: CGSize) {
        guard hasHeatmap, duration > 0 else { return }

        let maxBuckets = max(2, min(Int(ceil(duration / BUCKET_SIZE)) + 1, buckets.count))
        let trimmed    = Array(buckets.prefix(maxBuckets)).map { CGFloat($0) }
        guard trimmed.count >= 2 else { return }

        let bucketCount = trimmed.count
        let maxVal      = trimmed.max() ?? 1
        let W           = size.width
        let H           = size.height

        // Points: same formula as web — y = H - max(2, (v/maxVal)*H*0.90)
        let pts: [(CGFloat, CGFloat)] = trimmed.enumerated().map { (i, v) in
            let x = (CGFloat(i) / CGFloat(max(1, bucketCount - 1))) * W
            let y = H - max(2, (v / max(1, maxVal)) * H * 0.90)
            return (x, y)
        }

        // Bezier stroke path (catmull-rom-like using midpoint control points)
        var stroke = Path()
        stroke.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
        for i in 0 ..< pts.count - 1 {
            let mx = (pts[i].0 + pts[i + 1].0) / 2
            stroke.addCurve(
                to:       CGPoint(x: pts[i + 1].0, y: pts[i + 1].1),
                control1: CGPoint(x: mx,            y: pts[i].1),
                control2: CGPoint(x: mx,            y: pts[i + 1].1)
            )
        }

        // Closed fill path
        var fill = stroke
        fill.addLine(to: CGPoint(x: W, y: H))
        fill.addLine(to: CGPoint(x: 0, y: H))
        fill.closeSubpath()

        // Draw fill (gradient: watch@25% → watch@1%)
        ctx.fill(
            fill,
            with: .linearGradient(
                Gradient(colors: [C.watch.opacity(0.25), C.watch.opacity(0.01)]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint:   CGPoint(x: 0, y: H)
            )
        )

        // Draw stroke
        ctx.stroke(
            stroke,
            with:  .color(C.watch.opacity(0.35)),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
        )

        // Current-position needle
        if duration > 0 {
            let nx = CGFloat(currentSec) / CGFloat(duration) * W
            var needle = Path()
            needle.move(to: CGPoint(x: nx, y: 0))
            needle.addLine(to: CGPoint(x: nx, y: H))
            ctx.stroke(needle,
                       with:  .color(Color.white.opacity(0.55)),
                       style: StrokeStyle(lineWidth: 1.5))
        }
    }
}
