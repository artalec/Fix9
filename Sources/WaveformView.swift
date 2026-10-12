// DJPLAYER-BUILD: v4 (2026-10-12)
import SwiftUI
import AppKit

/// Waveform трека: клик для перемотки, перетаскиваемые маркеры Start Time / End Time.
///
/// Рисуется через Canvas, а не через HStack из ~900 прямоугольников.
/// Это главная причина, почему waveform «подтормаживал»: SwiftUI создавал
/// сотни отдельных View и пересчитывал layout на каждом кадре таймера.
/// Canvas рисует всё одним проходом.
struct WaveformView: View {

    let peaks: [Float]
    let currentTime: TimeInterval
    let duration: TimeInterval
    let accent: RGBAColor

    let trimStart: TimeInterval
    let trimEnd: TimeInterval?

    let onSeek: (TimeInterval, Bool) -> Void
    let onTrimChanged: (TimeInterval, TimeInterval?) -> Void

    @State private var draggingHandle: Handle?
    @State private var dragStartValues: (start: TimeInterval, end: TimeInterval) = (0, 0)

    private enum Handle { case start, end }

    private let handleWidth: CGFloat = 13
    private let handleHitArea: CGFloat = 20

    private var safeDuration: TimeInterval { max(duration, 0.001) }

    private var effectiveTrimEnd: TimeInterval {
        trimEnd ?? duration
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height

            ZStack(alignment: .leading) {
                Canvas { context, size in
                    draw(in: &context, size: size)
                }
                .contentShape(Rectangle())
                .gesture(seekGesture(width: width))

                if duration > 0 {
                    handleView(.start, width: width, height: height)
                    handleView(.end, width: width, height: height)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            )
        }
    }

    // MARK: - Отрисовка

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let width = size.width
        let height = size.height
        guard width > 0, height > 0 else { return }

        // Фон
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.black.opacity(0.16)))

        guard duration > 0 else {
            drawCenteredText("Выберите трек", in: &context, size: size)
            return
        }

        guard !peaks.isEmpty else {
            drawCenteredText("Считаю waveform…", in: &context, size: size)
            return
        }

        let barWidth: CGFloat = 2
        let barSpacing: CGFloat = 1
        let slot = barWidth + barSpacing
        let barCount = max(1, Int(width / slot))
        let values = downsample(peaks, to: barCount)

        let startRatio = CGFloat(min(max(trimStart / safeDuration, 0), 1))
        let endRatio = CGFloat(min(max(effectiveTrimEnd / safeDuration, 0), 1))
        let playedRatio = CGFloat(min(max((trimStart + currentTime) / safeDuration, 0), 1))

        let midY = height / 2
        let maxHalf = (height - 18) / 2

        // Полупрозрачные зоны слева и справа от сегмента
        if startRatio > 0 {
            context.fill(
                Path(CGRect(x: 0, y: 0, width: width * startRatio, height: height)),
                with: .color(Color.black.opacity(0.38))
            )
        }
        if endRatio < 1 {
            let x = width * endRatio
            context.fill(
                Path(CGRect(x: x, y: 0, width: width - x, height: height)),
                with: .color(Color.black.opacity(0.38))
            )
        }

        // Столбики
        let accentColor = accent.swiftUIColor
        for (index, value) in values.enumerated() {
            let ratio = CGFloat(index) / CGFloat(max(1, values.count - 1))
            let inSegment = ratio >= startRatio && ratio <= endRatio
            let played = ratio <= playedRatio

            let barHeight = max(2, CGFloat(value) * maxHalf * 2)
            let rect = CGRect(
                x: CGFloat(index) * slot,
                y: midY - barHeight / 2,
                width: barWidth,
                height: barHeight
            )

            let color: Color
            if !inSegment {
                color = Color.secondary.opacity(0.22)
            } else if played {
                color = accentColor
            } else {
                color = Color.secondary.opacity(0.5)
            }

            context.fill(Path(rect), with: .color(color))
        }

        // Осевая линия
        context.stroke(
            Path { path in
                path.move(to: CGPoint(x: 0, y: midY))
                path.addLine(to: CGPoint(x: width, y: midY))
            },
            with: .color(Color.secondary.opacity(0.2)),
            lineWidth: 0.5
        )

        // Курсор воспроизведения
        let cursorX = width * playedRatio
        context.fill(
            Path(CGRect(x: cursorX - 1, y: 0, width: 2, height: height)),
            with: .color(Color.red.opacity(0.85))
        )
    }

    private func drawCenteredText(_ text: String, in context: inout GraphicsContext, size: CGSize) {
        let resolved = context.resolve(
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        )
        context.draw(resolved, at: CGPoint(x: size.width / 2, y: size.height / 2), anchor: .center)
    }

    private func downsample(_ source: [Float], to count: Int) -> [Float] {
        guard !source.isEmpty, count > 0 else { return [] }
        if source.count == count { return source }

        var result: [Float] = []
        result.reserveCapacity(count)
        let ratio = Double(source.count) / Double(count)

        for i in 0..<count {
            let start = Int(Double(i) * ratio)
            let end = min(source.count, max(start + 1, Int(Double(i + 1) * ratio)))
            var peak: Float = 0
            for j in start..<end { peak = max(peak, source[j]) }
            result.append(peak)
        }
        return result
    }

    // MARK: - Геометрия

    private func fileTime(forX x: CGFloat, width: CGFloat) -> TimeInterval {
        guard width > 0 else { return 0 }
        return Double(min(max(x / width, 0), 1)) * safeDuration
    }

    // MARK: - Перемотка

    private func seekGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard draggingHandle == nil, duration > 0 else { return }
                // Клик без движения — только перемотка, протягивание — ещё и запуск.
                let moved = abs(value.location.x - value.startLocation.x) > 3
                let absolute = fileTime(forX: value.location.x, width: width)
                let relative = absolute - trimStart
                let upper = max(0, effectiveTrimEnd - trimStart)
                onSeek(max(0, min(relative, upper)), moved)
            }
    }

    // MARK: - Маркеры обрезки

    private func handleView(_ handle: Handle, width: CGFloat, height: CGFloat) -> some View {
        let time = handle == .start ? trimStart : effectiveTrimEnd
        let x = width * CGFloat(min(max(time / safeDuration, 0), 1))
        let isStart = handle == .start

        return ZStack {
            Rectangle()
                .fill(Color.gray.opacity(0.85))
                .frame(width: 1.5, height: height)

            Triangle()
                .fill(Color.gray)
                .overlay(
                    Triangle().stroke(Color.black.opacity(0.45), lineWidth: 1)
                )
                .frame(width: handleWidth, height: 9)
                .scaleEffect(y: isStart ? 1 : -1)
                .offset(y: isStart ? -height / 2 + 6 : height / 2 - 6)
        }
        .frame(width: handleHitArea, height: height)
        .contentShape(Rectangle())
        .offset(x: x - handleHitArea / 2)
        .help(isStart ? "Start Time — потяните, чтобы задать начало" : "End Time — потяните, чтобы задать конец")
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if draggingHandle == nil {
                        draggingHandle = handle
                        dragStartValues = (trimStart, effectiveTrimEnd)
                    }
                    let newAbsolute = fileTime(forX: value.location.x, width: width)

                    if isStart {
                        let upper = dragStartValues.end
                        let clamped = max(0, min(newAbsolute, upper - 0.2))
                        onTrimChanged(clamped, dragStartValues.end)
                    } else {
                        let lower = dragStartValues.start
                        let clamped = min(safeDuration, max(newAbsolute, lower + 0.2))
                        // Если маркер у самого конца — считаем это «без обрезки»
                        onTrimChanged(dragStartValues.start, clamped)
                    }
                }
                .onEnded { _ in
                    draggingHandle = nil
                }
        )
    }
}

/// Треугольник для маркеров обрезки.
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
