import CoreGraphics

public enum Orientation {
  case h, v
  public var flipped: Orientation { self == .h ? .v : .h }
}

public enum Layout { case tiles, accordion }

public enum Direction: String {
  case left, down, up, right
  public var axis: Orientation { self == .left || self == .right ? .h : .v }
  public var sign: Int { self == .right || self == .down ? 1 : -1 }
}

public struct Gaps {
  public var inner: CGFloat = 5
  public var top: CGFloat = 7
  public var left: CGFloat = 5
  public var bottom: CGFloat = 5
  public var right: CGFloat = 5
  public var accordion: CGFloat = 30
  public init() {}
}

public final class Node {
  public let window: Int?  // set on leaves, nil on containers
  public var layout = Layout.tiles
  public var orientation: Orientation
  public var children: [Node] = []
  public var weight: CGFloat = 1
  public weak var parent: Node?
  public var rect = CGRect.zero  // from the last layout pass

  init(window: Int? = nil, orientation: Orientation = .h) {
    self.window = window
    self.orientation = orientation
  }

  var leaves: [Node] { window != nil ? [self] : children.flatMap(\.leaves) }
  var index: Int? { parent?.children.firstIndex { $0 === self } }
}

/// One workspace's window tree. Coordinates are top-left origin (y grows down),
/// so "down" is the positive direction, matching the Accessibility API.
public final class Tree {
  public private(set) var root: Node
  public var defaultOrientation: Orientation
  public var focused: Int?
  public var zoomed: Int?
  /// Off means this workspace is left to plain macOS window handling.
  public var enabled = true

  public init(orientation: Orientation) {
    defaultOrientation = orientation
    root = Node(orientation: orientation)
  }

  public var windows: [Int] { root.leaves.compactMap(\.window) }
  public func contains(_ id: Int) -> Bool { leaf(id) != nil }
  func leaf(_ id: Int) -> Node? { root.leaves.first { $0.window == id } }

  /// New windows land after the focused one, like AeroSpace.
  public func insert(_ id: Int) {
    guard leaf(id) == nil else { return }
    let node = Node(window: id)
    if let f = focused.flatMap(leaf), let p = f.parent, let i = f.index {
      attach(node, to: p, at: i + 1)
    } else {
      attach(node, to: root, at: root.children.count)
    }
    normalize()
  }

  /// Puts `id` just after `beside` along `axis`: next to it when its container
  /// already runs that way, else the two share a new container in its place.
  public func split(_ beside: Int, with id: Int, _ axis: Orientation) {
    if leaf(id) != nil, id != beside { remove(id) }
    guard leaf(id) == nil, let t = leaf(beside), let p = t.parent, let i = t.index else { return insert(id) }
    let node = Node(window: id)
    if p.children.count == 1 { p.orientation = axis }
    if p.orientation == axis {
      attach(node, to: p, at: i + 1)
    } else {
      let c = Node(orientation: axis)
      c.weight = t.weight
      p.children[i] = c
      c.parent = p
      c.children = [t, node]
      for child in c.children {
        child.parent = c
        child.weight = 1
      }
    }
    normalize()
  }

  public func remove(_ id: Int) {
    guard let n = leaf(id) else { return }
    detach(n)
    if focused == id { focused = nil }
    if zoomed == id { zoomed = nil }
    normalize()
  }

  public func layout(in area: CGRect, gaps: Gaps) -> [Int: CGRect] {
    let inner = CGRect(
      x: area.minX + gaps.left, y: area.minY + gaps.top,
      width: area.width - gaps.left - gaps.right, height: area.height - gaps.top - gaps.bottom)
    var out: [Int: CGRect] = [:]
    place(root, inner, gaps, &out)
    if let z = zoomed, out[z] != nil { out[z] = inner }
    return out
  }

  /// Returns false when the window is already at the workspace edge in `dir`.
  public func move(_ id: Int, _ dir: Direction) -> Bool {
    guard let n = leaf(id) else { return false }
    if let (anchor, sib) = adjacent(n, dir), let p = anchor.parent {
      if anchor === n, sib.window != nil {
        p.children.swapAt(n.index!, sib.index!)
      } else if anchor === n {  // sibling is a container: enter it at the near edge
        detach(n)
        attach(n, to: sib, at: dir.sign > 0 ? 0 : sib.children.count)
      } else {  // leave the nested container, land beside it
        detach(n)
        let i = anchor.index!
        attach(n, to: p, at: dir.sign > 0 ? i + 1 : i)
      }
    } else if root.orientation != dir.axis, root.children.count > 1 {
      detach(n)
      let old = root
      root = Node(orientation: dir.axis)
      root.children = [old]
      old.parent = root
      attach(n, to: root, at: dir.sign > 0 ? 1 : 0)
    } else {
      return false
    }
    normalize()
    return true
  }

  /// Puts the window and its neighbour in `dir` into a new container.
  public func join(_ id: Int, _ dir: Direction) -> Bool {
    guard let n = leaf(id), let (_, sib) = adjacent(n, dir), let p = sib.parent else { return false }
    detach(n)
    let c = Node(orientation: p.orientation.flipped)
    c.weight = sib.weight
    p.children[sib.index!] = c
    c.parent = p
    c.children = dir.sign > 0 ? [n, sib] : [sib, n]
    for child in c.children {
      child.parent = c
      child.weight = 1
    }
    normalize()
    return true
  }

  /// Trades places, keeping each slot's size. For dropping one window onto another.
  public func swap(_ a: Int, _ b: Int) {
    guard let x = leaf(a), let y = leaf(b), let px = x.parent, let py = y.parent, let i = x.index, let j = y.index
    else { return }
    px.children[i] = y
    py.children[j] = x
    x.parent = py
    y.parent = px
    (x.weight, y.weight) = (y.weight, x.weight)
  }

  /// AeroSpace's "resize smart": along the parent's orientation, taking from the siblings.
  /// With an `axis`, along that axis instead, at the nearest container that splits that way.
  public func resize(_ id: Int, by delta: CGFloat, inner: CGFloat, axis: Orientation? = nil) {
    guard var n = leaf(id) else { return }
    while let p = n.parent,
      p.children.count < 2 || p.layout == .accordion || (axis != nil && p.orientation != axis)
    { n = p }
    guard let p = n.parent else { return }
    let count = CGFloat(p.children.count)
    let total = (p.orientation == .h ? p.rect.width : p.rect.height) - inner * (count - 1)
    let sum = p.children.map(\.weight).reduce(0, +)
    guard total > 0 else { return }
    let cur = total * n.weight / sum
    let new = min(max(cur + delta, 50), total - 50 * (count - 1))
    guard new > 0, total > cur else { return }
    for c in p.children {
      c.weight = c === n ? new : total * c.weight / sum * (total - new) / (total - cur)
    }
  }

  /// `layout tiles horizontal vertical` / `layout accordion horizontal vertical`.
  public func cycle(_ id: Int, _ layout: Layout) {
    guard let p = leaf(id)?.parent else { return }
    if p.layout == layout {
      p.orientation = p.orientation.flipped
    } else {
      p.layout = layout
      p.orientation = .h
    }
    normalize()
  }

  public func flatten() {
    let leaves = root.leaves
    root = Node(orientation: defaultOrientation)
    root.children = leaves
    for l in leaves {
      l.parent = root
      l.weight = 1
    }
  }

  // MARK: internals

  private func attach(_ n: Node, to p: Node, at i: Int) {
    // an average share, so the existing proportions survive
    n.weight = p.children.isEmpty ? 1 : p.children.map(\.weight).reduce(0, +) / CGFloat(p.children.count)
    p.children.insert(n, at: i)
    n.parent = p
  }

  private func detach(_ n: Node) {
    n.parent?.children.removeAll { $0 === n }
    n.parent = nil
  }

  /// The closest ancestor (or the node itself) with a sibling in `dir`, and that sibling.
  private func adjacent(_ n: Node, _ dir: Direction) -> (anchor: Node, sibling: Node)? {
    var a = n
    while let p = a.parent, let i = a.index {
      let t = i + dir.sign
      if p.orientation == dir.axis, p.children.indices.contains(t) { return (a, p.children[t]) }
      a = p
    }
    return nil
  }

  /// AeroSpace's two normalizations: flatten single-child containers, and give
  /// nested containers the opposite orientation to their parent.
  private func normalize() {
    flatten(root)
    while root.children.count == 1, root.children[0].window == nil {
      root = root.children[0]
      root.parent = nil
    }
    if root.children.count <= 1 { root.orientation = defaultOrientation }
    alternate(root)
  }

  private func flatten(_ n: Node) {
    n.children.forEach(flatten)
    n.children = n.children.flatMap { c -> [Node] in
      if c.window != nil || c.children.count > 1 { return [c] }
      c.children.first?.weight = c.weight
      return c.children
    }
    n.children.forEach { $0.parent = n }
  }

  private func alternate(_ n: Node) {
    for c in n.children where c.window == nil {
      if c.orientation == n.orientation { c.orientation = n.orientation.flipped }
      alternate(c)
    }
  }

  private func place(_ n: Node, _ r: CGRect, _ g: Gaps, _ out: inout [Int: CGRect]) {
    n.rect = r
    if let w = n.window {
      out[w] = r
      return
    }
    let count = n.children.count
    let horizontal = n.orientation == .h
    switch n.layout {
    case .tiles:
      let total = (horizontal ? r.width : r.height) - g.inner * CGFloat(count - 1)
      let sum = n.children.map(\.weight).reduce(0, +)
      var offset = horizontal ? r.minX : r.minY
      for c in n.children {
        let len = total * c.weight / sum
        place(
          c,
          horizontal
            ? CGRect(x: offset, y: r.minY, width: len, height: r.height)
            : CGRect(x: r.minX, y: offset, width: r.width, height: len), g, &out)
        offset += len + g.inner
      }
    case .accordion:
      for (i, c) in n.children.enumerated() {
        let before = i > 0 ? g.accordion : 0
        let after = i < count - 1 ? g.accordion : 0
        place(
          c,
          horizontal
            ? CGRect(x: r.minX + before, y: r.minY, width: r.width - before - after, height: r.height)
            : CGRect(x: r.minX, y: r.minY + before, width: r.width, height: r.height - before - after),
          g, &out)
      }
    }
  }
}

/// The rect whose centre is nearest in `dir`, penalising sideways offset.
// ponytail: geometric, not tree-based like AeroSpace; ties between equally
// near windows are arbitrary. Track per-container MRU if that ever matters.
public func nearest(from: CGRect, _ dir: Direction, in rects: [Int: CGRect]) -> Int? {
  rects.compactMap { id, r -> (Int, CGFloat)? in
    let dx = r.midX - from.midX, dy = r.midY - from.midY
    let (along, across) = dir.axis == .h ? (dx * CGFloat(dir.sign), dy) : (dy * CGFloat(dir.sign), dx)
    return along > 1 ? (id, along + 2 * abs(across)) : nil
  }.min { $0.1 < $1.1 }?.0
}

/// Rectangle-style stepping for a floating window. Each press moves it one step
/// along that axis through near half, full span, far half, so the four direction
/// keys reach every half, every quarter and the whole area. Stepping off the edge
/// enters `next` (the display on that side) on its near half.
// ponytail: a window that can't shrink to half (fixed size) reads as "full" every
// time, so it never steps off to the next display; drag it there.
public func snap(_ frame: CGRect, in area: CGRect, _ dir: Direction, inner: CGFloat, next: CGRect? = nil) -> CGRect {
  // 0 near half, 1 full span, 2 far half; a window that is neither half counts as full
  func slot(_ lo: CGFloat, _ len: CGFloat, _ from: CGFloat, _ span: CGFloat) -> Int {
    guard abs(len - (span - inner) / 2) < 20 else { return 1 }
    return abs(lo - from) < 20 ? 0 : abs(lo + len - from - span) < 20 ? 2 : 1
  }
  func place(_ slot: Int, _ from: CGFloat, _ span: CGFloat) -> (CGFloat, CGFloat) {
    let half = (span - inner) / 2
    return slot == 1 ? (from, span) : (slot == 0 ? from : from + half + inner, half)
  }
  var h = slot(frame.minX, frame.width, area.minX, area.width)
  var v = slot(frame.minY, frame.height, area.minY, area.height)
  var area = area
  if dir.axis == .h { h += dir.sign } else { v += dir.sign }
  if !(0...2).contains(h) || !(0...2).contains(v) {
    guard let next else { return frame }
    area = next
    if dir.axis == .h { h = dir.sign > 0 ? 0 : 2 } else { v = dir.sign > 0 ? 0 : 2 }
  }
  let (x, w) = place(h, area.minX, area.width)
  let (y, height) = place(v, area.minY, area.height)
  return CGRect(x: x, y: y, width: w, height: height)
}

/// Rectangle's named places for a floating window: halves, quarters, thirds, two thirds,
/// the whole area, or centred at its own size. Nil for a name it doesn't know.
public func place(_ name: String, in area: CGRect, inner: CGFloat, size: CGSize) -> CGRect? {
  // `count` of `parts` equal slices starting at slice `start`, with `inner` between slices
  func cut(_ from: CGFloat, _ span: CGFloat, _ parts: CGFloat, _ start: CGFloat, _ count: CGFloat = 1) -> (CGFloat, CGFloat) {
    let one = (span - inner * (parts - 1)) / parts
    return (from + start * (one + inner), one * count + inner * (count - 1))
  }
  var x = (area.minX, area.width), y = (area.minY, area.height)
  switch name {
  case "maximize": break
  case "almost-maximize": return area.insetBy(dx: area.width * 0.05, dy: area.height * 0.05)
  case "center":
    let w = min(size.width, area.width), h = min(size.height, area.height)
    return CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
  case "top-left", "top-right", "bottom-left", "bottom-right":
    x = cut(area.minX, area.width, 2, name.hasSuffix("left") ? 0 : 1)
    y = cut(area.minY, area.height, 2, name.hasPrefix("top") ? 0 : 1)
  case "left-half", "right-half": x = cut(area.minX, area.width, 2, name.hasPrefix("left") ? 0 : 1)
  case "top-half", "bottom-half": y = cut(area.minY, area.height, 2, name.hasPrefix("top") ? 0 : 1)
  case "left-third": x = cut(area.minX, area.width, 3, 0)
  case "center-third": x = cut(area.minX, area.width, 3, 1)
  case "right-third": x = cut(area.minX, area.width, 3, 2)
  case "left-two-thirds": x = cut(area.minX, area.width, 3, 0, 2)
  case "right-two-thirds": x = cut(area.minX, area.width, 3, 1, 2)
  default: return nil
  }
  return CGRect(x: x.0, y: y.0, width: x.1, height: y.1)
}
