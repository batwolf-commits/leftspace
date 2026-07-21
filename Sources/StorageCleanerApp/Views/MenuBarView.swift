import SwiftUI
import Charts
import StorageCleanerKit

/// The popover shown from the menu bar extra: a compact disk-usage graph, a
/// reclaimable-by-category chart, and one-click actions — everything you need for
/// a quick pass without opening the full window.
struct MenuBarView: View {
    @Environment(ScanViewModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    /// Which safety levels the quick-clean will include, persisted as a bitmask so
    /// the choice is remembered between popover opens. Defaults to Safe only.
    @AppStorage("menuBarCleanLevels") private var selectionRaw: Int = 1 << SafetyLevel.safe.rawValue

    private var selection: Set<SafetyLevel> {
        Set(SafetyLevel.allCases.filter { selectionRaw & (1 << $0.rawValue) != 0 })
    }

    /// Reclaimable bytes per level, largest concern last, empty levels omitted.
    private var levelBytes: [(level: SafetyLevel, bytes: Int64)] {
        SafetyLevel.allCases
            .map { ($0, model.reclaimableBytes(for: $0)) }
            .filter { $0.1 > 0 }
    }
    private var totalReclaimable: Int64 { levelBytes.reduce(0) { $0 + $1.bytes } }
    private var selectedBytes: Int64 { model.reclaimableBytes(forLevels: selection) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            diskSection
            if totalReclaimable > 0 {
                Divider()
                reclaimSection
            }
            Divider()
            actions
        }
        .padding(14)
        .frame(width: 320)
        .task {
            model.refreshDiskSpace()
        }
    }

    // MARK: - Reclaimable breakdown (stacked bar + per-level tick boxes)

    private var reclaimSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Reclaimable")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(ByteFormat.string(totalReclaimable))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // The stacked bar. Clicking it opens the main window to inspect items.
            Button {
                presentMainWindow(openWindow)
            } label: {
                ReclaimBar(segments: levelBytes.map {
                    ($0.level, $0.bytes, selection.contains($0.level))
                })
            }
            .buttonStyle(.plain)
            .help("Click to open the app and see exactly what's inside")

            // One tick box per present level, with its size.
            VStack(spacing: 3) {
                ForEach(levelBytes, id: \.level) { item in
                    Toggle(isOn: binding(for: item.level)) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(SafetyPalette.color(item.level))
                                .frame(width: 8, height: 8)
                            Text(item.level.label)
                            Spacer()
                            Text(ByteFormat.string(item.bytes))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .font(.caption)
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
    }

    private func binding(for level: SafetyLevel) -> Binding<Bool> {
        Binding(
            get: { selectionRaw & (1 << level.rawValue) != 0 },
            set: { isOn in
                if isOn { selectionRaw |= (1 << level.rawValue) }
                else { selectionRaw &= ~(1 << level.rawValue) }
            }
        )
    }

    private var header: some View {
        HStack {
            AppIconColorView(size: 20)
            Text("LeftSpace")
                .font(.headline)
            Spacer()
            if model.isScanning {
                ProgressView().controlSize(.small)
            }
        }
    }

    // MARK: - Disk usage graph

    private var diskSection: some View {
        HStack(spacing: 14) {
            DiskDonut(space: model.diskSpace)
                .frame(width: 76, height: 76)
            VStack(alignment: .leading, spacing: 3) {
                Text(ByteFormat.string(model.diskSpace.freeBytes) + " free")
                    .font(.title3.weight(.semibold))
                Text("\(ByteFormat.string(model.diskSpace.usedBytes)) used of \(ByteFormat.string(model.diskSpace.totalBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(Int(model.diskSpace.usedFraction * 100))% full")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 10) {
            // Confirmation that a quick-clean just happened.
            if let freed = model.lastCleanedBytes, freed > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Label(model.lastCleanPermanent
                            ? "Deleted \(ByteFormat.string(freed))"
                            : "Moved \(ByteFormat.string(freed)) to Trash",
                          systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // Moving to Trash doesn't free the space until it's emptied.
                    if model.canEmptyMenuBarClean {
                        Text("This space isn't free until you empty it from the Trash.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            confirmAndEmptyMenuBarClean()
                        } label: {
                            Label("Empty \(ByteFormat.string(freed)) from Trash",
                                  systemImage: "trash.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Permanently remove only what was just cleaned, to free the space")
                    }
                }
            }

            if totalReclaimable > 0 {
                // Matched pair: Clean (primary) + Rescan, same size and shape.
                HStack(spacing: 8) {
                    Button {
                        confirmAndClean(levels: selection)
                    } label: {
                        Label("Clean \(ByteFormat.string(selectedBytes))",
                              systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedBytes == 0)
                    .help(permanentDeletePreference
                          ? "Permanently delete the ticked items (no Trash)"
                          : "Move the ticked items to the Trash (recoverable)")

                    Button {
                        Task { await model.startScan() }
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isScanning)
                }
                .controlSize(.large)
            } else {
                Button {
                    Task { await model.startScan() }
                } label: {
                    Label(model.isScanning ? "Scanning…" : "Scan now", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isScanning)
            }

            // Compact icon toolbar — labels live in tooltips, not on screen.
            HStack(spacing: 2) {
                ToolbarIcon(systemImage: "macwindow", help: "Open main window") {
                    presentMainWindow(openWindow)
                }
                SettingsLink {
                    Image(systemName: "gearshape")
                        .frame(width: 30, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Settings")
                .simultaneousGesture(TapGesture().onEnded {
                    NSApp.activate(ignoringOtherApps: true)
                })
                Spacer()
                ToolbarIcon(systemImage: "power", help: "Quit LeftSpace") {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}

extension MenuBarView {
    /// Show a confirmation window, then clean the selected levels only if the user
    /// agrees. Uses an `NSAlert` because a SwiftUI dialog can't present reliably
    /// from a menu bar popover — and the user wants a real confirmation message.
    func confirmAndClean(levels: Set<SafetyLevel>) {
        let bytes = model.reclaimableBytes(forLevels: levels)
        guard bytes > 0 else { return }
        let sizeText = ByteFormat.string(bytes)
        let permanent = permanentDeletePreference
        let names = SafetyLevel.allCases.filter { levels.contains($0) }.map { $0.label.lowercased() }
        let namesText = Self.listPhrase(names)

        let alert = NSAlert()
        alert.messageText = permanent
            ? "Permanently delete \(sizeText)?"
            : "Move \(sizeText) to the Trash?"

        var info = "This removes the \(namesText) items from your last scan."
        if !permanent {
            info += " They go to the Trash and can be recovered until you empty it."
        } else {
            info += " With permanent delete on they CANNOT be recovered."
        }
        if levels.contains(.risky) {
            info += " Risky items can have real impact (like device backups) — be sure you don't need them."
            alert.alertStyle = .critical
        } else if levels.contains(.caution) {
            info += " Review items may cost a re-index or a slower first launch."
            alert.alertStyle = .informational
        } else {
            alert.alertStyle = .informational
        }
        alert.informativeText = info
        alert.addButton(withTitle: permanent ? "Delete Permanently" : "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await model.cleanLevels(levels) }
        }
    }

    /// Confirm, then permanently empty just the items this widget moved to the
    /// Trash — never the whole Trash. This is what actually frees the space.
    func confirmAndEmptyMenuBarClean() {
        guard let freed = model.lastCleanedBytes else { return }
        let alert = NSAlert()
        alert.messageText = "Permanently delete \(ByteFormat.string(freed)) from the Trash?"
        alert.informativeText = """
        This empties only what LeftSpace just moved to the Trash — the rest of \
        your Trash is untouched. This CANNOT be undone.
        """
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Delete Permanently")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await model.emptyMenuBarClean() }
        }
    }

    /// "safe", "safe and review", or "safe, review and risky".
    static func listPhrase(_ items: [String]) -> String {
        switch items.count {
        case 0:  return ""
        case 1:  return items[0]
        case 2:  return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
        }
    }
}

/// Colors for the three safety levels, shared by the bar and its legend.
enum SafetyPalette {
    static func color(_ level: SafetyLevel) -> Color {
        switch level {
        case .safe:    return .green
        case .caution: return .orange
        case .risky:   return .red
        }
    }
}

/// A compact stacked bar of reclaimable space by safety level. Selected segments
/// are solid; unticked ones dim so you can see what the current clean would take.
struct ReclaimBar: View {
    let segments: [(level: SafetyLevel, bytes: Int64, selected: Bool)]

    private var total: Int64 { max(1, segments.reduce(0) { $0 + $1.bytes }) }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(segments, id: \.level) { seg in
                    SafetyPalette.color(seg.level)
                        .opacity(seg.selected ? 1 : 0.22)
                        .frame(width: max(3, geo.size.width * CGFloat(Double(seg.bytes) / Double(total))))
                }
            }
        }
        .frame(height: 16)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(RoundedRectangle(cornerRadius: 5))
    }
}

/// A borderless icon button for the menu bar's compact toolbar row.
private struct ToolbarIcon: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

/// A donut showing used vs free capacity.
struct DiskDonut: View {
    let space: DiskSpace

    var body: some View {
        Chart {
            SectorMark(
                angle: .value("Used", space.usedBytes),
                innerRadius: .ratio(0.62),
                angularInset: 1
            )
            .foregroundStyle(usedColor)
            SectorMark(
                angle: .value("Free", space.freeBytes),
                innerRadius: .ratio(0.62),
                angularInset: 1
            )
            .foregroundStyle(Color.gray.opacity(0.25))
        }
        .chartLegend(.hidden)
        .overlay {
            Text("\(Int(space.usedFraction * 100))%")
                .font(.caption.weight(.bold).monospacedDigit())
        }
    }

    // Warn as the disk fills up.
    private var usedColor: Color {
        switch space.usedFraction {
        case ..<0.75: return .green
        case ..<0.9:  return .orange
        default:      return .red
        }
    }
}
