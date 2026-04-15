import SwiftUI

@main
struct SimpleDisplayApp: App {
    @State private var viewModel = DisplayManagerViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environment(viewModel)
        } label: {
            Label("SimpleDisplay", systemImage: "display")
        }
        .menuBarExtraStyle(.window)
    }
}
