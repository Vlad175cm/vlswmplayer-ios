import SwiftUI

struct NowPlayingView: View {
    @EnvironmentObject private var model: Model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header

            Spacer(minLength: 8)

            artwork

            Spacer(minLength: 8)

            info

            controls
                .padding(.top, 14)
                .padding(.bottom, 10)
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .background(Color.black.ignoresSafeArea())
        .foregroundColor(.white)
        .gesture(
            DragGesture(minimumDistance: 20).onEnded { value in
                if value.translation.height > 80 { dismiss() }
            }
        )
    }

    private var header: some View {
        HStack {
            Text("NOW PLAYING")
                .font(.custom("JetBrainsMonoNF-Regular", size: 10))
            Spacer()
            Button {
                dismiss()
            } label: {
                Text("X")
                    .font(.custom("JetBrainsMonoNF-Regular", size: 12))
                    .frame(width: 34, height: 28)
                    .overlay(Rectangle().stroke(Color.white, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .frame(height: 30)
    }

    private var artwork: some View {
        Group {
            if let image = model.artwork {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.black
                    Text("NO ART")
                        .font(.custom("JetBrainsMonoNF-Regular", size: 11))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .overlay(Rectangle().stroke(Color.white, lineWidth: 1))
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.current?.title ?? "NOTHING PLAYING")
                .font(.custom("JetBrainsMonoNF-Regular", size: 18))
                .lineLimit(2)
                .minimumScaleFactor(0.7)

            Text((model.current?.artist ?? "").uppercased())
                .font(.custom("JetBrainsMonoNF-Regular", size: 10))
                .lineLimit(1)

            HStack(spacing: 8) {
                Text(time(model.position))
                bar(fraction: progressFraction) { model.seek(toFraction: $0) }
                Text(time(model.duration))
            }
            .font(.custom("JetBrainsMonoNF-Regular", size: 9))

            Text("LENGTH \(time(model.duration))")
                .font(.custom("JetBrainsMonoNF-Regular", size: 9))
        }
        .padding(.top, 12)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            button(liked ? "*" : "+") { model.toggleLikeCurrent() }
            button("|<") { model.goBack() }
            button(model.playing ? "||" : ">", filled: true) { model.togglePlay() }
            button(">|") { model.advance() }
        }
    }

    private func button(_ title: String, filled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.custom("JetBrainsMonoNF-Regular", size: 13))
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(filled ? Color.white : Color.black)
                .foregroundColor(filled ? Color.black : Color.white)
                .overlay(Rectangle().stroke(Color.white, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var liked: Bool {
        guard let track = model.current else { return false }
        return model.isLiked(track.id)
    }

    private var progressFraction: Double {
        guard model.duration > 0 else { return 0 }
        return min(max(model.position / model.duration, 0), 1)
    }

    private func time(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let minutes = total / 60
        let secs = total % 60
        if minutes >= 60 {
            return String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    private func bar(fraction: Double, onDrag: @escaping (Double) -> Void) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Color.black
                Rectangle()
                    .frame(width: geo.size.width * CGFloat(min(max(fraction, 0), 1)))
                    .foregroundColor(.white)
                Rectangle().stroke(Color.white, lineWidth: 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onEnded { value in
                    let raw = value.location.x / max(1, geo.size.width)
                    onDrag(min(max(raw, 0), 1))
                }
            )
        }
        .frame(height: 12)
    }
}
