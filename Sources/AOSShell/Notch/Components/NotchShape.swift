import SwiftUI

// MARK: - NotchOutlineShape
//
// A pure SwiftUI `Shape` that traces just the outer silhouette path of the
// notch — used as a mask source by EdgeHighlightOverlay so the radial
// highlight appears only along the edge stroke. The full visual silhouette
// (with the destinationOut shoulder cutouts) is rendered by `NotchShape`
// below; this is the simpler matching outline for highlight masking.
struct NotchOutlineShape: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(cornerRadius, min(rect.width, rect.height) / 2)
        // Top-left corner (square at the top, since the menu bar continues)
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX - r, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - r),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        p.closeSubpath()
        return p
    }
}

// MARK: - NotchEdgeHighlightShape
//
// Open highlight path for the interactive white glow. It intentionally omits
// the top edge because the notch attaches to the menu bar there; only the
// left, bottom-center, and right visible edges should catch the glow.
struct NotchEdgeHighlightShape: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(cornerRadius, min(rect.width, rect.height) / 2)
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + r, y: rect.maxY),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY - r),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return p
    }
}


// MARK: - NotchShape
//
// Implements the rounded-notch silhouette per notch-dev-guide.md §6:
// a downward-rounded rectangle with two `destinationOut` cutouts at the
// shoulders to create the inverse-curve transition into the surrounding
// menu bar.
//
// The view derives its size and corner radii from the `status` argument
// (closed/popping/opened) so SwiftUI's `.animation(_:value:status)` can
// interpolate between the three layouts in one spring.

struct NotchShape: View {
    let status: NotchViewModel.Status
    let deviceNotchRect: CGRect
    let panelSize: CGSize

    /// Visual silhouette in closed/popping state must wrap the entire
    /// ClosedBar (icon + middle + emoji), so the bar gets the same
    /// rounded-bottom + concave-shoulder shape as the original device notch
    /// instead of three flat black rectangles.
    private var closedBarWidth: CGFloat {
        deviceNotchRect.width + 2 * deviceNotchRect.height
    }

    private var notchSize: CGSize {
        switch status {
        case .closed, .popping:
            // Popping shares the closed footprint: the hover "grow" effect
            // is applied as a top-anchored scaleEffect in NotchView so the
            // shape and the content scale together as one container.
            return CGSize(
                width: max(closedBarWidth, 0),
                height: max(deviceNotchRect.height, 0)
            )
        case .opened:
            return panelSize
        }
    }

    private var notchCornerRadius: CGFloat {
        switch status {
        case .closed, .popping: return 8
        case .opened: return 32
        }
    }

    private var shoulderRadius: CGFloat {
        switch status {
        case .closed, .popping: return 6
        case .opened: return 18
        }
    }

    var body: some View {
        let r = notchCornerRadius
        let sh = shoulderRadius
        let spacing: CGFloat = 0.5

        return Rectangle()
            .foregroundStyle(.black)
            .frame(width: notchSize.width, height: notchSize.height)
            .clipShape(.rect(bottomLeadingRadius: r, bottomTrailingRadius: r))
            .overlay(alignment: .topLeading) {
                // Left shoulder: black square + topTrailing-rounded mask
                ZStack(alignment: .topTrailing) {
                    Rectangle()
                        .frame(width: sh, height: sh)
                        .foregroundStyle(.black)
                    Rectangle()
                        .clipShape(.rect(topTrailingRadius: sh))
                        .foregroundStyle(.white)
                        .frame(width: sh + spacing, height: sh + spacing)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
                .offset(x: -sh - spacing + 0.5, y: -0.5)
            }
            .overlay(alignment: .topTrailing) {
                // Right shoulder mirrors the left.
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .frame(width: sh, height: sh)
                        .foregroundStyle(.black)
                    Rectangle()
                        .clipShape(.rect(topLeadingRadius: sh))
                        .foregroundStyle(.white)
                        .frame(width: sh + spacing, height: sh + spacing)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
                .offset(x: sh + spacing - 0.5, y: -0.5)
            }
    }
}
