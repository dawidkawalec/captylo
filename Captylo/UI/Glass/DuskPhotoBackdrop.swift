import SwiftUI

/// "Zmierzch": the blurred sunset over the lake, alive. The seamless video loop made from our own
/// photo (`DuskVideoView`, `scripts/make-dusk-video.sh`) plays over the photo (asset
/// `DuskWallpaper`, source copy in `docs/design/backdrops/`), which is its poster until the first
/// frame is ready and the fallback when the video cannot play. Both sit under a night-tinted
/// scrim so white text stays legible, and an optional soft vignette. `scrim` 0 shows the raw
/// image, 1 is heavy.
///
/// The video plays only while the window is key in the active app and on screen, and holds its
/// frame otherwise and with Reduce Motion.
@MainActor
struct DuskPhotoBackdrop: View {
    static let imageName = "DuskWallpaper"

    var scrim: Double
    var vignette: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                GlassColor.night

                Image(Self.imageName)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()

                DuskVideoView(isPlaying: !reduceMotion && controlActiveState == .key)
                    .frame(width: proxy.size.width, height: proxy.size.height)

                // Night-tinted wash, heavier at the top (page titles, subtitles and the
                // onboarding step labels sit on the bright lilac sky there) and at the bottom.
                LinearGradient(
                    stops: [
                        .init(color: GlassColor.night.opacity(min(1.6 * scrim, 0.9)), location: 0),
                        .init(color: GlassColor.night.opacity(1.1 * scrim), location: 0.25),
                        .init(color: GlassColor.night.opacity(0.30 * scrim), location: 0.45),
                        .init(color: GlassColor.night.opacity(0.65 * scrim), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                if vignette {
                    RadialGradient(
                        colors: [.clear, Color.black.opacity(0.35 * scrim)],
                        center: .center,
                        startRadius: min(proxy.size.width, proxy.size.height) * 0.35,
                        endRadius: max(proxy.size.width, proxy.size.height) * 0.8
                    )
                }
            }
        }
    }
}
