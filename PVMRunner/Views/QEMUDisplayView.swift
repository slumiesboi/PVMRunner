import AppKit
import SwiftUI

/// Shows a QEMU guest's screen (over VNC) inside the VM window and forwards keyboard and
/// mouse input. The guest draws its own pointer, so the Mac pointer is hidden over the screen.
struct QEMUDisplayView: NSViewRepresentable {
    let socketPath: String
    /// virtio-gpu's screen when the guest has ramfb too (see `QEMUDisplay`).
    var gpuSocketPath: String?

    func makeNSView(context: Context) -> QEMUScreenView {
        let view = QEMUScreenView(socketPath: socketPath, gpuSocketPath: gpuSocketPath)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: QEMUScreenView, context: Context) {}

    static func dismantleNSView(_ view: QEMUScreenView, coordinator: ()) {
        view.disconnect()
    }
}

/// With two screens (ramfb and virtio-gpu) it shows virtio-gpu whenever Windows draws on it,
/// and ramfb otherwise: during Setup, and while Windows starts before its display driver loads.
final class QEMUScreenView: NSView {
    private let primary: RFBClient
    private let gpu: RFBClient?
    private var primaryImage: CGImage?
    private var gpuImage: CGImage?
    private(set) var showsGPU = false
    private var client: RFBClient { showsGPU ? gpu ?? primary : primary }
    private var image: CGImage? { showsGPU ? gpuImage : primaryImage }
    private var buttons: UInt8 = 0
    private var pressedScancodes = Set<UInt32>()
    private var scrollRemainder = CGSize.zero
    private static let hiddenCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    init(socketPath: String, gpuSocketPath: String? = nil) {
        primary = RFBClient(socketPath: socketPath)
        gpu = gpuSocketPath.map(RFBClient.init(socketPath:))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        primary.onFrame = { [weak self] image in
            guard let self else { return }
            primaryImage = image
            if !showsGPU { needsDisplay = true }
        }
        gpu?.onFrame = { [weak self] image in
            guard let self else { return }
            gpuImage = image
            show(gpu: !Self.isBlank(image))
            if showsGPU { needsDisplay = true }
        }
        primary.start()
        gpu?.start()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func disconnect() {
        primary.stop()
        gpu?.stop()
    }

    private func show(gpu: Bool) {
        guard gpu != showsGPU else { return }
        releaseInput()
        showsGPU = gpu
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// True for an all-black screen, such as QEMU's "Display output is not active" placeholder
    /// on a virtio-gpu the guest isn't using. Samples a 64 × 36 grid.
    static func isBlank(_ image: CGImage) -> Bool {
        let width = 64, height = 36
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var dark = 0
        for offset in stride(from: 0, to: pixels.count, by: 4)
        where pixels[offset] < 16 && pixels[offset + 1] < 16 && pixels[offset + 2] < 16 {
            dark += 1
        }
        return dark * 100 >= width * height * 97
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    // MARK: Drawing

    /// The guest screen scaled to fit the view, centred, keeping its aspect ratio.
    private var screenRect: CGRect {
        guard let image else { return .zero }
        let size = CGSize(width: image.width, height: image.height)
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: (bounds.width - fitted.width) / 2, y: (bounds.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = screenRect
        context.saveGState()
        // CGContext draws images bottom-up; undo the view's flipped coordinates.
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = rect.width < CGFloat(image.width) ? .high : .medium
        context.draw(image, in: CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height))
        context.restoreGState()
    }

    override func resetCursorRects() {
        addCursorRect(screenRect, cursor: Self.hiddenCursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Mouse

    private func sendPointer(_ event: NSEvent, extraButtons: UInt8 = 0) {
        let rect = screenRect
        guard rect.width > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let size = client.framebufferSize
        let x = Int((point.x - rect.minX) / rect.width * size.width)
        let y = Int((point.y - rect.minY) / rect.height * size.height)
        client.sendPointer(x: x, y: y, buttons: buttons | extraButtons)
    }

    override func mouseMoved(with event: NSEvent) { sendPointer(event) }
    override func mouseDragged(with event: NSEvent) { sendPointer(event) }
    override func rightMouseDragged(with event: NSEvent) { sendPointer(event) }
    override func otherMouseDragged(with event: NSEvent) { sendPointer(event) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        buttons |= 1; sendPointer(event)
    }
    override func mouseUp(with event: NSEvent) { buttons &= ~1; sendPointer(event) }
    override func rightMouseDown(with event: NSEvent) { buttons |= 4; sendPointer(event) }
    override func rightMouseUp(with event: NSEvent) { buttons &= ~4; sendPointer(event) }
    override func otherMouseDown(with event: NSEvent) { buttons |= 2; sendPointer(event) }
    override func otherMouseUp(with event: NSEvent) { buttons &= ~2; sendPointer(event) }

    override func scrollWheel(with event: NSEvent) {
        // Trackpads report fine-grained deltas; send one wheel click per 10 points.
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 10 : 1
        scrollRemainder.height += event.scrollingDeltaY
        scrollRemainder.width += event.scrollingDeltaX
        while abs(scrollRemainder.height) >= step {
            let up = scrollRemainder.height > 0
            sendPointer(event, extraButtons: up ? 8 : 16)
            sendPointer(event)
            scrollRemainder.height += up ? -step : step
        }
        while abs(scrollRemainder.width) >= step {
            let left = scrollRemainder.width > 0
            sendPointer(event, extraButtons: left ? 32 : 64)
            sendPointer(event)
            scrollRemainder.width += left ? -step : step
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let code = Scancodes.map[event.keyCode] else { return }
        pressedScancodes.insert(code)
        client.sendKey(scancode: code, down: true)
    }

    override func keyUp(with event: NSEvent) {
        guard let code = Scancodes.map[event.keyCode] else { return }
        pressedScancodes.remove(code)
        client.sendKey(scancode: code, down: false)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let code = Scancodes.map[event.keyCode] else { return }
        if event.keyCode == 0x39 {
            // Caps Lock reports state changes, not presses: tap it.
            client.sendKey(scancode: code, down: true)
            client.sendKey(scancode: code, down: false)
            return
        }
        let down = !pressedScancodes.contains(code)
        if down { pressedScancodes.insert(code) } else { pressedScancodes.remove(code) }
        client.sendKey(scancode: code, down: down)
    }

    /// Lets ⌘-shortcuts reach the guest (⌘ is the Windows key) instead of the app's menus,
    /// except ⌘Q and ⌘W so the app and window can still be closed.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return false }
        if event.modifierFlags.contains(.command),
           let key = event.charactersIgnoringModifiers?.lowercased(), key == "q" || key == "w" {
            return false
        }
        keyDown(with: event)
        return true
    }

    override func resignFirstResponder() -> Bool {
        releaseInput()
        return super.resignFirstResponder()
    }

    /// Releases anything still held so the guest doesn't see a stuck key or button.
    private func releaseInput() {
        for code in pressedScancodes { client.sendKey(scancode: code, down: false) }
        pressedScancodes.removeAll()
        if buttons != 0 {
            buttons = 0
            client.sendPointer(x: 0, y: 0, buttons: 0)
        }
    }
}

/// macOS virtual key codes → PC set 1 scancodes in QEMU's "qnum" form (E0-prefixed keys are
/// 0x80 | code). Positions follow the physical key, so the guest's layout setting applies.
enum Scancodes {
    static let map: [UInt16: UInt32] = [
        0x00: 0x1E, 0x01: 0x1F, 0x02: 0x20, 0x03: 0x21, 0x04: 0x23, 0x05: 0x22, 0x06: 0x2C, 0x07: 0x2D,
        0x08: 0x2E, 0x09: 0x2F, 0x0A: 0x56, 0x0B: 0x30, 0x0C: 0x10, 0x0D: 0x11, 0x0E: 0x12, 0x0F: 0x13,
        0x10: 0x15, 0x11: 0x14, 0x12: 0x02, 0x13: 0x03, 0x14: 0x04, 0x15: 0x05, 0x16: 0x07, 0x17: 0x06,
        0x18: 0x0D, 0x19: 0x0A, 0x1A: 0x08, 0x1B: 0x0C, 0x1C: 0x09, 0x1D: 0x0B, 0x1E: 0x1B, 0x1F: 0x18,
        0x20: 0x16, 0x21: 0x1A, 0x22: 0x17, 0x23: 0x19, 0x24: 0x1C, 0x25: 0x26, 0x26: 0x24, 0x27: 0x28,
        0x28: 0x25, 0x29: 0x27, 0x2A: 0x2B, 0x2B: 0x33, 0x2C: 0x35, 0x2D: 0x31, 0x2E: 0x32, 0x2F: 0x34,
        0x30: 0x0F, 0x31: 0x39, 0x32: 0x29, 0x33: 0x0E, 0x35: 0x01,
        // Modifiers: ⌘ → Windows key, ⌥ → Alt.
        0x36: 0xDC, 0x37: 0xDB, 0x38: 0x2A, 0x39: 0x3A, 0x3A: 0x38, 0x3B: 0x1D, 0x3C: 0x36, 0x3D: 0xB8, 0x3E: 0x9D,
        // Keypad
        0x41: 0x53, 0x43: 0x37, 0x45: 0x4E, 0x47: 0x45, 0x4B: 0xB5, 0x4C: 0x9C, 0x4E: 0x4A, 0x51: 0x0D,
        0x52: 0x52, 0x53: 0x4F, 0x54: 0x50, 0x55: 0x51, 0x56: 0x4B, 0x57: 0x4C, 0x58: 0x4D, 0x59: 0x47,
        0x5B: 0x48, 0x5C: 0x49,
        // Function and navigation keys
        0x60: 0x3F, 0x61: 0x40, 0x62: 0x41, 0x63: 0x3D, 0x64: 0x42, 0x65: 0x43, 0x67: 0x57, 0x6D: 0x44,
        0x6F: 0x58, 0x72: 0xD2, 0x73: 0xC7, 0x74: 0xC9, 0x75: 0xD3, 0x76: 0x3E, 0x77: 0xCF, 0x78: 0x3C,
        0x79: 0xD1, 0x7A: 0x3B, 0x7B: 0xCB, 0x7C: 0xCD, 0x7D: 0xD0, 0x7E: 0xC8,
    ]
}
