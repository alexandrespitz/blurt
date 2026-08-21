import CoreGraphics
import Foundation

/// Picks which text input you meant, given where you are looking.
///
/// Pure geometry so it can be tested: the box under the point wins outright;
/// otherwise the one whose center is closest. Ties go to the smaller box,
/// because a huge web area behind a small search field is never the intent.
enum NearestInput {

    struct Candidate: Equatable {
        var index: Int
        var frame: CGRect
    }

    static func pick(_ candidates: [Candidate], near point: CGPoint) -> Candidate? {
        guard !candidates.isEmpty else { return nil }

        let containing = candidates.filter { $0.frame.contains(point) }
        if !containing.isEmpty {
            return containing.min { area($0) < area($1) }
        }

        return candidates.min { lhs, rhs in
            let a = distance(from: point, to: lhs.frame)
            let b = distance(from: point, to: rhs.frame)
            if a != b { return a < b }
            return area(lhs) < area(rhs)
        }
    }

    private static func area(_ candidate: Candidate) -> CGFloat {
        candidate.frame.width * candidate.frame.height
    }

    /// Distance from a point to a rectangle's nearest edge (zero inside).
    static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
