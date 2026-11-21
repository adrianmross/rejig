import XCTest

@testable import TileCore

final class TreeTests: XCTestCase {
  let area = CGRect(x: 0, y: 0, width: 1000, height: 600)

  func tree(_ ids: Int...) -> Tree {
    let t = Tree(orientation: .h)
    for id in ids {
      t.insert(id)
      t.focused = id
    }
    return t
  }

  func testTilesHonourGaps() {
    let r = tree(1, 2).layout(in: area, gaps: Gaps())
    // 1000 - 5 left - 5 right - 5 inner = 985, split in two
    XCTAssertEqual(r[1], CGRect(x: 5, y: 7, width: 492.5, height: 588))
    XCTAssertEqual(r[2], CGRect(x: 502.5, y: 7, width: 492.5, height: 588))
  }

  func testAccordionPadding() {
    let t = tree(1, 2, 3)
    t.cycle(1, .accordion)
    let r = t.layout(in: area, gaps: Gaps())
    XCTAssertEqual(r[1]!.minX, 5)
    XCTAssertEqual(r[1]!.width, 960)
    XCTAssertEqual(r[2]!.minX, 35)
    XCTAssertEqual(r[2]!.width, 930)
    XCTAssertEqual(r[3]!.maxX, 995)
  }

  func testMoveSwapsThenStopsAtEdge() {
    let t = tree(1, 2, 3)
    XCTAssertTrue(t.move(1, .right))
    XCTAssertEqual(t.windows, [2, 1, 3])
    XCTAssertFalse(t.move(2, .left))
  }

  func testMoveAcrossAxisWrapsRootAndNormalizes() {
    let t = tree(1, 2, 3)
    XCTAssertTrue(t.move(3, .down))
    XCTAssertEqual(t.root.orientation, .v)
    XCTAssertEqual(t.root.children.count, 2)
    XCTAssertEqual(t.root.children[0].orientation, .h)  // nested container is opposite
    XCTAssertEqual(t.root.children[1].window, 3)
    // taking a window back out leaves a single-child container, which is flattened away
    t.remove(1)
    XCTAssertEqual(t.root.children.map(\.window), [2, 3])
  }

  func testJoinNestsWithNeighbour() {
    let t = tree(1, 2, 3)
    XCTAssertTrue(t.join(3, .left))
    XCTAssertEqual(t.root.children.count, 2)
    XCTAssertEqual(t.root.children[1].children.map(\.window), [2, 3])
    XCTAssertEqual(t.root.children[1].orientation, .v)
    t.flatten()
    XCTAssertEqual(t.root.children.map(\.window), [1, 2, 3])
  }

  func testResizeTakesFromSiblings() {
    let t = tree(1, 2)
    _ = t.layout(in: area, gaps: Gaps())
    t.resize(1, by: 50, inner: 5)
    let r = t.layout(in: area, gaps: Gaps())
    XCTAssertEqual(r[1]!.width, 542.5, accuracy: 0.01)
    XCTAssertEqual(r[2]!.width, 442.5, accuracy: 0.01)
  }

  func testAxisResizeFindsTheRightContainerAndSwapKeepsSlots() {
    let t = tree(1, 2, 3)
    XCTAssertTrue(t.join(3, .left))  // [1 | (2 over 3)]
    _ = t.layout(in: area, gaps: Gaps())
    t.resize(3, by: 100, inner: 5, axis: .h)  // 3 sits in a vertical pair: the pair grows
    t.swap(1, 3)
    let r = t.layout(in: area, gaps: Gaps())
    XCTAssertEqual(r[1]!.width, 592.5, accuracy: 0.01)
    XCTAssertEqual(r[3]!.width, 392.5, accuracy: 0.01)
    XCTAssertEqual(r[3]!.minX, 5)
    XCTAssertEqual(r[1]!.minY, r[2]!.maxY + 5, accuracy: 0.01)
  }

  func testZoomFillsWorkspace() {
    let t = tree(1, 2)
    t.zoomed = 2
    XCTAssertEqual(t.layout(in: area, gaps: Gaps())[2], CGRect(x: 5, y: 7, width: 990, height: 588))
  }

  func testNearestPrefersAlignedWindow() {
    let rects = [
      2: CGRect(x: 500, y: 0, width: 500, height: 300), 3: CGRect(x: 500, y: 300, width: 500, height: 300),
    ]
    XCTAssertEqual(nearest(from: CGRect(x: 0, y: 0, width: 500, height: 300), .right, in: rects), 2)
    XCTAssertNil(nearest(from: rects[2]!, .right, in: rects))
    XCTAssertEqual(nearest(from: rects[2]!, .down, in: rects), 3)
  }

  func testSplitPutsTheNewWindowBesideOrBelow() {
    let t = tree(1, 2)
    t.split(2, with: 3, .v)  // [1 | (2 over 3)]
    t.split(1, with: 4, .h)  // [1 | 4 | (2 over 3)]
    let r = t.layout(in: area, gaps: Gaps())
    XCTAssertEqual(r[3]!.minX, r[2]!.minX)
    XCTAssertEqual(r[3]!.minY, r[2]!.maxY + 5, accuracy: 0.01)
    XCTAssertEqual(r[4]!.minX, r[1]!.maxX + 5, accuracy: 0.01)
    XCTAssertEqual(r[4]!.height, r[1]!.height)
  }

  func testNamedPlaces() {
    let a = CGRect(x: 0, y: 0, width: 1010, height: 605), s = CGSize(width: 400, height: 300)
    XCTAssertEqual(place("bottom-right", in: a, inner: 5, size: s), CGRect(x: 507.5, y: 305, width: 502.5, height: 300))
    XCTAssertEqual(place("center-third", in: a, inner: 5, size: s)!.minX, 1010 / 3 + 5.0 / 3, accuracy: 0.01)
    XCTAssertEqual(place("right-two-thirds", in: a, inner: 5, size: s)!.maxX, 1010, accuracy: 0.01)
    XCTAssertEqual(place("left-two-thirds", in: a, inner: 5, size: s)!.width, 2 * 1000 / 3 + 5.0, accuracy: 0.01)
    XCTAssertEqual(place("center", in: a, inner: 5, size: s), CGRect(x: 305, y: 152.5, width: 400, height: 300))
    XCTAssertEqual(place("maximize", in: a, inner: 5, size: s), a)
    XCTAssertNil(place("nowhere", in: a, inner: 5, size: s))
    XCTAssertEqual(place("almost-maximize", in: a, inner: 5, size: s)!.width, a.width * 0.9, accuracy: 0.01)
    XCTAssertEqual(place("right-half", in: a, inner: 5, size: s)!.minX, place("top-right", in: a, inner: 5, size: s)!.minX)
    XCTAssertEqual(place("bottom-half", in: a, inner: 5, size: s)!.width, a.width)
  }

  func testSnapWalksHalvesQuartersAndDisplays() {
    let a = CGRect(x: 0, y: 0, width: 1005, height: 605), b = CGRect(x: 1005, y: 0, width: 1005, height: 605)
    var f = snap(CGRect(x: 300, y: 200, width: 400, height: 300), in: a, .left, inner: 5)
    XCTAssertEqual(f, CGRect(x: 0, y: 0, width: 500, height: 605))  // left half
    f = snap(f, in: a, .up, inner: 5)
    XCTAssertEqual(f, CGRect(x: 0, y: 0, width: 500, height: 300))  // top-left quarter
    f = snap(f, in: a, .right, inner: 5)
    XCTAssertEqual(f, CGRect(x: 0, y: 0, width: 1005, height: 300))  // top half
    f = snap(f, in: a, .right, inner: 5)
    XCTAssertEqual(f, CGRect(x: 505, y: 0, width: 500, height: 300))  // top-right quarter
    XCTAssertEqual(snap(f, in: a, .right, inner: 5), f)  // no display that way: stays
    f = snap(f, in: a, .right, inner: 5, next: b)
    XCTAssertEqual(f, CGRect(x: 1005, y: 0, width: 500, height: 300))  // next display, near side
    XCTAssertEqual(snap(f, in: b, .down, inner: 5), CGRect(x: 1005, y: 0, width: 500, height: 605))
  }
}
