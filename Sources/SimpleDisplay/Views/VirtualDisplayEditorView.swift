import SwiftUI

/// Create or edit a virtual display. Pass `editing` to edit an existing one.
/// A compact form that fits the popover without scrolling: name, a preset
/// menu, panel size, zoom, and (when editing) the live mode.
struct VirtualDisplayEditorView: View {
    @Environment(DisplayManagerViewModel.self) private var viewModel
    @Environment(LocaleManager.self) private var locale

    let editing: DisplayInfo?
    /// Panel size and zoom the display was created with. The live mode can differ
    /// (a zoom level picked from the row menu, or macOS's remembered mode), so
    /// the editor starts from the saved config, not from what is on screen.
    private let saved: VirtualDisplayService.VirtualDisplayConfig?

    @State private var name: String
    @State private var width: Int
    @State private var height: Int
    @State private var hiDPI: Bool
    @State private var refreshRate: Double

    /// Common refresh rates offered in the picker. The underlying private API
    /// accepts any value up to ~488 Hz; 240 is the supported ceiling here.
    private static let refreshRateChoices: [Double] = [60, 72, 75, 90, 100, 120, 144, 165, 180, 240]

    /// The picker's options, with the display's own rate folded in so a config
    /// saved at a non-standard rate still shows a selected value.
    private var refreshOptions: [Double] {
        var options = Self.refreshRateChoices
        if !options.contains(refreshRate) { options.append(refreshRate); options.sort() }
        return options
    }

    private var isEditing: Bool { editing != nil }

    init(editing: DisplayInfo? = nil, saved: VirtualDisplayService.VirtualDisplayConfig? = nil) {
        self.editing = editing
        self.saved = saved
        if let d = editing {
            _name = State(initialValue: d.name)
            _width = State(initialValue: saved?.width ?? d.currentMode.width)
            _height = State(initialValue: saved?.height ?? d.currentMode.height)
            _hiDPI = State(initialValue: saved?.hiDPI ?? d.currentMode.isHiDPI)
            let current = d.currentMode.refreshRate
            _refreshRate = State(initialValue: saved?.refreshRate ?? (current > 0 ? current : 60))
        } else {
            _name = State(initialValue: "Virtual Display")
            _width = State(initialValue: 1920)
            _height = State(initialValue: 1080)
            _hiDPI = State(initialValue: false)
            _refreshRate = State(initialValue: 60)
        }
    }

    private var hasChanges: Bool {
        guard let d = editing else { return true }
        let baseW = saved?.width ?? d.currentMode.width
        let baseH = saved?.height ?? d.currentMode.height
        let baseHiDPI = saved?.hiDPI ?? d.currentMode.isHiDPI
        let baseRefresh = saved?.refreshRate ?? (d.currentMode.refreshRate > 0 ? d.currentMode.refreshRate : 60)
        return width != baseW || height != baseH || hiDPI != baseHiDPI
            || refreshRate != baseRefresh || name != d.name
    }

    /// What the desktop will look like: HiDPI renders the panel at 2x, so the
    /// usable area is half the pixels in each direction.
    private var looksLike: String {
        hiDPI ? "\(width / 2) x \(height / 2)" : "\(width) x \(height)"
    }

    /// The preset matching the current size, if any; it names the preset menu.
    private var matchingPreset: DevicePreset? {
        devicePresets.first { $0.width == width && $0.height == height }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            form
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)
            if isEditing && hasChanges {
                Text(locale.t("recreate_warning"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
            Divider()
            bottomBar
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack {
            Image(systemName: "rectangle.dashed")
                .foregroundStyle(.purple)
            Text(verbatim: isEditing ? name : locale.t("new_virtual_display"))
                .font(.headline)
                .lineLimit(1)
            if isEditing {
                BadgeView(text: locale.t("badge_virtual"), color: .purple)
            }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { close() }
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

    // MARK: - Form

    @ViewBuilder
    private var form: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                label("display_name")
                TextField(locale.t("virtual_display"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .gridCellColumns(2)
            }
            GridRow {
                label("preset")
                presetMenu
                    .gridCellColumns(2)
            }
            GridRow {
                label("panel_size")
                HStack(spacing: 6) {
                    TextField("W", value: $width, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                    Text(verbatim: "×").foregroundStyle(.secondary)
                    TextField("H", value: $height, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                    Text(locale.t("pixels"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .gridCellColumns(2)
            }
            GridRow {
                label("zoom")
                Picker("", selection: $hiDPI) {
                    Text(locale.t("zoom_1x")).tag(false)
                    Text(locale.t("zoom_2x")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
                Text(verbatim: locale.t("looks_like_format", looksLike))
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            GridRow {
                label("refresh_rate")
                Picker("", selection: $refreshRate) {
                    ForEach(refreshOptions, id: \.self) { rate in
                        Text(verbatim: "\(Int(rate)) Hz").tag(rate)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 120)
                Text(verbatim: locale.t("refresh_rate_help"))
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if let d = editing {
                GridRow {
                    label("active")
                    Text(verbatim: d.currentMode.localizedResolutionString(locale))
                        .font(.caption).foregroundStyle(.secondary)
                        .gridCellColumns(2)
                }
            }
        }
    }

    private func label(_ key: String) -> some View {
        Text(locale.t(key))
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 76, alignment: .leading)
    }

    /// Device presets as one popup button, grouped by family. Picking one fills
    /// the panel size and, unless the display already has a custom name, the name.
    @ViewBuilder
    private var presetMenu: some View {
        Picker("", selection: Binding<UUID?>(
            get: { matchingPreset?.id },
            set: { id in
                if let preset = devicePresets.first(where: { $0.id == id }) { apply(preset) }
            }
        )) {
            Text(locale.t("preset_custom")).tag(UUID?.none)
            ForEach(DevicePreset.PresetCategory.allCases, id: \.self) { cat in
                Section(cat.localizedName(locale)) {
                    ForEach(devicePresets.filter { $0.category == cat }) { preset in
                        Text(verbatim: "\(preset.name)  ·  \(preset.dimensionString)")
                            .tag(Optional(preset.id))
                    }
                }
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: 260, alignment: .leading)
    }

    private func apply(_ preset: DevicePreset) {
        let nameIsGeneric = !isEditing || name == "Virtual Display" || devicePresets.contains { $0.name == name }
        width = preset.width
        height = preset.height
        if nameIsGeneric { name = preset.name }
    }

    // MARK: - Bottom Bar

    @ViewBuilder
    private var bottomBar: some View {
        HStack(spacing: 8) {
            if let d = editing {
                Button(role: .destructive) {
                    viewModel.removeVirtualDisplay(d)
                    viewModel.navigate(to: .displayList)
                } label: {
                    Image(systemName: "trash").font(.caption2)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .help(locale.t("remove"))
                .disabled(viewModel.isBusy)

                if !d.isMain, d.isActive {
                    Button {
                        viewModel.setAsMainDisplay(d)
                    } label: {
                        Image(systemName: "star.fill").font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .help(locale.t("badge_set_main"))
                    .disabled(viewModel.isBusy)
                }

                Button {
                    viewModel.reconfigureVirtualDisplay(
                        d, width: width, height: height,
                        refreshRate: refreshRate, hiDPI: hiDPI, name: name
                    )
                } label: {
                    Text(verbatim: locale.t("apply_format", width, height))
                        .font(.caption).fontWeight(.medium)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(hasChanges && !viewModel.isBusy ? .purple : .gray)
                .disabled(!hasChanges || viewModel.isBusy)
            } else {
                Button(locale.t("cancel")) {
                    withAnimation(.easeInOut(duration: 0.2)) { close() }
                }

                Button {
                    viewModel.newDisplayConfig = VirtualDisplayService.VirtualDisplayConfig(
                        name: name, width: width, height: height,
                        refreshRate: refreshRate, hiDPI: hiDPI
                    )
                    viewModel.createVirtualDisplay()
                } label: {
                    Text(verbatim: locale.t("create_format", width, height))
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
