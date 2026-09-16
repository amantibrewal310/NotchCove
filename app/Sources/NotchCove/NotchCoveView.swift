import SwiftUI
import AppKit
import Observation
import UniformTypeIdentifiers

@Observable
@MainActor
public final class ShelfUIState {
    public var isTargetedForDrop: Bool = false
    public var hoveredItemId: String? = nil

    public init() {}
}

@MainActor
public struct NotchCoveView: View {
    @ObservedObject var engine = CoveEngine.shared
    @Binding var isExpanded: Bool
    var uiState: ShelfUIState

    let metrics: NotchMetrics

    public init(metrics: NotchMetrics, isExpanded: Binding<Bool>, uiState: ShelfUIState) {
        self.metrics = metrics
        self._isExpanded = isExpanded
        self.uiState = uiState
    }

    public init(metrics: NotchMetrics, isExpanded: Binding<Bool>) {
        self.metrics = metrics
        self._isExpanded = isExpanded
        self.uiState = ShelfUIState()
    }

    public var body: some View {
        VStack(spacing: 0) {
            if isExpanded {
                expandedShelfView
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)),
                        removal: .opacity
                    ))
            } else {
                idlePillView
            }
        }
        .frame(
            width: isExpanded ? max(460, CGFloat(engine.items.count * 90 + 160)) : metrics.width,
            height: isExpanded ? 145 : metrics.height
        )
        .background(
            ZStack {
                // Frosted background
                RoundedRectangle(cornerRadius: isExpanded ? 20 : (metrics.hasPhysicalNotch ? 8 : 16), style: .continuous)
                    .fill(.ultraThinMaterial)

                // Deep dark overlay for notch seamless blending
                RoundedRectangle(cornerRadius: isExpanded ? 20 : (metrics.hasPhysicalNotch ? 8 : 16), style: .continuous)
                    .fill(Color.black.opacity(uiState.isTargetedForDrop ? 0.70 : 0.85))

                // Subtle border glow when dragging over
                RoundedRectangle(cornerRadius: isExpanded ? 20 : (metrics.hasPhysicalNotch ? 8 : 16), style: .continuous)
                    .strokeBorder(
                        uiState.isTargetedForDrop
                            ? Color.accentColor.opacity(0.9)
                            : Color.white.opacity(0.15),
                        lineWidth: uiState.isTargetedForDrop ? 1.5 : 0.6
                    )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: isExpanded ? 20 : (metrics.hasPhysicalNotch ? 8 : 16), style: .continuous))
        .shadow(color: Color.black.opacity(isExpanded ? 0.40 : 0.15), radius: isExpanded ? 18 : 6, x: 0, y: isExpanded ? 8 : 2)
        .onDrop(
            of: [UTType.fileURL.identifier, UTType.item.identifier],
            isTargeted: Binding(
                get: { uiState.isTargetedForDrop },
                set: { uiState.isTargetedForDrop = $0 }
            )
        ) { providers in
            handleIncomingDrop(providers: providers)
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.75), value: isExpanded)
        .animation(.easeInOut(duration: 0.2), value: uiState.isTargetedForDrop)
    }

    // MARK: - Idle State
    private var idlePillView: some View {
        Button(action: {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.75)) {
                isExpanded.toggle()
            }
        }) {
            HStack(spacing: 6) {
                if engine.items.isEmpty {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                    Text("Cove")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                } else {
                    Image(systemName: "tray.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.accentColor)
                    Text("\(engine.items.count) \(engine.items.count == 1 ? "file" : "files")")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Expanded Shelf View
    private var expandedShelfView: some View {
        VStack(spacing: 10) {
            // Header Bar
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "tray.2.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.accentColor)
                    Text("NotchCove")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                    if !engine.items.isEmpty {
                        Text("(\(engine.items.count))")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundColor(.white.opacity(0.6))
                    }
                }

                Spacer()

                if !engine.items.isEmpty {
                    Button(action: {
                        engine.clearAll()
                        withAnimation {
                            isExpanded = false
                        }
                    }) {
                        Text("Clear All")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 6)
                }

                Button(action: {
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.75)) {
                        isExpanded = false
                    }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // Content Area: Empty State or File Shelf
            if engine.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.white.opacity(0.4))
                    Text("Drop files or folders here to stash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 12)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(engine.items) { item in
                            StagedFileCard(
                                item: item,
                                isHovered: uiState.hoveredItemId == item.id,
                                onRemove: {
                                    engine.remove(id: item.id)
                                    if engine.items.isEmpty {
                                        withAnimation {
                                            isExpanded = false
                                        }
                                    }
                                }
                            )
                            .onHover { hovering in
                                uiState.hoveredItemId = hovering ? item.id : nil
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                }
            }
        }
    }

    // MARK: - Drop Handling
    private func handleIncomingDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        DispatchQueue.main.async {
                            engine.stage(url: url)
                            withAnimation(.spring(response: 0.36, dampingFraction: 0.75)) {
                                isExpanded = true
                            }
                        }
                    } else if let url = item as? URL {
                        DispatchQueue.main.async {
                            engine.stage(url: url)
                            withAnimation(.spring(response: 0.36, dampingFraction: 0.75)) {
                                isExpanded = true
                            }
                        }
                    }
                }
                handled = true
            }
        }

        if handled {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        return handled
    }
}

// MARK: - Staged File Card Component
struct StagedFileCard: View {
    let item: StagedItem
    let isHovered: Bool
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                // File Icon with Native AppKit Icon
                FileIconView(path: item.originalPath)
                    .frame(width: 44, height: 44)
                    .padding(6)
                    .background(Color.white.opacity(isHovered ? 0.14 : 0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                // Remove Button on hover
                if isHovered {
                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white)
                            .padding(3)
                            .background(Color.red.opacity(0.85))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: 4, y: -4)
                }
            }

            // Filename
            Text(item.filename)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
                .frame(width: 68)

            // File Size
            Text(item.formattedSize)
                .font(.system(size: 8))
                .foregroundColor(.white.opacity(0.5))
        }
        // Support Dragging Out from Cove to Finder/Slack/Mail!
        .onDrag {
            NSItemProvider(contentsOf: URL(fileURLWithPath: item.originalPath)) ?? NSItemProvider()
        }
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(item.originalPath, inFileViewerRootedAtPath: "")
            }
            Button("Open File") {
                NSWorkspace.shared.open(URL(fileURLWithPath: item.originalPath))
            }
            Button("Copy File Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.originalPath, forType: .string)
            }
            Divider()
            Button("Remove from Cove", role: .destructive) {
                onRemove()
            }
        }
    }
}

// MARK: - Native File Icon View
struct FileIconView: NSViewRepresentable {
    let path: String

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        let icon = NSWorkspace.shared.icon(forFile: path)
        imageView.image = icon
        return imageView
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        nsView.image = NSWorkspace.shared.icon(forFile: path)
    }
}
