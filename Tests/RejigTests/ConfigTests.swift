import XCTest

@testable import rejig

final class ConfigTests: XCTestCase {
  private func config(_ json: String) throws -> Config {
    try JSONDecoder().decode(Config.self, from: Data(json.utf8))
  }

  func testAnEmptyFileIsTheDefaults() throws {
    let c = try config("{}")
    XCTAssertEqual(c.style, "highlight")
    XCTAssertTrue(c.cycle)
    XCTAssertFalse(c.edgeSnap)
    XCTAssertEqual(c.gaps.top, 7)
    XCTAssertEqual(c.modes["main"]?["ctrl-alt-left"], ["focus left"])
  }

  func testOneGapLeavesTheOthers() throws {
    let c = try config(#"{"gaps": {"inner": 12}}"#)
    XCTAssertEqual(c.gaps.inner, 12)
    XCTAssertEqual(c.gaps.top, 7)
  }

  func testAReboundKeyKeepsTheRestAndAnEmptyListUnbinds() throws {
    let c = try config(#"{"keys": "vim", "modes": {"main": {"alt-enter": ["fullscreen"], "alt-tab": []}}}"#)
    XCTAssertEqual(c.modes["main"]?["alt-enter"], ["fullscreen"])
    XCTAssertEqual(c.modes["main"]?["alt-tab"], [])
    XCTAssertEqual(c.modes["main"]?["alt-h"], ["focus left"])
    // the arrows are free in this preset, so they take the halves
    XCTAssertEqual(c.modes["main"]?["ctrl-alt-left"], ["snap left-half"])
  }

  func testOlderSwitchesStillRead() throws {
    XCTAssertEqual(try config(#"{"highlight": false}"#).style, "plain")
    XCTAssertEqual(try config(#"{"highlight": false, "style": "shadow"}"#).style, "shadow")
    XCTAssertEqual(try config(#"{"showWorkspaces": false}"#).menuBar, "icon")
  }

  func testEveryDefaultKeyCanBeRegistered() {
    for preset in ["macos", "vim", "rex"] {
      for (mode, keys) in Config.defaultModes(preset) {
        for key in keys.keys { XCTAssertNotNil(Hotkeys.parse(key), "\(preset) \(mode) \(key)") }
      }
    }
  }

  func testKeyNames() {
    XCTAssertEqual(Hotkeys.parse("alt-shift-h")?.0, 4)
    XCTAssertNil(Hotkeys.parse("alt-nonsense"))
    XCTAssertNil(Hotkeys.parse("hyper-h"))
  }
}
