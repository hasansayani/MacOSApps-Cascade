import SwiftUI
import AppKit
import CascadeCore
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    var borders: BorderController? = nil
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    private var s: Binding<CascadeSettings> { $store.settings }
    private var settings: CascadeSettings { store.settings }

    /// Groups available on the main display with the current grid.
    private var groupCount: Int {
        let width = NSScreen.main?.visibleFrame.width ?? 1440
        let columns = settings.columns == 0 ? GroupGrid.autoColumns(forWidth: width) : settings.columns
        return columns * settings.rows
    }

    var body: some View {
        Form {
            Section {
                LayoutPreview(settings: settings)
                    .frame(height: 190)
                    .frame(maxWidth: .infinity)
            }

            Section("Window Size") {
                Picker("Size", selection: s.sizeMode) {
                    Text("Fill group").tag(SizeMode.auto)
                    Text("Custom").tag(SizeMode.custom)
                }
                .pickerStyle(.segmented)
                if settings.sizeMode == .custom {
                    PercentSlider(title: "Width", value: s.widthPercent)
                    PercentSlider(title: "Height", value: s.heightPercent)
                } else {
                    Text("Windows grow to fill their group, shrinking as the stack gets deeper.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                PointSlider(title: "Top (title bar)", value: s.revealTop)
                PointSlider(title: "Left edge", value: s.revealLeft)
            } header: {
                Text("Visible Part of Windows Underneath")
            } footer: {
                Text("How much of each covered window stays visible. 30–40 pt shows the full title bar.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Cascade Groups") {
                Picker("Columns", selection: s.columns) {
                    Text("Automatic").tag(0)
                    ForEach(1...CascadeSettings.maxColumns, id: \.self) { Text("\($0)").tag($0) }
                }
                Stepper("Rows: \(settings.rows)", value: s.rows, in: 1...CascadeSettings.maxRows)
                PointSlider(title: "Gap", value: s.groupGap, range: 0...60)
                Picker("Group by", selection: s.groupingMode) {
                    Text("Application").tag(GroupingMode.application)
                    Text("Manual").tag(GroupingMode.manual)
                }
                if settings.groupingMode == .application {
                    Toggle("Let used groups take space from empty ones", isOn: s.collapseEmptyGroups)
                } else {
                    AppGroupRules(rules: s.appGroups, groupCount: groupCount)
                }
            }

            Section("Displays") {
                Picker("Cascade", selection: s.displayMode) {
                    Text("Keep windows on their own display").tag(DisplayMode.eachDisplay)
                    Text("Gather all windows onto the display under the pointer").tag(DisplayMode.pointerScreen)
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
            }

            Section {
                Toggle("Drag a window onto a group to snap it", isOn: s.dragToSnap)
                if settings.dragToSnap {
                    Picker("While holding", selection: s.snapModifier) {
                        Text("⇧ Shift").tag(SnapModifier.shift)
                        Text("⌃ Control").tag(SnapModifier.control)
                        Text("⌥ Option").tag(SnapModifier.option)
                        Text("⌘ Command").tag(SnapModifier.command)
                    }
                }
                Toggle("⌃⌥1 – ⌃⌥9 snap the focused window to group 1–9", isOn: s.snapHotkeys)
            } header: {
                Text("Snapping")
            } footer: {
                Text("A snapped window stays in its group until it closes or you choose Reset Snapped Windows.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Cascade visible windows") {
                    ShortcutRecorder(shortcut: s.cascadeVisibleShortcut)
                }
                LabeledContent("Cascade all windows") {
                    ShortcutRecorder(shortcut: s.cascadeAllShortcut)
                }
            } header: {
                Text("Keyboard Shortcuts")
            } footer: {
                if !HotKeys.failed.isEmpty {
                    Text("Unavailable (in use by another app): \(HotKeys.failed.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Section {
                Toggle("Outline each app's windows in its own color", isOn: s.bordersEnabled)
                if settings.bordersEnabled {
                    Picker("Style", selection: s.borderStyle) {
                        Text("Icon colors").tag(BorderStyle.natural)
                        Text("Vibrant").tag(BorderStyle.vibrant)
                        Text("High contrast").tag(BorderStyle.highContrast)
                        Text("One color").tag(BorderStyle.custom)
                    }
                    .pickerStyle(.segmented)
                    if settings.borderStyle == .custom {
                        ColorPicker("Border color", selection: Binding(
                            get: {
                                let c = settings.borderCustomColor
                                return Color(.sRGB, red: c.red, green: c.green, blue: c.blue)
                            },
                            set: { color in
                                if let c = NSColor(color).usingColorSpace(.sRGB) {
                                    store.settings.borderCustomColor = RGBColor(red: c.redComponent, green: c.greenComponent,
                                                                                blue: c.blueComponent)
                                }
                            }), supportsOpacity: false)
                    }
                    PointSlider(title: "Thickness", value: s.borderWidth, range: CascadeSettings.borderWidthRange)
                    if let borders { BorderSwatches(borders: borders) }
                }
            } header: {
                Text("Window Borders")
            } footer: {
                Text(borderFooter).font(.caption).foregroundStyle(.secondary)
            }

            Section {
                MenuBarIconPicker(selection: s.menuBarIcon, customTemplate: s.customIconIsTemplate)
                AppIconPicker(selection: s.appIcon)
            } header: {
                Text("Appearance")
            } footer: {
                Text("The app icon theme shows in About, Settings and alerts. Finder keeps the original icon.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enabled in setLaunchAtLogin(enabled) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Text("Cascade \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") { store.resetToDefaults() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 560)
    }

    private var borderFooter: String {
        switch settings.borderStyle {
        case .natural: return "Each app's color is taken from its icon. Apps in use always get clearly different colors."
        case .vibrant: return "Icon colors at full strength with a soft glow, for maximum visibility."
        case .highContrast: return "Icon colors on a dark band, readable over light and dark backgrounds alike."
        case .custom: return "Every app's windows get the same color."
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct PercentSlider: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: CascadeSettings.percentRange, step: 1)
                Text("\(Int(value))%").monospacedDigit().frame(width: 44, alignment: .trailing)
            }
        }
    }
}

private struct PointSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...120

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range, step: 1)
                Text("\(Int(value)) pt").monospacedDigit().frame(width: 52, alignment: .trailing)
            }
        }
    }
}

/// The colors currently assigned to apps with windows on screen.
private struct BorderSwatches: View {
    let borders: BorderController
    @State private var colors: [(name: String, color: NSColor)] = []

    var body: some View {
        Group {
            if !colors.isEmpty {
                LabeledContent("In use") {
                    HStack(spacing: 10) {
                        ForEach(Array(colors.prefix(8).enumerated()), id: \.offset) { _, entry in
                            HStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: entry.color)).frame(width: 12, height: 12)
                                Text(entry.name).font(.caption).lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { colors = borders.currentColors }
        .onReceive(NotificationCenter.default.publisher(for: BorderController.colorsDidChange)) { _ in
            colors = borders.currentColors
        }
    }
}

/// Grid of menu bar icon designs, macOS symbols, and a custom image.
private struct MenuBarIconPicker: View {
    @Binding var selection: MenuBarIconStyle
    @Binding var customTemplate: Bool
    /// Bumped when a new custom image is chosen so tiles redraw.
    @State private var customRevision = 0

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Menu bar icon")
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(MenuBarIconStyle.allCases, id: \.self) { style in tile(style) }
            }
            .id(customRevision)
            if selection == .custom {
                HStack {
                    Button("Choose Image…") { CustomIconStore.choose() }
                    Spacer()
                    Toggle("Match menu bar color", isOn: $customTemplate)
                        .help("Turn off for full-color artwork. Turn on for single-color icons, which then adapt to light and dark menu bars.")
                }
            }
        }
        .padding(.vertical, 4)
        .onReceive(NotificationCenter.default.publisher(for: CustomIconStore.didChange)) { _ in customRevision += 1 }
    }

    private func tile(_ style: MenuBarIconStyle) -> some View {
        let selected = selection == style
        return Button {
            if style == .custom && CustomIconStore.load() == nil {
                if CustomIconStore.choose() { selection = .custom }
            } else {
                selection = style
            }
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05))
                    icon(style)
                }
                .frame(height: 36)
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 1))
                Text(MenuBarIcons.title(style))
                    .font(.caption2)
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(MenuBarIcons.title(style)) menu bar icon")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private func icon(_ style: MenuBarIconStyle) -> some View {
        if style == .custom && CustomIconStore.load() == nil {
            Image(systemName: "plus").foregroundStyle(.secondary)
        } else {
            let image = MenuBarIcons.image(style, customTemplate: customTemplate)
            Image(nsImage: image)
                .renderingMode(image.isTemplate ? .template : .original)
                .foregroundStyle(.primary)
        }
    }
}

/// Row of app icon color themes.
private struct AppIconPicker: View {
    @Binding var selection: AppIconStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("App icon")
            HStack(spacing: 0) {
                ForEach(AppIconStyle.allCases, id: \.self) { style in
                    let selected = selection == style
                    Button { selection = style } label: {
                        VStack(spacing: 4) {
                            Image(nsImage: AppIconRenderer.image(style, size: 128))
                                .resizable()
                                .frame(width: 52, height: 52)
                                .padding(3)
                                .overlay(RoundedRectangle(cornerRadius: 14)
                                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
                            Text(AppIconRenderer.title(style))
                                .font(.caption2)
                                .foregroundStyle(selected ? .primary : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(AppIconRenderer.title(style)) app icon")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Manual mode: pin running apps (and apps with existing rules) to groups.
private struct AppGroupRules: View {
    @Binding var rules: [String: Int]
    let groupCount: Int

    private struct AppRow: Identifiable {
        let id: String
        let name: String
        let icon: NSImage?
    }

    private var apps: [AppRow] {
        var rows: [String: AppRow] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { continue }
            rows[id] = AppRow(id: id, name: app.localizedName ?? id, icon: app.icon)
        }
        for id in rules.keys where rows[id] == nil {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            rows[id] = AppRow(id: id, name: url.map { FileManager.default.displayName(atPath: $0.path) } ?? id,
                              icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) })
        }
        return rows.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Text("Pin apps to groups. Unpinned apps are balanced across the remaining space.")
            .font(.caption).foregroundStyle(.secondary)
        ForEach(apps) { app in
            Picker(selection: Binding(
                get: { rules[app.id] ?? -1 },
                set: { rules[app.id] = $0 < 0 ? nil : $0 }
            )) {
                Text("Automatic").tag(-1)
                ForEach(0..<max(groupCount, (rules[app.id] ?? 0) + 1), id: \.self) { Text("Group \($0 + 1)").tag($0) }
            } label: {
                HStack {
                    if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                    Text(app.name)
                }
            }
        }
    }
}

/// Miniature of the main display showing groups and sample cascades with the current settings.
private struct LayoutPreview: View {
    let settings: CascadeSettings

    private static let apps = [("Safari", 3), ("Xcode", 2), ("Mail", 2), ("Notes", 1), ("Terminal", 2), ("Music", 1)]
    private static let samples: [PlanWindow] = {
        var result: [PlanWindow] = []
        var z = 0
        for (app, count) in Self.apps {
            for _ in 0..<count {
                result.append(PlanWindow(windowID: nil, appKey: app, bundleID: app, zRank: z))
                z += 1
            }
        }
        return result
    }()

    private static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal]

    var body: some View {
        Canvas { context, size in
            let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1512, height: 920)
            let area = CGRect(origin: .zero, size: screen)
            let scale = min(size.width / screen.width, size.height / screen.height)
            let offset = CGPoint(x: (size.width - screen.width * scale) / 2, y: (size.height - screen.height * scale) / 2)
            func map(_ r: CGRect) -> CGRect {
                CGRect(x: offset.x + r.minX * scale, y: offset.y + r.minY * scale,
                       width: r.width * scale, height: r.height * scale)
            }

            context.fill(Path(roundedRect: map(area), cornerRadius: 6), with: .color(.secondary.opacity(0.12)))
            let plan = Planner.plan(windows: Self.samples, area: area, settings: settings)
            for target in plan.dropTargets {
                context.stroke(Path(roundedRect: map(target.region), cornerRadius: 4),
                               with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            for group in plan.groups {
                for (index, frame) in zip(group.windows, group.frames) {
                    let r = map(frame)
                    let colorIndex = (Self.apps.firstIndex { $0.0 == Self.samples[index].appKey } ?? 0) % Self.palette.count
                    let color = Self.palette[colorIndex]
                    let shape = Path(roundedRect: r, cornerRadius: 3)
                    context.fill(shape, with: .color(Color(nsColor: .windowBackgroundColor)))
                    context.fill(Path(CGRect(x: r.minX, y: r.minY, width: r.width, height: min(r.height, 6))),
                                 with: .color(color.opacity(0.85)))
                    context.stroke(shape, with: .color(.primary.opacity(0.35)), lineWidth: 0.75)
                }
            }
        }
        .accessibilityLabel("Preview of the cascade layout")
    }
}

// MARK: - Shortcut recorder

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: Shortcut?

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.onChange = { shortcut = $0 }
        button.shortcut = shortcut
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.onChange = { shortcut = $0 }
        if !button.isRecording { button.shortcut = shortcut }
    }
}

extension Notification.Name {
    /// Posted with `object: Bool` when shortcut recording starts (true) or ends (false).
    static let shortcutRecording = Notification.Name("CascadeShortcutRecording")
}

final class RecorderButton: NSButton {
    var onChange: ((Shortcut?) -> Void)?
    var shortcut: Shortcut? { didSet { refresh() } }
    private(set) var isRecording = false { didSet { refresh() } }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggle)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    @objc private func toggle() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        window?.makeFirstResponder(self)
        NotificationCenter.default.post(name: .shortcutRecording, object: true)
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        NotificationCenter.default.post(name: .shortcutRecording, object: false)
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch Int(event.keyCode) {
        case 53 where flags.isEmpty:                 // Esc cancels
            stopRecording()
        case 51 where flags.isEmpty, 117 where flags.isEmpty:   // Delete clears
            shortcut = nil
            onChange?(nil)
            stopRecording()
        default:
            // Require a "real" modifier so plain typing can't be hijacked.
            guard !flags.intersection([.command, .option, .control]).isEmpty else { NSSound.beep(); return }
            let recorded = Shortcut(keyCode: UInt32(event.keyCode), modifiers: HotKeys.carbonModifiers(flags),
                                    key: HotKeys.keyLabel(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers))
            shortcut = recorded
            onChange?(recorded)
            stopRecording()
        }
    }

    private func refresh() {
        title = isRecording ? "Type shortcut…" : (shortcut?.displayString ?? "Click to record")
        toolTip = "Click, then press a shortcut. Esc cancels, Delete clears."
    }
}
