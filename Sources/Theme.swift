// DJPLAYER-BUILD: v4 (2026-10-12)
import SwiftUI
import AppKit

extension RGBAColor {
    var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// Кружок нужного цвета для пункта меню.
    ///
    /// В меню macOS рисует изображение элемента, но игнорирует `.foregroundStyle`.
    /// Поэтому цветной кружок рисуем сразу как NSImage и помечаем как не-template.
    func swatchImage(diameter: CGFloat = 12) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size, flipped: false) { rect in
            let inset = rect.insetBy(dx: 0.5, dy: 0.5)
            NSColor(srgbRed: self.red, green: self.green, blue: self.blue, alpha: self.alpha).setFill()
            NSBezierPath(ovalIn: inset).fill()

            NSColor.black.withAlphaComponent(0.25).setStroke()
            let border = NSBezierPath(ovalIn: inset)
            border.lineWidth = 1
            border.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}

extension TimeInterval {
    var timecode: String {
        let total = Int(self)
        let seconds = total % 60
        let minutes = (total / 60) % 60
        let hours = total / 3600
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}
