import SwiftUI
import StorageCleanerKit

/// Top-level router that swaps between the phases of the flow.
struct RootView: View {
    @Environment(ScanViewModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            switch model.phase {
            case .idle:
                IdleView()
            case .scanning(let done, let total, let current):
                ScanProgressView(done: done, total: total, current: current)
            case .results:
                ResultsView()
            case .cleaning:
                CleaningView()
            case .finished(let freed, let failures):
                FinishedView(freed: freed, failures: failures)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .onAppear { model.refreshPermissions() }
        .onDisappear {
            // Closing the window fully removes the Dock icon. If the menu bar
            // widget is available, the app keeps running there (no Dock presence)
            // and reopens the window on demand; otherwise there is nothing left to
            // reach it from, so the app quits.
            if showMenuBarIconPreference {
                NSApp.setActivationPolicy(.accessory)
            } else {
                NSApp.terminate(nil)
            }
        }
    }
}

/// The starting screen: a Full Disk Access nudge (if needed) and a Scan button.
struct IdleView: View {
    @Environment(ScanViewModel.self) private var model

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            AppIconColorView(size: 84)
            Text("LeftSpace")
                .font(.largeTitle.weight(.semibold))
            Text("Find and safely remove caches, logs, and developer junk\nthat Finder never shows you.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if !model.fullDiskAccessGranted {
                FullDiskAccessCard()
                    .padding(.top, 4)
            }

            Button {
                Task { await model.startScan() }
            } label: {
                Label("Scan my Mac", systemImage: "magnifyingglass")
                    .font(.headline)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 8)

            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .controlSize(.large)
            .simultaneousGesture(TapGesture().onEnded {
                NSApp.activate(ignoringOtherApps: true)
            })
            Spacer()
        }
        .padding(40)
    }
}

/// Explains and deep-links to the Full Disk Access settings pane.
struct FullDiskAccessCard: View {
    @Environment(ScanViewModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Grant Full Disk Access for a complete scan")
                    .font(.subheadline.weight(.semibold))
                Text("Without it, caches belonging to other apps stay hidden. You can still scan your own caches now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button("Open Settings…") {
                        if let url = URL(string: FullDiskAccess.settingsURLString) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Button("Re-check") { model.refreshPermissions() }
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: 460)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.orange.opacity(0.25)))
    }
}

struct ScanProgressView: View {
    let done: Int
    let total: Int
    let current: String

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .progressViewStyle(.linear)
                .frame(width: 320)
            Text(current.isEmpty ? "Scanning…" : "Scanning \(current)…")
                .foregroundStyle(.secondary)
            Text("\(done) of \(total) locations")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(40)
    }
}

struct CleaningView: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Cleaning up…")
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

struct FinishedView: View {
    @Environment(ScanViewModel.self) private var model
    let freed: Int64
    let failures: Int
    @State private var undoing = false
    @State private var confirmingEmpty = false

    /// Trash mode leaves the space occupied until the Trash is emptied.
    private var spaceStillInTrash: Bool {
        model.lastCleanWasTrash && !model.didEmptyTrashed && model.canEmptyTrashed
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("Freed \(ByteFormat.string(freed))")
                .font(.largeTitle.weight(.semibold))

            if model.didEmptyTrashed {
                Text("Items were permanently removed from the Trash — the space is fully reclaimed.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if model.lastCleanWasTrash {
                Text("Items were moved to the Trash and can be recovered.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Items were permanently removed.")
                    .foregroundStyle(.secondary)
            }
            if failures > 0 {
                Text("\(failures) item(s) could not be removed and were left untouched.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let before = model.diskBeforeClean {
                BeforeAfterGauge(before: before, after: model.diskSpace)
                    .padding(.top, 6)
            }

            if spaceStillInTrash {
                Label("This space isn't fully free until you empty it from the Trash.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                if model.canUndoLastClean {
                    Button {
                        undoing = true
                        Task { await model.undoLastClean(); undoing = false }
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .controlSize(.large)
                    .disabled(undoing)
                }
                if model.canEmptyTrashed {
                    Button {
                        confirmingEmpty = true
                    } label: {
                        Label("Delete from Trash", systemImage: "trash.fill")
                    }
                    .controlSize(.large)
                    .disabled(undoing)
                }
                Button("Scan again") { model.reset() }
                    .controlSize(.large)
            }
            .padding(.top, 8)
            Spacer()
        }
        .padding(40)
        .confirmationDialog("Permanently delete these items from the Trash?",
                            isPresented: $confirmingEmpty, titleVisibility: .visible) {
            Button("Delete Permanently", role: .destructive) {
                Task { await model.emptyTrashedFromLastClean() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This empties only the \(ByteFormat.string(freed)) LeftSpace just moved to the Trash — the rest of your Trash is untouched. This CANNOT be undone.")
        }
    }
}

/// A compact before/after view of free disk space after a clean.
struct BeforeAfterGauge: View {
    let before: DiskSpace
    let after: DiskSpace

    private var gained: Int64 { max(0, after.freeBytes - before.freeBytes) }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 20) {
                column("Free before", before.freeBytes)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)
                column("Free now", after.freeBytes, highlight: true)
            }
            if gained > 0 {
                Text("+\(ByteFormat.string(gained)) available")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            }
        }
        .padding(14)
        .frame(maxWidth: 380)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private func column(_ label: String, _ bytes: Int64, highlight: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(ByteFormat.string(bytes))
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(highlight ? AnyShapeStyle(.green) : AnyShapeStyle(.primary))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
