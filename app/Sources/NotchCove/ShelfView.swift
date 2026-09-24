import AppKit
import SwiftUI

// MARK: - Notch shape

/// Black notch silhouette: flush with the top edge, with small outward "ears"
/// at the top corners and rounded bottom corners, like the hardware notch.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = topRadius, b = min(bottomRadius, rect.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Root

public struct NotchRootView: View {
    @ObservedObject private var manager = NotchWindowManager.shared
    @ObservedObject private var engine = CoveEngine.shared

    public init() {}

    private var metrics: NotchMetrics { manager.metrics }
    private var expanded: Bool { manager.isExpanded }
    private var earRadius: CGFloat { expanded ? 14 : 6 }

    private var size: CGSize {
        expanded
            ? CGSize(width: metrics.shelfWidth, height: metrics.shelfHeight)
            : CGSize(width: metrics.collapsedWidth(itemCount: manager.collapsedCount), height: metrics.notchHeight)
    }

    public var body: some View {
        ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                if expanded {
                    ShelfContent()
                        .padding(.horizontal, earRadius)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                } else {
                    CollapsedContent(count: manager.collapsedCount, splitAroundNotch: metrics.hasPhysicalNotch, theme: manager.theme)
                        .padding(.horizontal, earRadius)
                        .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipShape(NotchShape(topRadius: earRadius, bottomRadius: expanded ? 24 : 10))
            // The shadow sits on a plain background shape, not on the content,
            // so scrolling doesn't force it to be recomputed every frame.
            .background(
                NotchShape(topRadius: earRadius, bottomRadius: expanded ? 24 : 10)
                    .fill(Color.black)
                    .shadow(color: .black.opacity(expanded ? 0.45 : 0), radius: 14, y: 6)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Collapsed

private struct CollapsedContent: View {
    let count: Int
    /// Physical notch: icon left of the camera, count right of it. Virtual: centred together.
    let splitAroundNotch: Bool
    let theme: ShelfTheme

    var body: some View {
        if count > 0 {
            HStack(spacing: 6) {
                if !splitAroundNotch { Spacer(minLength: 0) }
                Image(nsImage: Brand.glyph)
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 14, height: 14)
                    .foregroundStyle(.white.opacity(0.9))
                Spacer(minLength: 0).frame(maxWidth: splitAroundNotch ? .infinity : 0)
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(theme.onAccent)
                    .contentTransition(.numericText())
                    .padding(.horizontal, 4.5)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Capsule().fill(theme.accent))
                if !splitAroundNotch { Spacer(minLength: 0) }
            }
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Expanded shelf

private struct ShelfContent: View {
    @ObservedObject private var manager = NotchWindowManager.shared
    @ObservedObject private var engine = CoveEngine.shared

    var body: some View {
        let cards = manager.displayedCards
        VStack(spacing: 0) {
            ShelfHeader(cards: cards)
                .frame(height: manager.metrics.headerHeight)

            ZStack {
                if cards.isEmpty {
                    EmptyShelf()
                        .opacity(manager.isReceivingDrag ? 0 : 1)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 8) {
                                ForEach(cards) { card in
                                    CardView(
                                        card: card,
                                        scale: manager.metrics.scale,
                                        isSelected: manager.selection.contains(card.id),
                                        theme: manager.theme,
                                        hover: manager.hoverState(for: card.id),
                                        poof: manager.poofs[card.id]
                                    )
                                    .id(card.id)
                                    .transition(.asymmetric(
                                        insertion: .scale(scale: 0.6).combined(with: .opacity),
                                        removal: .opacity
                                    ))
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.top, 6)
                            .animation(NotchWindowManager.openAnimation, value: engine.revision)
                        }
                        .onChange(of: manager.dropPulse) {
                            if let first = cards.first { withAnimation { proxy.scrollTo(first.id, anchor: .leading) } }
                        }
                    }
                    .opacity(manager.isReceivingDrag ? 0.2 : 1)
                    .blur(radius: manager.isReceivingDrag ? 2 : 0)
                }

                if manager.isReceivingDrag {
                    DropZone(targeted: manager.isDropTargeted, theme: manager.theme)
                        .padding(.horizontal, 10)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 12)
        }
    }
}

/// Removal "poof", like Dropzone's: a small cloud of soft puffs bursts over
/// the card and dissolves while the card fades. Only exists for the ~0.4 s
/// the card takes to go, so nothing runs afterwards.
private struct PoofCloud: View {
    let burst: Bool
    private static let puffs = 7

    var body: some View {
        ZStack {
            puff(size: burst ? 30 : 16, opacity: 0.9)
            ForEach(0..<Self.puffs, id: \.self) { index in
                let angle = Double(index) / Double(Self.puffs) * 2 * .pi + 0.35
                let distance: CGFloat = burst ? 24 : 6
                puff(size: burst ? 22 : 14, opacity: 0.85)
                    .offset(x: cos(angle) * distance, y: sin(angle) * distance * 0.8)
            }
        }
        .opacity(burst ? 0 : 1)
        .allowsHitTesting(false)
    }

    private func puff(size: CGFloat, opacity: Double) -> some View {
        Circle()
            .fill(RadialGradient(
                colors: [.white.opacity(opacity), .white.opacity(opacity * 0.5), .white.opacity(0)],
                center: .center, startRadius: 0, endRadius: size / 2
            ))
            .frame(width: size, height: size)
    }
}

private struct ShelfHeader: View {
    @ObservedObject private var manager = NotchWindowManager.shared
    @ObservedObject private var engine = CoveEngine.shared
    let cards: [ShelfStack]

    var body: some View {
        let theme = manager.theme
        HStack(spacing: 10) {
            if manager.openStackId != nil {
                Button { manager.closeStack() } label: {
                    Label("\(cards.count) Items", systemImage: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(HeaderButtonStyle())
                .accessibilityLabel("Back to shelf (Esc)")
            } else {
                Image(nsImage: Brand.glyph)
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(theme.accent)
                    // Pop when something lands (SF Symbol bounce doesn't apply to a custom mark).
                    .id(manager.dropPulse)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                Text(theme.headerTitle)
                    .font(theme.headerTitleFont)
                    .tracking(theme.headerTitleTracking)
                    .foregroundStyle(theme.textPrimary)
                if !engine.items.isEmpty {
                    Text("\(engine.items.count)")
                        .font(.system(size: 12, weight: theme.headerCountColor == theme.accent ? .bold : .medium, design: .rounded))
                        .foregroundStyle(theme.headerCountColor)
                        .contentTransition(.numericText())
                }
            }

            // Keep the centre clear: that's where the camera housing is.
            Spacer(minLength: manager.metrics.hasPhysicalNotch ? manager.metrics.notchWidth + 16 : 16)

            if !cards.isEmpty {
                DragAllHandle()
                    .frame(width: 22, height: 22)
                    .overlay(
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.75))
                            .allowsHitTesting(false)
                    )
                    .accessibilityLabel("Drag everything out at once")

                Button {
                    manager.poofThenRemove(engine.items, clearAll: true)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(HeaderButtonStyle())
                .accessibilityLabel("Clear shelf")
            }

            Button {
                manager.isSticky ? manager.collapse() : manager.expand(.click)
            } label: {
                Image(systemName: manager.isSticky ? "pin.fill" : "pin")
            }
            .buttonStyle(HeaderButtonStyle())
            .accessibilityLabel(manager.isSticky ? "Unpin and close" : "Keep open")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.top, 2)
    }
}

private struct HeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.5 : 0.75))
            .frame(minWidth: 22, minHeight: 22)
            .contentShape(Rectangle())
    }
}

private struct EmptyShelf: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.white.opacity(0.45))
            Text("Drag files, images, links or text here")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            Text("Drag them out again whenever you need them")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
        }
    }
}

private struct DropZone: View {
    let targeted: Bool
    let theme: ShelfTheme

    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(theme.dropFill)
            .opacity(targeted ? 1 : 0.6)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        targeted ? theme.dropStroke : Color.white.opacity(0.3),
                        style: StrokeStyle(lineWidth: theme.dropLineWidth, dash: theme.dropDashed ? [7, 5] : [])
                    )
            )
            .overlay(
                VStack(spacing: 6) {
                    Image(systemName: targeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(targeted ? theme.accent : theme.textSecondary)
                        .scaleEffect(targeted ? 1.15 : 1)
                    Text(targeted ? "Release to stash" : "Drop here to stash")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(targeted ? theme.textPrimary : theme.textSecondary)
            )
            .scaleEffect(targeted ? 1.0 : 0.98)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: targeted)
    }
}

// MARK: - Cards

private struct CardView: View {
    let card: ShelfStack
    let scale: CGFloat
    let isSelected: Bool
    let theme: ShelfTheme
    @ObservedObject var hover: NotchWindowManager.HoverState
    /// Set while the card is being removed: false, then true once the poof bursts.
    var poof: Bool? = nil

    private var isHovered: Bool { hover.isHovered && poof == nil }

    var body: some View {
        VStack(spacing: 4) {
            CardThumbnail(card: card, scale: scale, theme: theme)
                .frame(width: 58 * scale, height: 54 * scale)

            Text(card.title)
                .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? theme.selectedTitle : theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 80 * scale)

            Text(card.subtitle)
                .font(.system(size: 9))
                .foregroundStyle(isSelected ? theme.selectedSubtitle : theme.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? theme.selectionFill : isHovered ? theme.cardHoverFill : theme.cardFill)
                .overlay {
                    if isSelected, let ring = theme.selectionRing {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ring, lineWidth: 1.5)
                    }
                }
        )
        .overlay(CardInteractionView(card: card))
        .overlay(alignment: .topTrailing) {
            if isHovered {
                // Visual only: the card's AppKit layer handles clicks on this corner.
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, theme.removeButtonFill)
                    .allowsHitTesting(false)
                    .offset(x: -1, y: 1)
                .accessibilityLabel("Remove from Cove")
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .scaleEffect(poof == true ? 0.55 : 1)
        .opacity(poof == true ? 0 : 1)
        .overlay {
            if let poof { PoofCloud(burst: poof) }
        }
        .allowsHitTesting(poof == nil)
    }
}

private struct CardThumbnail: View {
    let card: ShelfStack
    let scale: CGFloat
    let theme: ShelfTheme

    var body: some View {
        if card.isStack {
            ZStack {
                ForEach(Array(card.items.prefix(3).enumerated().reversed()), id: \.element.id) { index, item in
                    ThumbnailView(url: item.url, size: (42 * scale).rounded())
                        .rotationEffect(.degrees(Double(index) * 8 - 8))
                        .offset(x: CGFloat(index) * 5 - 5, y: CGFloat(index) * -2)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Text("\(card.items.count)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.onAccent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(theme.accent))
                    .overlay(Capsule().strokeBorder(.black, lineWidth: 1.5).padding(-1.5))
                    .offset(x: 4, y: 2)
            }
        } else if let item = card.items.first {
            ThumbnailView(url: item.url, size: (50 * scale).rounded())
        }
    }
}
