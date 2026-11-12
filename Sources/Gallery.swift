import SwiftUI

struct Disegno: Identifiable, Codable {
    let id: UUID
    let date: Date
    let duration: TimeInterval
}

func fmt(_ t: TimeInterval) -> String {
    let s = Int(t)
    if s >= 3600 { return "\(s / 3600) h \(s % 3600 / 60) min" }
    if s >= 60 { return "\(s / 60) min \(s % 60) s" }
    return "\(s) s"
}

final class Store: ObservableObject {
    @Published var items: [Disegno] = []
    private let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private var index: URL { dir.appendingPathComponent("index.json") }

    init() {
        if let data = try? Data(contentsOf: index),
           let arr = try? JSONDecoder().decode([Disegno].self, from: data) { items = arr }
    }
    func url(_ d: Disegno) -> URL { dir.appendingPathComponent("\(d.id.uuidString).png") }
    func image(_ d: Disegno) -> UIImage? { UIImage(contentsOfFile: url(d).path) }
    func add(_ img: UIImage, duration: TimeInterval) {
        let d = Disegno(id: UUID(), date: Date(), duration: duration)
        try? img.pngData()?.write(to: url(d))
        items.insert(d, at: 0)
        save()
    }
    func remove(_ d: Disegno) {
        try? FileManager.default.removeItem(at: url(d))
        items.removeAll { $0.id == d.id }
        save()
    }
    private func save() { try? JSONEncoder().encode(items).write(to: index) }
}

struct GalleryView: View {
    @ObservedObject var store: Store
    @State private var selected: Disegno?
    private let cols = [GridItem(.adaptive(minimum: 160), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("I miei disegni").font(.largeTitle.bold())
                if store.items.isEmpty {
                    Text("Ancora nessun disegno. Passa a sinistra per crearne uno.")
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: cols, spacing: 14) {
                    ForEach(store.items) { d in
                        VStack(alignment: .leading, spacing: 6) {
                            thumb(d)
                            Text(d.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.footnote.bold())
                            Label(fmt(d.duration), systemImage: "timer")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .onTapGesture { selected = d }
                        .contextMenu {
                            Button("Elimina", systemImage: "trash", role: .destructive) { store.remove(d) }
                        }
                    }
                }
            }
            .padding().padding(.bottom, 90)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.07).ignoresSafeArea())
        .sheet(item: $selected) { d in
            ZStack { Color.white.ignoresSafeArea(); thumb(d).padding() }
        }
    }

    @ViewBuilder private func thumb(_ d: Disegno) -> some View {
        if let ui = store.image(d) {
            Image(uiImage: ui).resizable().scaledToFit()
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}
