import SwiftUI

@main
struct SimpleDisplayApp: App {
    @State private var viewModel = DisplayManagerViewModel()
    @State private var locale = LocaleManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environment(viewModel)
                .environment(locale)
                .onAppear { viewModel.locale = locale }
        } label: {
            Label("SimpleDisplay", systemImage: "display")
        }
        .menuBarExtraStyle(.window)
    }
}
