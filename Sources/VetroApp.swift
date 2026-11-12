import SwiftUI

@main
struct VetroApp: App {
    var body: some Scene {
        WindowGroup { ContentView().preferredColorScheme(.dark) }
    }
}

extension View {
    @ViewBuilder func glass<S: Shape>(_ shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.tint(.black.opacity(0.3)).interactive(), in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}

struct ContentView: View {
    @StateObject private var store = Store()
    @StateObject private var tracer = Tracer()
    @State private var page = 1   // 0 = live, 1 = galleria (all'avvio)

    var body: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                if page == 0 {
                    LiveView(tracer: tracer, store: store) { page = 1 }
                        .transition(.move(edge: .leading))
                } else {
                    GalleryView(store: store)
                        .transition(.move(edge: .trailing))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.smooth, value: page)
            PagePill(page: $page).padding(.bottom, 10)
        }
        .onChange(of: page) { _, p in tracer.run(p == 0) }
    }
}

struct PagePill: View {
    @Binding var page: Int
    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.ultraThinMaterial)
            Color.clear.frame(width: 64, height: 48)
                .glass(Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.25)))
                .offset(x: page == 0 ? 4 : 68)
            HStack(spacing: 0) {
                Image(systemName: "camera.viewfinder")
                    .frame(width: 64, height: 48)
                    .foregroundStyle(page == 0 ? .primary : .secondary)
                Image(systemName: "square.grid.2x2")
                    .frame(width: 64, height: 48)
                    .foregroundStyle(page == 1 ? .primary : .secondary)
            }
            .font(.title3).padding(.leading, 4)
        }
        .frame(width: 136, height: 56)
        .contentShape(Capsule())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            page = v.location.x < 68 ? 0 : 1
        })
        .animation(.smooth, value: page)
    }
}
