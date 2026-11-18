import AppKit
import CVirtualDisplay
import ScreenCaptureKit

/// A display with no monitor. Windows put on it are out of the user's way
/// without any desktop having to slide, and a viewer window shows it live for
/// anyone who wants to look. Made on demand, gone when Rejig quits.
final class AgentScreen: NSObject, SCStreamOutput, NSWindowDelegate {
  static let name = "Rejig Agents"
  static let size = CGSize(width: 1920, height: 1200)
  private var display: CGVirtualDisplay?
  private var viewer: NSWindow?
  private var stream: SCStream?
  var onProblem: (String) -> Void = { _ in }
  var onShown: () -> Void = {}

  var exists: Bool { display != nil }
  /// As the Spaces lists name the display.
  var uuid: String? {
    (display?.displayID).flatMap { CGDisplayCreateUUIDFromDisplayID($0)?.takeRetainedValue() }.map { CFUUIDCreateString(nil, $0) as String }
  }
  var screen: NSScreen? { NSScreen.screens.first { $0.localizedName == AgentScreen.name } }

  /// False if macOS would not make the display. The screen list catches up a moment later.
  @discardableResult func create() -> Bool {
    guard display == nil else { return true }
    let d = CGVirtualDisplayDescriptor()
    d.queue = .main
    d.name = AgentScreen.name
    d.maxPixelsWide = UInt(AgentScreen.size.width * 2)
    d.maxPixelsHigh = UInt(AgentScreen.size.height * 2)
    d.sizeInMillimeters = CGSize(width: 410, height: 256)
    (d.productID, d.vendorID, d.serialNum) = (0x7265, 0x6A67, 1)
    let settings = CGVirtualDisplaySettings()
    settings.hiDPI = 1
    settings.modes = [
      CGVirtualDisplayMode(width: UInt(AgentScreen.size.width), height: UInt(AgentScreen.size.height), refreshRate: 60)
    ]
    // the first try after launch has been seen to fail where the second succeeds
    guard let made = [0, 1].lazy.compactMap({ _ in CGVirtualDisplay(descriptor: d).flatMap { $0.apply(settings) ? $0 : nil } }).first
    else { return false }
    display = made
    // macOS first puts a new display beside the main one, where the pointer could stray onto it
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.tuckAway() }
    return true
  }

  /// Moves the display so it touches the real ones only at their bottom-right corner.
  private func tuckAway() {
    guard let id = display?.displayID else { return }
    var count: UInt32 = 0
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    CGGetActiveDisplayList(16, &ids, &count)
    let others = ids.prefix(Int(count)).filter { $0 != id }.map(CGDisplayBounds)
    var config: CGDisplayConfigRef?
    guard let x = others.map(\.maxX).max(), let y = others.map(\.maxY).max(), CGBeginDisplayConfiguration(&config) == .success
    else { return }
    CGConfigureDisplayOrigin(config, id, Int32(x), Int32(y))
    CGCompleteDisplayConfiguration(config, .forSession)
  }

  func remove() {
    viewer?.close()
    display = nil  // macOS moves anything left on it back to a real display
  }

  /// The viewer: the agent screen, live, in a window. Needs Screen Recording permission.
  func show() {
    if let viewer {
      NSApp.activate(ignoringOtherApps: true)
      return viewer.makeKeyAndOrderFront(nil)
    }
    guard let id = display?.displayID else { return }
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, _ in
      DispatchQueue.main.async {
        guard let target = content?.displays.first(where: { $0.displayID == id }) else {
          NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
          return self.onProblem("to show the agent screen, allow Rejig under Screen & System Audio Recording, then try again")
        }
        let config = SCStreamConfiguration()
        (config.width, config.height) = (Int(AgentScreen.size.width), Int(AgentScreen.size.height))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        let stream = SCStream(filter: SCContentFilter(display: target, excludingWindows: []), configuration: config, delegate: nil)
        try? stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
        stream.startCapture { _ in }
        self.stream = stream

        let w = NSWindow(
          contentRect: CGRect(x: 0, y: 0, width: 960, height: 600),
          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Agent Screen"
        w.contentAspectRatio = AgentScreen.size
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView?.wantsLayer = true
        w.contentView?.layer?.backgroundColor = .black
        w.contentView?.layer?.contentsGravity = .resizeAspect
        w.center()
        self.viewer = w
        self.onShown()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
      }
    }
  }

  func windowWillClose(_: Notification) {
    stream?.stopCapture { _ in }
    stream = nil
    viewer = nil
  }

  func stream(_: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of _: SCStreamOutputType) {
    // frames with nothing new carry no image
    guard let image = sample.imageBuffer, let surface = CVPixelBufferGetIOSurface(image)?.takeUnretainedValue() else { return }
    DispatchQueue.main.async { self.viewer?.contentView?.layer?.contents = surface }
  }
}
