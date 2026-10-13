import CoreGraphics
import Foundation

public enum ReferenceLinkGeometry {
    public struct Geometry {
        public let path: CGPath
        public let arrow: CGPath
    }

    /// Separate collinear overlapping references while preserving center endpoints.
    public static func make(link: CardLink, links: [CardLink], frames: [UUID: CGRect]) -> Geometry? {
        guard let source = frames[link.sourceCardId], let target = frames[link.targetCardId] else { return nil }
        let start = CGPoint(x: source.midX, y: source.midY)
        let end = CGPoint(x: target.midX, y: target.midY)
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 1 else { return nil }
        // Canonical direction makes reciprocal links share the same lane ordering.
        let sign: CGFloat = dx < 0 || (abs(dx) < 0.001 && dy < 0) ? -1 : 1
        let ux = dx / length * sign, uy = dy / length * sign
        let nx = -uy, ny = ux
        let originProjection = start.x * ux + start.y * uy
        let endProjection = end.x * ux + end.y * uy
        let low = min(originProjection, endProjection), high = max(originProjection, endProjection)
        let peers = links.filter { other in
            guard let a = frames[other.sourceCardId], let b = frames[other.targetCardId] else { return false }
            let ac = CGPoint(x: a.midX, y: a.midY), bc = CGPoint(x: b.midX, y: b.midY)
            let al = hypot(bc.x - ac.x, bc.y - ac.y)
            guard al > 1 else { return false }
            let parallel = abs((bc.x - ac.x) * nx + (bc.y - ac.y) * ny) / al < 0.01
            let distance = abs((ac.x - start.x) * nx + (ac.y - start.y) * ny)
            let ap = ac.x * ux + ac.y * uy, bp = bc.x * ux + bc.y * uy
            return parallel && distance < 3 && min(high, max(ap, bp)) - max(low, min(ap, bp)) > 10
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        let lane = peers.firstIndex(where: { $0.id == link.id }) ?? 0
        let offset = peers.count > 1 ? (CGFloat(lane) - CGFloat(peers.count - 1) / 2) * 10 : 0
        let shift = CGPoint(x: nx * offset, y: ny * offset)
        let lead = min(length / 3, 30 + abs(offset))
        let direction = CGPoint(x: dx / length, y: dy / length)
        let a = CGPoint(x: start.x + direction.x * lead + shift.x, y: start.y + direction.y * lead + shift.y)
        let b = CGPoint(x: end.x - direction.x * lead + shift.x, y: end.y - direction.y * lead + shift.y)
        let path = CGMutablePath()
        path.move(to: start)
        path.addLine(to: a)
        path.addLine(to: b)
        path.addLine(to: end)

        // Place the arrow on the last segment, just outside the destination rectangle.
        let vx = end.x - b.x, vy = end.y - b.y
        let segmentLength = hypot(vx, vy)
        let ax = vx / segmentLength, ay = vy / segmentLength
        let boundary = min(abs(ax) > 0.0001 ? target.width / 2 / abs(ax) : .greatestFiniteMagnitude,
                           abs(ay) > 0.0001 ? target.height / 2 / abs(ay) : .greatestFiniteMagnitude)
        // For long cards the final segment can begin inside the card; extend the
        // marker along the preceding straight lane instead.
        let arrowDirection: CGPoint
        let tip: CGPoint
        if boundary + 7 < segmentLength {
            arrowDirection = CGPoint(x: ax, y: ay)
            tip = CGPoint(x: end.x - ax * (boundary + 7), y: end.y - ay * (boundary + 7))
        } else {
            arrowDirection = direction
            let extent = min(abs(direction.x) > 0.0001 ? target.width / 2 / abs(direction.x) : .greatestFiniteMagnitude,
                             abs(direction.y) > 0.0001 ? target.height / 2 / abs(direction.y) : .greatestFiniteMagnitude)
            tip = CGPoint(x: end.x - direction.x * (extent + 9) + shift.x,
                          y: end.y - direction.y * (extent + 9) + shift.y)
        }
        let arrow = CGMutablePath()
        arrow.move(to: tip)
        arrow.addLine(to: CGPoint(x: tip.x - arrowDirection.x * 9 - arrowDirection.y * 4,
                                 y: tip.y - arrowDirection.y * 9 + arrowDirection.x * 4))
        arrow.addLine(to: CGPoint(x: tip.x - arrowDirection.x * 9 + arrowDirection.y * 4,
                                 y: tip.y - arrowDirection.y * 9 - arrowDirection.x * 4))
        arrow.closeSubpath()
        return Geometry(path: path, arrow: arrow)
    }
}
