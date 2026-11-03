import SwiftUI

@main
struct VLSWMPlayerApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}
