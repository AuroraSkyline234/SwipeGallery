import SwiftUI
import Photos
import AVKit

@main
struct SwipeGalleryApp: App {
    var body: some Scene { WindowGroup { GalleryView() } }
}

private struct Decision: Codable {
    let id: String
    let delete: Bool
}

@MainActor
final class GalleryStore: ObservableObject {
    @Published var assets: [PHAsset] = []
    @Published var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published var busy = false
    @Published var error: String?
    @Published private var decisions: [Decision] = []
    private let key = "SwipeGallery.decisions.v1"
    var current: PHAsset? { assets.first }
    var pendingIDs: [String] { decisions.filter(\.delete).map(\.id) }
    var reviewed: Int { decisions.count }
    var canUndo: Bool { !decisions.isEmpty }

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([Decision].self, from: data) {
            decisions = saved
        }
    }

    func refresh() async {
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { assets = []; return }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                       PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: options)
        var available: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in available.append(asset) }
        let liveIDs = Set(available.map(\.localIdentifier))
        // Remove decisions for assets deleted elsewhere or no longer shared with this app.
        decisions.removeAll { !liveIDs.contains($0.id) }
        let seen = Set(decisions.map(\.id))
        assets = available.filter { !seen.contains($0.localIdentifier) }
        persist()
    }

    func authorize() async {
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        await refresh()
    }

    func decide(delete: Bool) {
        guard !busy, let asset = current else { return }
        decisions.append(Decision(id: asset.localIdentifier, delete: delete))
        assets.removeFirst()
        persist()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func undo() async {
        guard !busy, !decisions.isEmpty else { return }
        decisions.removeLast()
        persist()
        await refresh()
    }

    func reset() async {
        guard !busy else { return }
        decisions.removeAll()
        persist()
        await refresh()
    }

    func deleteSelected() async {
        guard !busy, !pendingIDs.isEmpty else { return }
        busy = true
        defer { busy = false }
        let ids = Set(pendingIDs)
        let selected = PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: nil)
        do {
            if selected.count > 0 {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets(selected)
                }
            }
            decisions.removeAll { ids.contains($0.id) }
            persist()
            await refresh()
        } catch {
            // Keep every selection if the system dialog is cancelled or deletion fails.
            self.error = "Файлы не удалены. Выбор сохранён. " + error.localizedDescription
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(decisions) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

struct GalleryView: View {
    @StateObject private var store = GalleryStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var drag: CGFloat = 0
    @State private var resetConfirmation = false
    private let mint = Color(red: 0.64, green: 0.98, blue: 0.76)
    private let coral = Color(red: 1, green: 0.43, blue: 0.40)

    var body: some View {
        ZStack {
            Color(red: 0.055, green: 0.065, blue: 0.07).ignoresSafeArea()
            VStack(spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Листай").font(.largeTitle.bold())
                        Text("Меньше лишнего. Больше места.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button("Обновить галерею") { Task { await store.refresh() } }
                        Button("Настройки доступа") { openSettings() }
                        Button("Начать заново") { resetConfirmation = true }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.title2).padding(8)
                    }.accessibilityLabel("Настройки")
                }
                if store.status == .authorized || store.status == .limited {
                    if store.status == .limited {
                        Button("Виден только выбранный вами набор · Настройки") { openSettings() }
                            .font(.caption).foregroundStyle(mint)
                    }
                    HStack {
                        Text("Просмотрено: \(store.reviewed)")
                        Spacer()
                        Text("Осталось: \(store.assets.count)")
                    }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if let asset = store.current {
                        MediaCard(asset: asset)
                            .overlay(alignment: .top) {
                                if abs(drag) > 30 {
                                    Text(drag > 0 ? "УДАЛИТЬ" : "ОСТАВИТЬ")
                                        .font(.title.bold()).padding(12)
                                        .background(drag > 0 ? coral : mint)
                                        .foregroundStyle(.black).clipShape(Capsule()).padding(20)
                                }
                            }
                            .offset(x: drag)
                            .rotationEffect(.degrees(Double(drag / 24)))
                            .gesture(DragGesture(minimumDistance: 25)
                                .onChanged { value in
                                    if !store.busy { drag = value.translation.width }
                                }
                                .onEnded { value in
                                    if abs(value.translation.width) > 90 {
                                        store.decide(delete: value.translation.width > 0)
                                    }
                                    withAnimation(.spring()) { drag = 0 }
                                })
                            .id(asset.localIdentifier)
                    } else {
                        message("Всё просмотрено", detail: "Обновите галерею позже или начните заново.", icon: "checkmark.circle")
                    }
                    HStack(spacing: 18) {
                        action("Оставить", icon: "arrow.left", color: mint) { store.decide(delete: false) }
                            .disabled(store.current == nil || store.busy)
                        Button { Task { await store.undo() } } label: {
                            Image(systemName: "arrow.uturn.backward").font(.title2)
                                .frame(width: 48, height: 48).background(.white.opacity(0.08), in: Circle())
                        }.disabled(!store.canUndo || store.busy).accessibilityLabel("Отменить последний свайп")
                        action("Удалить", icon: "arrow.right", color: coral) { store.decide(delete: true) }
                            .disabled(store.current == nil || store.busy)
                    }
                    Text("← оставить     •     удалить →").font(.caption).foregroundStyle(.secondary)
                    Button { Task { await store.deleteSelected() } } label: {
                        HStack {
                            if store.busy { ProgressView() } else { Image(systemName: "trash") }
                            Text("Удалить выбранное: \(store.pendingIDs.count)").bold()
                        }.frame(maxWidth: .infinity).padding(16)
                            .background(coral.opacity(store.pendingIDs.isEmpty ? 0.15 : 1), in: RoundedRectangle(cornerRadius: 18))
                            .foregroundStyle(store.pendingIDs.isEmpty ? .gray : .black)
                    }.disabled(store.pendingIDs.isEmpty || store.busy)
                    Text("Свайп выбирает файл. Удаление — после подтверждения iOS.")
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                } else {
                    message("Разберём галерею?", detail: "Фото и видео по очереди. Ваши файлы остаются на устройстве: приложение никуда их не отправляет.", icon: "rectangle.stack")
                    Button(store.status == .notDetermined ? "Открыть галерею" : "Разрешить доступ в настройках") {
                        if store.status == .notDetermined { Task { await store.authorize() } }
                        else { openSettings() }
                    }.buttonStyle(.borderedProminent).tint(mint).foregroundStyle(.black)
                    Spacer()
                }
            }.padding(20)
        }
        .preferredColorScheme(.dark)
        .task { await store.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && !store.busy { Task { await store.refresh() } }
        }
        .alert("Не удалось удалить", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("Понятно", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
        .confirmationDialog("Сбросить все решения? Файлы не удалятся.", isPresented: $resetConfirmation, titleVisibility: .visible) {
            Button("Начать заново", role: .destructive) { Task { await store.reset() } }
        }
    }

    private func action(_ title: String, icon: String, color: Color, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: 5) { Image(systemName: icon).font(.title2); Text(title).font(.caption.bold()) }
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 18)).foregroundStyle(color)
        }
    }

    private func message(_ title: String, detail: String, icon: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 54)).foregroundStyle(mint)
            Text(title).font(.title2.bold())
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

struct MediaCard: View {
    let asset: PHAsset
    @State private var thumbnail: UIImage?
    @State private var player: AVPlayer?
    @State private var loading = true
    @State private var failed = false
    @State private var request: PHImageRequestID?
    @State private var token = UUID()

    var body: some View {
        ZStack {
            Color.white.opacity(0.045)
            if let player {
                VideoPlayer(player: player)
            } else if let thumbnail {
                GeometryReader { geometry in
                    Image(uiImage: thumbnail).resizable().scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            if loading { ProgressView("Загрузка…").padding().background(.ultraThinMaterial, in: Capsule()) }
            if failed {
                VStack(spacing: 8) {
                    Image(systemName: "icloud.slash")
                    Text("Не удалось загрузить файл").font(.callout)
                    Button("Повторить") { load() }
                }.padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 6) {
                Image(systemName: asset.mediaType == .video ? "video.fill" : "photo")
                if let date = asset.creationDate { Text(date.formatted(date: .abbreviated, time: .omitted)) }
            }.font(.caption).padding(10).background(.ultraThinMaterial, in: Capsule()).padding(12)
        }
        .onAppear { load() }
        .onDisappear {
            token = UUID()
            if let request { PHImageManager.default().cancelImageRequest(request) }
            player?.pause()
            player = nil
        }
    }

    private func load() {
        if let request { PHImageManager.default().cancelImageRequest(request) }
        token = UUID()
        let active = token
        loading = true
        failed = false
        if asset.mediaType == .video {
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            request = PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                DispatchQueue.main.async {
                    guard token == active else { return }
                    loading = false
                    if let item { player = AVPlayer(playerItem: item) } else { failed = true }
                }
            }
        } else {
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            request = PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 1400, height: 1800), contentMode: .aspectFit, options: options) { image, _ in
                DispatchQueue.main.async {
                    guard token == active else { return }
                    loading = false
                    thumbnail = image
                    failed = image == nil
                }
            }
        }
    }
}
