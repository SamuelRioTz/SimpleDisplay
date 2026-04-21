import SwiftUI

@main
struct SimpleDisplayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var locale = LocaleManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environment(appDelegate.viewModel)
                .environment(locale)
                .onAppear { appDelegate.viewModel.locale = locale }
        } label: {
            Label("SimpleDisplay", systemImage: "display")
        }
        .menuBarExtraStyle(.window)
    }
}
