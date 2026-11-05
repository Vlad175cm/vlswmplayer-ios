import SwiftUI
import UniformTypeIdentifiers

private let fg = Color.white
private let bg = Color.black

private func mono(_ size: CGFloat) -> Font {
    Font.custom("JetBrainsMonoNF-Regular", size: size)
}

private func timeText(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    let minutes = total / 60
    let secs = total % 60
    if minutes >= 60 {
        return String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, secs)
    }
    return String(format: "%d:%02d", minutes, secs)
}

struct ContentView: View {
    @EnvironmentObject private var model: Model
    @State private var dragFraction: Double?
    @State private var showNowPlaying = false
    @State private var showAudioImporter = false
    @State private var showLikesImporter = false
    @State private var showLikesExporter = false
    @State private var likesDocument = LikesFile(data: Data())

    var body: some View {
        VStack(spacing: 0) {
            header
            tabs
            if model.view == .search {
                searchField
            }
            list
            if model.uploadActive {
                uploadProgress
            }
            playerBar
        }
        .background(bg.ignoresSafeArea())
        .foregroundColor(fg)
        .preferredColorScheme(.dark)
        .fileImporter(
            isPresented: $showAudioImporter,
            allowedContentTypes: audioTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                model.importLocalFiles(urls)
            }
        }
        .fileImporter(isPresented: $showLikesImporter, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    model.importLikes(data: data)
                }
            }
        }
        .fileExporter(
            isPresented: $showLikesExporter,
            document: likesDocument,
            contentType: .json,
            defaultFilename: "vlswmplayer-likes"
        ) { _ in }
        .fullScreenCover(isPresented: $showNowPlaying) {
            NowPlayingView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }

    private var audioTypes: [UTType] {
        var types: [UTType] = [.audio, .mp3, .wav, .aiff]
        for ext in ["flac", "m4a", "aac", "caf", "alac"] {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        return types
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("VLSWM // PLAYER")
            Spacer()
            Text(model.hint).lineLimit(1)
            Menu {
                Button("ADD LOCAL FILES") { showAudioImporter = true }
                Button("EXPORT LIKES") {
                    likesDocument = LikesFile(data: model.likesDocumentData())
                    showLikesExporter = true
                }
                Button("IMPORT LIKES") { showLikesImporter = true }
            } label: {
                VStack(spacing: 3) {
                    ForEach(0..<3) { _ in
                        Rectangle().frame(width: 16, height: 2)
                    }
                }
                .frame(width: 26, height: 24)
            }
        }
        .font(mono(10))
        .padding(.horizontal, 12)
        .frame(height: 30)
        .overlay(Rectangle().frame(height: 1).foregroundColor(fg), alignment: .bottom)
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            tab("SEARCH", active: model.view == .search) { model.setView(.search) }
            tab("LIKES", active: model.view == .likes) { model.setView(.likes) }
            tab("UPLOADED", active: model.view == .uploaded) { model.setView(.uploaded) }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private func tab(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(mono(10))
                .padding(.horizontal, 12)
                .frame(height: 24)
                .background(active ? fg : bg)
                .foregroundColor(active ? bg : fg)
                .overlay(Rectangle().stroke(fg, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var searchField: some View {
        HStack(spacing: 0) {
            Text("> ")
            TextField("", text: Binding(get: { model.query }, set: { model.setQuery($0) }))
                .textFieldStyle(.plain)
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .font(mono(12))
                .foregroundColor(fg)
            if !model.query.isEmpty {
                Button {
                    model.setQuery("")
                } label: {
                    Text("x").font(mono(12))
                }
                .buttonStyle(.plain)
            }
        }
        .font(mono(12))
        .padding(.horizontal, 8)
        .frame(height: 32)
        .overlay(Rectangle().stroke(fg, lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.visible.enumerated()), id: \.element.id) { index, track in
                        SwipeRow(
                            enabled: model.view == .uploaded,
                            onDelete: { model.deleteUploaded(track) }
                        ) {
                            row(index: index, track: track)
                        }
                        .id(track.id)
                    }
                }
            }
            .onChange(of: model.selected) { value in
                if value < model.visible.count {
                    withAnimation(.linear(duration: 0.12)) {
                        proxy.scrollTo(model.visible[value].id, anchor: .center)
                    }
                }
            }
        }
    }

    private func row(index: Int, track: Track) -> some View {
        let selected = index == model.selected
        return Button {
            model.select(index)
        } label: {
            HStack(spacing: 8) {
                Text(String(format: "%02d", index + 1))
                    .frame(width: 26, alignment: .trailing)
                Text((model.isLiked(track.id) ? "* " : "") + track.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Text(timeText(Double(track.duration)))
                    .frame(width: 44, alignment: .trailing)
            }
            .font(mono(11))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(selected ? fg : bg)
            .foregroundColor(selected ? bg : fg)
        }
        .buttonStyle(.plain)
    }

    private var uploadProgress: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("UPLOADING \(model.uploadDone)/\(model.uploadTotal)  \(model.uploadLabel)")
                .font(mono(8))
                .lineLimit(1)
            bar(fraction: model.uploadTotal > 0
                ? Double(model.uploadDone) / Double(model.uploadTotal)
                : 0) { _ in }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    private var playerBar: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                artwork
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.current?.title ?? "NOTHING PLAYING")
                        .font(mono(13))
                        .lineLimit(1)
                    Text((model.current?.artist ?? "").uppercased())
                        .font(mono(9))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 64)

            HStack(spacing: 8) {
                Text(timeText(model.position)).font(mono(9))
                bar(fraction: progressFraction) { fraction in
                    model.seek(toFraction: fraction)
                }
                Text(timeText(model.duration)).font(mono(9))
            }

            HStack(spacing: 8) {
                Text("VOL").font(mono(9))
                bar(fraction: model.volume) { value in
                    model.setVolume(value)
                }
                .frame(width: 110)
                Text("\(Int(model.volume * 100))")
                    .font(mono(9))
                    .frame(width: 26, alignment: .trailing)
                Spacer(minLength: 0)
                controls
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .overlay(Rectangle().frame(height: 1).foregroundColor(fg), alignment: .top)
    }

    private var artwork: some View {
        Button {
            showNowPlaying = true
        } label: {
            artworkContent
        }
        .buttonStyle(.plain)
    }

    private var artworkContent: some View {
        Group {
            if let image = model.artwork {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    bg
                    Text("NO ART").font(mono(8))
                }
            }
        }
        .frame(width: 64, height: 64)
        .clipped()
        .overlay(Rectangle().stroke(fg, lineWidth: 1))
    }

    private var progressFraction: Double {
        guard model.duration > 0 else { return 0 }
        return min(max(model.position / model.duration, 0), 1)
    }

    private func bar(fraction: Double, onDrag: @escaping (Double) -> Void) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                bg
                Rectangle().frame(width: geo.size.width * CGFloat(min(max(fraction, 0), 1)))
                    .foregroundColor(fg)
                Rectangle().stroke(fg, lineWidth: 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let raw = value.location.x / max(1, geo.size.width)
                        dragFraction = min(max(raw, 0), 1)
                    }
                    .onEnded { value in
                        let raw = value.location.x / max(1, geo.size.width)
                        onDrag(min(max(raw, 0), 1))
                        dragFraction = nil
                    }
            )
        }
        .frame(height: 12)
    }

    private var controls: some View {
        HStack(spacing: 6) {
            control(likedCurrent ? "*" : "+") { model.toggleLikeCurrent() }
            control("|<") { model.goBack() }
            control(model.playing ? "||" : ">", filled: true) { model.togglePlay() }
            control(">|") { model.advance() }
        }
    }

    private var likedCurrent: Bool {
        guard let track = model.current else { return false }
        return model.isLiked(track.id)
    }

    private func control(_ title: String, filled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(mono(11))
                .frame(width: 44, height: 30)
                .background(filled ? fg : bg)
                .foregroundColor(filled ? bg : fg)
                .overlay(Rectangle().stroke(fg, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}


private struct SwipeRow<Content: View>: View {
    let enabled: Bool
    let onDelete: () -> Void
    let content: Content

    @State private var offset: CGFloat = 0

    private let width: CGFloat = 92

    init(enabled: Bool, onDelete: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.enabled = enabled
        self.onDelete = onDelete
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            if enabled {
                Button {
                    offset = 0
                    onDelete()
                } label: {
                    Text("DELETE")
                        .font(.custom("JetBrainsMonoNF-Regular", size: 10))
                        .foregroundColor(.white)
                        .frame(width: width, height: 28)
                        .background(Color.black)
                        .overlay(Rectangle().stroke(Color.white, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .opacity(offset < -2 ? 1 : 0)
            }

            Group {
                if enabled {
                    content
                        .background(Color.black)
                        .offset(x: offset)
                        .simultaneousGesture(drag)
                } else {
                    content
                }
            }
        }
        .clipped()
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                offset = min(0, max(-width, value.translation.width))
            }
            .onEnded { _ in
                offset = offset < -width / 2 ? -width : 0
            }
    }
}
