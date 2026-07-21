import SwiftUI
import StorageCleanerKit

/// The main results screen: total reclaimable at the top, a priority filter, a
/// grouped/checkable list of categories (each expandable to its individual files),
/// and the Clean action bar at the bottom.
struct ResultsView: View {
    @Environment(ScanViewModel.self) private var model
    @State private var confirming = false
    @State private var confirmingPermanent = false
    // The single persistent Trash/permanent preference — shared with the menu bar
    // and Settings. @AppStorage so the toggle and labels update live.
    @AppStorage(PrefKey.permanentDelete) private var permanentDelete = false
    private var trashMode: Bool { !permanentDelete }

    var body: some View {
        VStack(spacing: 0) {
            header
            FilterBar()
            Divider()
            selectAllBar
            Divider()
            list
            Divider()
            actionBar
        }
        .confirmationDialog(confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
            Button(trashMode ? "Move to Trash" : "Delete Permanently",
                   role: .destructive) {
                Task { await model.clean() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text(ByteFormat.string(model.totalReclaimable))
                .font(.system(size: 40, weight: .bold, design: .rounded))
            Text("reclaimable across \(model.categoryCount(for: nil)) locations")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    private var selectAllBar: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { model.allVisibleSelected },
                set: { model.setAllVisibleSelected($0) }
            )) {
                Text(model.allVisibleSelected ? "Deselect all" : "Select all")
                    .font(.callout)
            }
            .toggleStyle(.checkbox)

            Spacer()

            Text("\(model.visibleItems.count) items")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(model.groups, id: \.group) { entry in
                    GroupSection(group: entry.group, categories: entry.categories)
                }
                if model.groups.isEmpty {
                    Text("Nothing at this priority level.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
            .padding(20)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.selectedItems.count) items selected")
                    .font(.subheadline.weight(.medium))
                Text(ByteFormat.string(model.selectedBytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(isOn: Binding(
                get: { !permanentDelete },
                set: { wantsTrash in
                    // Turning Trash OFF enables permanent delete — confirm first,
                    // matching the Settings toggle. Turning it back ON is safe.
                    if wantsTrash { permanentDelete = false }
                    else { confirmingPermanent = true }
                }
            )) {
                Text("Move to Trash (recoverable)")
                    .font(.callout)
            }
            .toggleStyle(.checkbox)
            .alert("Delete permanently instead of using the Trash?",
                   isPresented: $confirmingPermanent) {
                Button("Turn On Permanent Delete", role: .destructive) { permanentDelete = true }
                Button("Cancel", role: .cancel) { permanentDelete = false }
            } message: {
                Text("Everything LeftSpace removes will be erased immediately and cannot be recovered, here and from the menu bar. You can switch it back off at any time.")
            }

            Button {
                confirming = true
            } label: {
                Label("Clean", systemImage: "trash")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.selectedItems.isEmpty)
        }
        .padding(16)
        .background(.regularMaterial)
    }

    private var confirmTitle: String {
        trashMode ? "Move \(model.selectedItems.count) items to Trash?"
                  : "Permanently delete \(model.selectedItems.count) items?"
    }
    private var confirmMessage: String {
        let size = ByteFormat.string(model.selectedBytes)
        return trashMode
            ? "This frees about \(size). Everything goes to the Trash and can be recovered."
            : "This frees about \(size) and CANNOT be undone."
    }
}

/// Priority (safety-level) filter as a segmented control with counts.
struct FilterBar: View {
    @Environment(ScanViewModel.self) private var model

    private var options: [(label: String, level: SafetyLevel?)] {
        [("All", nil), (SafetyLevel.safe.label, .safe),
         (SafetyLevel.caution.label, .caution), (SafetyLevel.risky.label, .risky)]
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("Priority")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(options, id: \.label) { opt in
                let count = model.categoryCount(for: opt.level)
                Button {
                    model.safetyFilter = opt.level
                } label: {
                    HStack(spacing: 5) {
                        Text(opt.label)
                        Text("\(count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        model.safetyFilter == opt.level ? AnyShapeStyle(.tint.opacity(0.18))
                                                        : AnyShapeStyle(.clear),
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
                .disabled(opt.level != nil && count == 0)
                .opacity(opt.level != nil && count == 0 ? 0.4 : 1)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }
}

/// One high-level group (e.g. "Developer caches") with its categories.
struct GroupSection: View {
    @Environment(ScanViewModel.self) private var model
    let group: CategoryGroup
    let categories: [CategoryResult]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(group.title)
                    .font(.headline)
                Spacer()
                Text(ByteFormat.string(categories.reduce(0) { $0 + $1.totalBytes }))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(categories) { cat in
                    CategoryRow(cat: cat)
                    if cat.id != categories.last?.id { Divider() }
                }
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// A category row that expands to reveal its individual files.
struct CategoryRow: View {
    @Environment(ScanViewModel.self) private var model
    let cat: CategoryResult
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Toggle("", isOn: Binding(
                    get: { model.isCategoryFullySelected(cat) },
                    set: { model.toggleCategory(cat, on: $0) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(cat.category.title)
                            .font(.body.weight(.medium))
                        SafetyBadge(level: cat.category.safety)
                    }
                    Text(cat.category.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Text(ByteFormat.string(cat.totalBytes))
                    .font(.body.monospacedDigit().weight(.semibold))

                // Disclosure chevron — reveals the per-item detail.
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .font(.caption.weight(.semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Hide files" : "Show files")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if expanded {
                ItemDetailList(cat: cat)
            }
        }
        .contentShape(Rectangle())
    }
}

/// The expanded list of individual files inside a category.
struct ItemDetailList: View {
    @Environment(ScanViewModel.self) private var model
    let cat: CategoryResult

    /// Cap how many rows we show so a huge cache folder doesn't produce thousands.
    private let visibleLimit = 100

    var body: some View {
        VStack(spacing: 0) {
            Divider().padding(.leading, 40)
            ForEach(cat.items.prefix(visibleLimit)) { item in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(
                        get: { model.isSelected(item) },
                        set: { _ in model.toggle(item) }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()

                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.url.lastPathComponent)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        // Prefer the human context (e.g. "npm packages in bookease
                        // · last changed 5 months ago") when the item provides it.
                        Text(item.detail ?? item.url.abbreviatedPath)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text(ByteFormat.string(item.sizeBytes))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([item.url])
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Reveal in Finder")
                }
                .padding(.leading, 40)
                .padding(.trailing, 14)
                .padding(.vertical, 5)
                Divider().padding(.leading, 40)
            }
            if cat.items.count > visibleLimit {
                Text("+ \(cat.items.count - visibleLimit) more…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 40)
                    .padding(.vertical, 6)
            }
        }
        .padding(.bottom, 4)
    }
}

struct SafetyBadge: View {
    let level: SafetyLevel
    var body: some View {
        Text(level.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
    private var color: Color {
        switch level {
        case .safe:    return .green
        case .caution: return .orange
        case .risky:   return .red
        }
    }
}

extension URL {
    /// Path with the user's home directory collapsed to `~`, for compact display.
    var abbreviatedPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
