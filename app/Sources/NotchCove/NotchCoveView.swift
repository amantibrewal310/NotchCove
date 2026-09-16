import SwiftUI
import AppKit

@MainActor
public struct NotchCoveView: View {
    @ObservedObject var engine = CoveEngine.shared
    let metrics: NotchMetrics
    let isExpanded: Bool

    public init(metrics: NotchMetrics, isExpanded: Bool) {
        self.metrics = metrics
        self.isExpanded = isExpanded
    }

    private var cornerRadius: CGFloat {
        isExpanded ? 20 : (metrics.hasPhysicalNotch ? 8 : 17)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top inset: push content below menu bar on non-notch screens
            if metrics.topInset > 0 {
                Spacer().frame(height: isExpanded ? max(metrics.topInset - 10, 0) : metrics.topInset)
            }

            // The Pill / Shelf Card
            ZStack {
                if isExpanded {
                    expandedShelfView
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
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.black.opacity(0.85))
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.6)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: Color.black.opacity(isExpanded ? 0.40 : 0.15),
                    radius: isExpanded ? 18 : 6, x: 0, y: isExpanded ? 8 : 2)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: isExpanded)
    }

    // MARK: - Idle Pill
    private var idlePillView: some View {
        HStack(spacing: 6) {
            if engine.items.isEmpty {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                Text("Cove")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.95))
            } else {
                Image(systemName: "tray.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.accentColor)
                Text("\(engine.items.count) \(engine.items.count == 1 ? "file" : "files")")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    // MARK: - Expanded Shelf
    private var expandedShelfView: some View {
        VStack(spacing: 10) {
            // Header
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
                        NotchWindowManager.shared.collapse()
                    }) {
                        Text("Clear All")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 6)
                }

                Button(action: {
                    NotchWindowManager.shared.collapse()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // Content
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
                            StagedFileCard(item: item, onRemove: {
                                engine.remove(id: item.id)
                                if engine.items.isEmpty {
                                    NotchWindowManager.shared.collapse()
                                }
                            })
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                }
            }
        }
    }
}

// MARK: - File Card
struct StagedFileCard: View {
    let item: StagedItem
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            FileIconView(path: item.originalPath, onDragEnd: onRemove)
                .frame(width: 44, height: 44)
                .padding(6)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(item.filename)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
                .frame(width: 68)

            Text(item.formattedSize)
                .font(.system(size: 8))
                .foregroundColor(.white.opacity(0.5))
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
            Button("Remove from Cove", role: .destructive) { onRemove() }
        }
    }
}

// MARK: - Native File Icon View
struct FileIconView: NSViewRepresentable {
    let path: String
    let onDragEnd: () -> Void

    class DraggableImageView: NSImageView, NSDraggingSource {
        var fileURL: URL?
        var onDragEnd: (() -> Void)?
        private var isDragging = false
        private var mouseDownEvent: NSEvent?

        override func mouseDown(with event: NSEvent) {
            mouseDownEvent = event
            isDragging = false
            super.mouseDown(with: event)
        }
        
        override func mouseDragged(with event: NSEvent) {
            guard !isDragging, let url = fileURL, let downEvent = mouseDownEvent else {
                super.mouseDragged(with: event)
                return
            }
            
            // Start drag
            isDragging = true
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let draggingFrame = NSRect(x: 0, y: 0, width: self.bounds.width, height: self.bounds.height)
            item.setDraggingFrame(draggingFrame, contents: self.image)
            
            self.beginDraggingSession(with: [item], event: downEvent, source: self)
        }
        
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            return [.copy, .move, .link, .generic]
        }
        
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            isDragging = false
            if operation != [] {
                DispatchQueue.main.async {
                    self.onDragEnd?()
                }
            }
        }
    }

    func makeNSView(context: Context) -> DraggableImageView {
        let iv = DraggableImageView()
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.fileURL = URL(fileURLWithPath: path)
        iv.onDragEnd = onDragEnd
        iv.image = NSWorkspace.shared.icon(forFile: path)
        return iv
    }

    func updateNSView(_ nsView: DraggableImageView, context: Context) {
        nsView.fileURL = URL(fileURLWithPath: path)
        nsView.onDragEnd = onDragEnd
        nsView.image = NSWorkspace.shared.icon(forFile: path)
    }
}
