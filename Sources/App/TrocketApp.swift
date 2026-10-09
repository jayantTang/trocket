import SwiftUI

@main
struct TrocketApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task { await model.onAppear() }
        }
    }
}
