import CoreGraphics
import Foundation

struct HatPoint: Equatable {
    let x: CGFloat
    let y: CGFloat

    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }

    static func + (lhs: HatPoint, rhs: HatPoint) -> HatPoint {
        HatPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }

    static func - (lhs: HatPoint, rhs: HatPoint) -> HatPoint {
        HatPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }
}

struct HatAffine: Equatable {
    let a: CGFloat
    let b: CGFloat
    let c: CGFloat
    let d: CGFloat
    let e: CGFloat
    let f: CGFloat

    static let identity = HatAffine(a: 1, b: 0, c: 0, d: 0, e: 1, f: 0)

    func applying(to point: HatPoint) -> HatPoint {
        HatPoint(
            x: a * point.x + b * point.y + c,
            y: d * point.x + e * point.y + f
        )
    }

    func concatenating(_ other: HatAffine) -> HatAffine {
        HatAffine(
            a: a * other.a + b * other.d,
            b: a * other.b + b * other.e,
            c: a * other.c + b * other.f + c,
            d: d * other.a + e * other.d,
            e: d * other.b + e * other.e,
            f: d * other.c + e * other.f + f
        )
    }

    var inverse: HatAffine {
        let determinant = a * e - b * d
        precondition(abs(determinant) > 0.000_001, "Cannot invert a singular affine transform")

        return HatAffine(
            a: e / determinant,
            b: -b / determinant,
            c: (b * f - c * e) / determinant,
            d: -d / determinant,
            e: a / determinant,
            f: (c * d - a * f) / determinant
        )
    }

    static func translation(x: CGFloat, y: CGFloat) -> HatAffine {
        HatAffine(a: 1, b: 0, c: x, d: 0, e: 1, f: y)
    }

    static func rotation(_ angle: CGFloat) -> HatAffine {
        let cosine = CGFloat(cos(angle))
        let sine = CGFloat(sin(angle))
        return HatAffine(a: cosine, b: -sine, c: 0, d: sine, e: cosine, f: 0)
    }

    static func rotation(about point: HatPoint, angle: CGFloat) -> HatAffine {
        translation(x: point.x, y: point.y)
            .concatenating(rotation(angle))
            .concatenating(translation(x: -point.x, y: -point.y))
    }
}

struct HatChild {
    var transform: HatAffine
    var node: HatNode
}

struct HatMetaTile {
    var shape: [HatPoint]
    var width: CGFloat
    var children: [HatChild] = []

    mutating func addChild(_ transform: HatAffine, _ node: HatNode) {
        children.append(HatChild(transform: transform, node: node))
    }

    func evalChild(_ childIndex: Int, _ pointIndex: Int) -> HatPoint {
        children[childIndex].transform.applying(to: children[childIndex].node.shape[pointIndex])
    }

    mutating func recentre() {
        let sum = shape.reduce(HatPoint(x: 0, y: 0)) { partial, point in
            partial + point
        }
        let center = HatPoint(
            x: sum.x / CGFloat(shape.count),
            y: sum.y / CGFloat(shape.count)
        )
        let translation = HatPoint(x: -center.x, y: -center.y)

        shape = shape.map { $0 + translation }
        let matrix = HatAffine.translation(x: translation.x, y: translation.y)
        for index in children.indices {
            children[index].transform = matrix.concatenating(children[index].transform)
        }
    }
}

indirect enum HatNode {
    case hat
    case meta(HatMetaTile)

    var shape: [HatPoint] {
        switch self {
        case .hat:
            return HatTilingGenerator.hatOutline
        case .meta(let meta):
            return meta.shape
        }
    }
}

private enum PatchRuleValue {
    case index(Int)
    case shape(String)
}

enum HatTilingGenerator {
    static let hr3 = CGFloat(0.8660254037844386)

    static let hatOutline: [HatPoint] = [
        hexPoint(0, 0), hexPoint(-1, -1), hexPoint(0, -2), hexPoint(2, -2),
        hexPoint(2, -1), hexPoint(4, -2), hexPoint(5, -1), hexPoint(4, 0),
        hexPoint(3, 0), hexPoint(2, 2), hexPoint(0, 3), hexPoint(0, 2),
        hexPoint(-1, 2)
    ]

    static func polygons(level: Int, tileIndex: Int) -> [[CGPoint]] {
        let tiles = substitutedTiles(level: level)
        precondition(tiles.indices.contains(tileIndex), "Invalid hat tile index")
        return collectHatPolygons(from: .meta(tiles[tileIndex]))
    }

    static func patchPolygons(level: Int) -> [[CGPoint]] {
        let tiles = substitutedTiles(level: level)
        let patch = constructPatch(tiles[0], tiles[1], tiles[2], tiles[3])
        return collectHatPolygons(from: .meta(patch))
    }

    static func boundingBox(for polygons: [[CGPoint]]) -> CGRect {
        guard let firstPoint = polygons.first?.first else { return .zero }

        var minX = firstPoint.x
        var minY = firstPoint.y
        var maxX = firstPoint.x
        var maxY = firstPoint.y

        for polygon in polygons {
            for point in polygon {
                minX = min(minX, point.x)
                minY = min(minY, point.y)
                maxX = max(maxX, point.x)
                maxY = max(maxY, point.y)
            }
        }

        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }

    private static func collectHatPolygons(
        from node: HatNode,
        transform: HatAffine = .identity
    ) -> [[CGPoint]] {
        switch node {
        case .hat:
            return [hatOutline.map { transform.applying(to: $0).cgPoint }]
        case .meta(let meta):
            return meta.children.flatMap { child in
                collectHatPolygons(
                    from: child.node,
                    transform: transform.concatenating(child.transform)
                )
            }
        }
    }

    private static func substitutedTiles(level: Int) -> [HatMetaTile] {
        var tiles = initialTiles()

        guard level > 0 else { return tiles }

        for _ in 0..<level {
            let patch = constructPatch(tiles[0], tiles[1], tiles[2], tiles[3])
            tiles = constructMetatiles(from: patch)
        }

        return tiles
    }

    private static func initialTiles() -> [HatMetaTile] {
        [initialH(), initialT(), initialP(), initialF()]
    }

    private static func initialH() -> HatMetaTile {
        let outline = [
            point(0, 0), point(4, 0), point(4.5, hr3),
            point(2.5, 5 * hr3), point(1.5, 5 * hr3), point(-0.5, hr3)
        ]
        var meta = HatMetaTile(shape: outline, width: 2)

        meta.addChild(matchTwo(hatOutline[5], hatOutline[7], outline[5], outline[0]), .hat)
        meta.addChild(matchTwo(hatOutline[9], hatOutline[11], outline[1], outline[2]), .hat)
        meta.addChild(matchTwo(hatOutline[5], hatOutline[7], outline[3], outline[4]), .hat)

        let transform = HatAffine.translation(x: 2.5, y: hr3)
            .concatenating(HatAffine(a: -0.5, b: -hr3, c: 0, d: hr3, e: -0.5, f: 0))
            .concatenating(HatAffine(a: 0.5, b: 0, c: 0, d: 0, e: -0.5, f: 0))
        meta.addChild(transform, .hat)

        return meta
    }

    private static func initialT() -> HatMetaTile {
        let outline = [point(0, 0), point(3, 0), point(1.5, 3 * hr3)]
        var meta = HatMetaTile(shape: outline, width: 2)
        meta.addChild(HatAffine(a: 0.5, b: 0, c: 0.5, d: 0, e: 0.5, f: hr3), .hat)
        return meta
    }

    private static func initialP() -> HatMetaTile {
        let outline = [point(0, 0), point(4, 0), point(3, 2 * hr3), point(-1, 2 * hr3)]
        var meta = HatMetaTile(shape: outline, width: 2)
        meta.addChild(HatAffine(a: 0.5, b: 0, c: 1.5, d: 0, e: 0.5, f: hr3), .hat)

        let transform = HatAffine.translation(x: 0, y: 2 * hr3)
            .concatenating(HatAffine(a: 0.5, b: hr3, c: 0, d: -hr3, e: 0.5, f: 0))
            .concatenating(HatAffine(a: 0.5, b: 0, c: 0, d: 0, e: 0.5, f: 0))
        meta.addChild(transform, .hat)

        return meta
    }

    private static func initialF() -> HatMetaTile {
        let outline = [point(0, 0), point(3, 0), point(3.5, hr3), point(3, 2 * hr3), point(-1, 2 * hr3)]
        var meta = HatMetaTile(shape: outline, width: 2)
        meta.addChild(HatAffine(a: 0.5, b: 0, c: 1.5, d: 0, e: 0.5, f: hr3), .hat)

        let transform = HatAffine.translation(x: 0, y: 2 * hr3)
            .concatenating(HatAffine(a: 0.5, b: hr3, c: 0, d: -hr3, e: 0.5, f: 0))
            .concatenating(HatAffine(a: 0.5, b: 0, c: 0, d: 0, e: 0.5, f: 0))
        meta.addChild(transform, .hat)

        return meta
    }

    private static func constructPatch(
        _ h: HatMetaTile,
        _ t: HatMetaTile,
        _ p: HatMetaTile,
        _ f: HatMetaTile
    ) -> HatMetaTile {
        let rules: [[PatchRuleValue]] = [
            [.shape("H")],
            [.index(0), .index(0), .shape("P"), .index(2)],
            [.index(1), .index(0), .shape("H"), .index(2)],
            [.index(2), .index(0), .shape("P"), .index(2)],
            [.index(3), .index(0), .shape("H"), .index(2)],
            [.index(4), .index(4), .shape("P"), .index(2)],
            [.index(0), .index(4), .shape("F"), .index(3)],
            [.index(2), .index(4), .shape("F"), .index(3)],
            [.index(4), .index(1), .index(3), .index(2), .shape("F"), .index(0)],
            [.index(8), .index(3), .shape("H"), .index(0)],
            [.index(9), .index(2), .shape("P"), .index(0)],
            [.index(10), .index(2), .shape("H"), .index(0)],
            [.index(11), .index(4), .shape("P"), .index(2)],
            [.index(12), .index(0), .shape("H"), .index(2)],
            [.index(13), .index(0), .shape("F"), .index(3)],
            [.index(14), .index(2), .shape("F"), .index(1)],
            [.index(15), .index(3), .shape("H"), .index(4)],
            [.index(8), .index(2), .shape("F"), .index(1)],
            [.index(17), .index(3), .shape("H"), .index(0)],
            [.index(18), .index(2), .shape("P"), .index(0)],
            [.index(19), .index(2), .shape("H"), .index(2)],
            [.index(20), .index(4), .shape("F"), .index(3)],
            [.index(20), .index(0), .shape("P"), .index(2)],
            [.index(22), .index(0), .shape("H"), .index(2)],
            [.index(23), .index(4), .shape("F"), .index(3)],
            [.index(23), .index(0), .shape("F"), .index(3)],
            [.index(16), .index(0), .shape("P"), .index(2)],
            [.index(9), .index(4), .index(0), .index(2), .shape("T"), .index(2)],
            [.index(4), .index(0), .shape("F"), .index(3)]
        ]

        var result = HatMetaTile(shape: [], width: h.width)
        let shapes: [String: HatNode] = [
            "H": .meta(h),
            "T": .meta(t),
            "P": .meta(p),
            "F": .meta(f)
        ]

        for rule in rules {
            if rule.count == 1, case .shape(let name) = rule[0] {
                result.addChild(.identity, shapes[name]!)
            } else if rule.count == 4,
                      case .index(let sourceChildIndex) = rule[0],
                      case .index(let sourceEdgeIndex) = rule[1],
                      case .shape(let shapeName) = rule[2],
                      case .index(let targetEdgeIndex) = rule[3] {
                let sourcePolygon = result.children[sourceChildIndex].node.shape
                let sourceTransform = result.children[sourceChildIndex].transform
                let p1 = sourceTransform.applying(to: sourcePolygon[(sourceEdgeIndex + 1) % sourcePolygon.count])
                let q1 = sourceTransform.applying(to: sourcePolygon[sourceEdgeIndex])
                let nextShape = shapes[shapeName]!
                let targetPolygon = nextShape.shape
                let transform = matchTwo(
                    targetPolygon[targetEdgeIndex],
                    targetPolygon[(targetEdgeIndex + 1) % targetPolygon.count],
                    p1,
                    q1
                )
                result.addChild(transform, nextShape)
            } else if rule.count == 6,
                      case .index(let childPIndex) = rule[0],
                      case .index(let childPEdgeIndex) = rule[1],
                      case .index(let childQIndex) = rule[2],
                      case .index(let childQEdgeIndex) = rule[3],
                      case .shape(let shapeName) = rule[4],
                      case .index(let targetEdgeIndex) = rule[5] {
                let childP = result.children[childPIndex]
                let childQ = result.children[childQIndex]
                let p1 = childQ.transform.applying(to: childQ.node.shape[childQEdgeIndex])
                let q1 = childP.transform.applying(to: childP.node.shape[childPEdgeIndex])
                let nextShape = shapes[shapeName]!
                let targetPolygon = nextShape.shape
                let transform = matchTwo(
                    targetPolygon[targetEdgeIndex],
                    targetPolygon[(targetEdgeIndex + 1) % targetPolygon.count],
                    p1,
                    q1
                )
                result.addChild(transform, nextShape)
            }
        }

        return result
    }

    private static func constructMetatiles(from patch: HatMetaTile) -> [HatMetaTile] {
        let bps1 = patch.evalChild(8, 2)
        let bps2 = patch.evalChild(21, 2)
        let rotatedBps = HatAffine.rotation(about: bps1, angle: -2.0 * .pi / 3.0).applying(to: bps2)

        let p72 = patch.evalChild(7, 2)
        let p252 = patch.evalChild(25, 2)

        let lowerLeftCorner = intersect(
            p1: bps1,
            q1: rotatedBps,
            p2: patch.evalChild(6, 2),
            q2: p72
        )
        var w = patch.evalChild(6, 2) - lowerLeftCorner

        var newHOutline = [lowerLeftCorner, bps1]
        w = HatAffine.rotation(-.pi / 3).applying(to: w)
        newHOutline.append(newHOutline[1] + w)
        newHOutline.append(patch.evalChild(14, 2))
        w = HatAffine.rotation(-.pi / 3).applying(to: w)
        newHOutline.append(newHOutline[3] - w)
        newHOutline.append(patch.evalChild(6, 2))

        var newH = HatMetaTile(shape: newHOutline, width: patch.width * 2)
        for childIndex in [0, 9, 16, 27, 26, 6, 1, 8, 10, 15] {
            let child = patch.children[childIndex]
            newH.addChild(child.transform, child.node)
        }

        let newPOutline = [p72, p72 + (bps1 - lowerLeftCorner), bps1, lowerLeftCorner]
        var newP = HatMetaTile(shape: newPOutline, width: patch.width * 2)
        for childIndex in [7, 2, 3, 4, 28] {
            let child = patch.children[childIndex]
            newP.addChild(child.transform, child.node)
        }

        let newFOutline = [
            bps2,
            patch.evalChild(24, 2),
            patch.evalChild(25, 0),
            p252,
            p252 + (lowerLeftCorner - bps1)
        ]
        var newF = HatMetaTile(shape: newFOutline, width: patch.width * 2)
        for childIndex in [21, 20, 22, 23, 24, 25] {
            let child = patch.children[childIndex]
            newF.addChild(child.transform, child.node)
        }

        let aaa = newHOutline[2]
        let bbb = newHOutline[1] + (newHOutline[4] - newHOutline[5])
        let ccc = HatAffine.rotation(about: bbb, angle: -.pi / 3).applying(to: aaa)
        let newTOutline = [bbb, ccc, aaa]
        var newT = HatMetaTile(shape: newTOutline, width: patch.width * 2)
        let child = patch.children[11]
        newT.addChild(child.transform, child.node)

        newH.recentre()
        newP.recentre()
        newF.recentre()
        newT.recentre()

        return [newH, newT, newP, newF]
    }

    private static func point(_ x: CGFloat, _ y: CGFloat) -> HatPoint {
        HatPoint(x: x, y: y)
    }

    private static func hexPoint(_ x: CGFloat, _ y: CGFloat) -> HatPoint {
        point(x + 0.5 * y, hr3 * y)
    }

    private static func matchSegment(_ p: HatPoint, _ q: HatPoint) -> HatAffine {
        HatAffine(
            a: q.x - p.x,
            b: p.y - q.y,
            c: p.x,
            d: q.y - p.y,
            e: q.x - p.x,
            f: p.y
        )
    }

    private static func matchTwo(
        _ p1: HatPoint,
        _ q1: HatPoint,
        _ p2: HatPoint,
        _ q2: HatPoint
    ) -> HatAffine {
        matchSegment(p2, q2).concatenating(matchSegment(p1, q1).inverse)
    }

    private static func intersect(
        p1: HatPoint,
        q1: HatPoint,
        p2: HatPoint,
        q2: HatPoint
    ) -> HatPoint {
        let denominator = (q2.y - p2.y) * (q1.x - p1.x) - (q2.x - p2.x) * (q1.y - p1.y)
        let ua = ((q2.x - p2.x) * (p1.y - p2.y) - (q2.y - p2.y) * (p1.x - p2.x)) / denominator

        return HatPoint(
            x: p1.x + ua * (q1.x - p1.x),
            y: p1.y + ua * (q1.y - p1.y)
        )
    }
}
