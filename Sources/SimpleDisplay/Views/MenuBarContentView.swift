import SwiftUI

struct MenuBarContentView: View {
    @Environment(DisplayManagerViewModel.self) private var viewModel

    private var configuringDisplay: DisplayInfo? {
        guard case .configuringDisplay(let id) = viewModel.navigationState else { return nil }
        return viewModel.displays.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Button {
                    viewModel.navigate(to: .settings)
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.linearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 24, height: 24)
                        Image(systemName: "display")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isNavigating)

                Text("SimpleDisplay")
                    .font(.headline)
                Spacer()
                if viewModel.isBusy {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                } else {
                    Button {
                        viewModel.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Error banner
            if let error = viewModel.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(verbatim: error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    Spacer()
                    Button {
                        viewModel.errorMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.orange.opacity(0.1))
                .task(id: error) {
                    try? await Task.sleep(for: .seconds(8))
                    if viewModel.errorMessage == error {
                        viewModel.errorMessage = nil
                    }
                }

                Divider()
            }

            // Busy indicator
            if viewModel.isBusy, let message = viewModel.busyMessage {
                HStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                    Text(verbatim: message)
                        .font(.caption)
                        .foregroundStyle(.blue)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.1))
                .transition(.move(edge: .top).combined(with: .opacity))

                Divider()
            }

            switch viewModel.navigationState {
            case .settings:
                SettingsView()
                    .environment(viewModel)

            case .addVirtualDisplay:
                VirtualDisplayEditorView(editing: nil)
                    .environment(viewModel)

            case .configuringDisplay:
                if let display = configuringDisplay, display.isVirtual {
                    VirtualDisplayEditorView(editing: display)
                        .environment(viewModel)
                } else {
                    displayListContent
                }

            case .displayList:
                displayListContent
            }
        }
        .frame(width: 500)
        .onAppear {
            // Fix TextField focus in MenuBarExtra .window style
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Display List

    @ViewBuilder
    private var displayListContent: some View {
        if viewModel.displays.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "display.trianglebadge.exclamationmark")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No displays found")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(viewModel.displays) { display in
                        DisplayRowView(display: display)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
            }
            .frame(maxHeight: 450)
        }

        Divider()

        // Footer
        HStack(spacing: 10) {
            Button {
                viewModel.navigate(to: .settings)
            } label: {
                Image(systemName: "gearshape")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.isNavigating)

            Divider()
                .frame(height: 16)

            Button {
                viewModel.navigate(to: .addVirtualDisplay)
            } label: {
                Label("Virtual Display", systemImage: "plus.rectangle.on.rectangle")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.isBusy || viewModel.isNavigating)

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
