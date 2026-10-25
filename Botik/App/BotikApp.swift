import SwiftUI

@main
struct BotikApp: App {
    @State private var store = ChatStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
        }
    }
}
