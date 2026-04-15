import SwiftUI

/// Unified view for creating and editing virtual displays.
/// Pass `editing` to edit an existing display, or nil to create a new one.
struct VirtualDisplayEditorView: View {
    @Environment(DisplayManagerViewModel.self) private var viewModel

    let editing: DisplayInfo?

    @State private var name: String
    @State private var width: Int
    @State private var height: Int
    @State private var hiDPI: Bool
    @State private var selectedPresetCategory: DevicePreset.PresetCategory = .tv

    private var isEditing: Bool { editing != nil }

    init(editing: DisplayInfo? = nil) {
        self.editing = editing
        if let d = editing {
            _name = State(initialValue: d.name)
            _width = State(initialValue: d.currentMode.width)
            _height = State(initialValue: d.currentMode.height)
            _hiDPI = State(initialValue: d.currentMode.isHiDPI)
        } else {
            _name = State(initialValue: "Virtual Display")
            _width = State(initialValue: 1920)
            _height = State(initialValue: 1080)
            _hiDPI = State(initialValue: false)
        }
    }

    private var hasChanges: Bool {
        guard let d = editing else { return true }
        return width != d.currentMode.width
            || height != d.currentMode.height
            || hiDPI != d.currentMode.isHiDPI
            || name != d.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    nameSection
                    Divider()
                    resolutionSection
                    Divider()
                    presetsSection
                    Divider()
                    settingsSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            // Warning (edit mode only)
            if isEditing && hasChanges {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text(verbatim: "Applying changes will recreate the display. Use Settings to clean cached data.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(.orange.opacity(0.05))
            }

            // Sticky bottom bar
            Divider()
            bottomBar
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        HStack {
            Image(systemName: "rectangle.dashed")
                .foregroundStyle(.purple)
            Text(verbatim: isEditing ? name : "New Virtual Display")
                .font(.headline)
            if isEditing {
                BadgeView(text: "Virtual", color: .purple)
            }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    close()
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Name

    @ViewBuilder
    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "Display Name")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Virtual Display", text: $name)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Resolution

    @ViewBuilder
    private var resolutionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isEditing {
                HStack {
                    Text(verbatim: "Active")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .leading)
                    Spacer()
                    Text(verbatim: editing?.currentMode.resolutionString ?? "")
                        .font(.caption).fontWeight(.medium)
                }
            }

            HStack {
                Text(verbatim: "Resolution")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)
                TextField("W", value: $width, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 75)
                Text(verbatim: "x").foregroundStyle(.secondary)
                TextField("H", value: $height, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 75)
                Spacer()
            }

        }
    }

    // MARK: - Presets

    @ViewBuilder
    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "Device Presets")
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 4) {
                ForEach(DevicePreset.PresetCategory.allCases, id: \.self) { cat in
                    presetTab(cat)
                }
            }

            let filtered = devicePresets.filter { $0.category == selectedPresetCategory }
            VStack(spacing: 0) {
                ForEach(filtered) { preset in
                    presetRow(preset)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            )
        }
    }

    @ViewBuilder
    private func presetTab(_ cat: DevicePreset.PresetCategory) -> some View {
        if selectedPresetCategory == cat {
            Button { selectedPresetCategory = cat } label: {
                Text(verbatim: cat.rawValue).font(.caption2)
                    .padding(.horizontal, 8).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent).controlSize(.small).tint(.purple)
        } else {
            Button { selectedPresetCategory = cat } label: {
                Text(verbatim: cat.rawValue).font(.caption2)
                    .padding(.horizontal, 8).padding(.vertical, 4)
            }
            .buttonStyle(.bordered).controlSize(.small).tint(.gray)
        }
    }

    @ViewBuilder
    private func presetRow(_ preset: DevicePreset) -> some View {
        let isActive = width == preset.width && height == preset.height
        Button {
            width = preset.width
            height = preset.height
            name = preset.name
        } label: {
            HStack {
                Text(verbatim: preset.name).font(.caption)
                    .foregroundStyle(isActive ? .purple : .primary)
                Spacer()
                Text(verbatim: preset.dimensionString)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isActive ? Color.purple.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Settings

    @ViewBuilder
    private var settingsSection: some View {
        Toggle("HiDPI (Retina)", isOn: $hiDPI)
            .toggleStyle(.switch)
    }

    // MARK: - Bottom Bar

    @ViewBuilder
    private var bottomBar: some View {
        HStack(spacing: 8) {
            if isEditing {
                // Set as Main
                if let d = editing, !d.isMain, d.isActive {
                    Button {
                        viewModel.setAsMainDisplay(d)
                    } label: {
                        Image(systemName: "star.fill").font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isBusy)
                }

                // Remove
                Button(role: .destructive) {
                    if let d = editing {
                        viewModel.removeVirtualDisplay(d)
                        viewModel.navigate(to: .displayList)
                    }
                } label: {
                    Image(systemName: "trash").font(.caption2)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(viewModel.isBusy)

                // Apply
                Button {
                    if let d = editing {
                        viewModel.reconfigureVirtualDisplay(
                            d, width: width, height: height,
                            hiDPI: hiDPI, name: name
                        )
                    }
                } label: {
                    Text(verbatim: "Apply \(width) x \(height)")
                        .font(.caption).fontWeight(.medium)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(hasChanges && !viewModel.isBusy ? .purple : .gray)
                .disabled(!hasChanges || viewModel.isBusy)
            } else {
                Button("Cancel") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        close()
                    }
                }

                Button {
                    viewModel.newDisplayConfig = VirtualDisplayService.VirtualDisplayConfig(
                        name: name, width: width, height: height, hiDPI: hiDPI
                    )
                    viewModel.createVirtualDisplay()
                } label: {
                    Text(verbatim: "Create \(width) x \(height)")
                        .font(.caption).fontWeight(.medium)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(viewModel.isBusy ? .gray : .purple)
                .disabled(viewModel.isBusy)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func close() {
        viewModel.navigate(to: .displayList)
    }
}
