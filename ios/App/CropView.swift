import SwiftUI

struct CropRequest: Identifiable {
    let id = UUID()
    let picture: Picture
}

/// Picks the part of a picture to read (or continuous mode's area): drag the frame to move it, or its corners to
/// resize it. Shown in a NavigationStack.
struct CropView: View {
    let picture: Picture
    let title: String
    let action: String
    /// The part picked, normalized to the picture.
    let done: (CGRect) -> Void
    @Environment(\.dismiss) private var dismiss
    /// The part to read, normalized to the picture.
    @State private var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// The crop when the current drag started.
    @State private var dragStart: CGRect?
    private let image: UIImage

    init(picture: Picture, title: String = "Crop", action: String = "Read", initial: CGRect? = nil, done: @escaping (CGRect) -> Void) {
        self.picture = picture
        self.title = title
        self.action = action
        self.done = done
        image = UIImage(cgImage: picture.image)
        _crop = State(initialValue: initial ?? CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    var body: some View {
        GeometryReader { geometry in
            let frame = fitted(in: geometry.size)
            let box = CGRect(
                x: frame.minX + crop.minX * frame.width, y: frame.minY + crop.minY * frame.height,
                width: crop.width * frame.width, height: crop.height * frame.height
            )
            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                // Dims what's left out.
                Path { path in
                    path.addRect(frame)
                    path.addRect(box)
                }
                .fill(.black.opacity(0.5), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
                Rectangle()
                    .strokeBorder(.white, lineWidth: 2)
                    .contentShape(Rectangle())
                    .frame(width: box.width, height: box.height)
                    .offset(x: box.minX, y: box.minY)
                    .gesture(drag(in: frame) { start, x, y in start.offsetBy(dx: x, dy: y) })
                ForEach(Corner.allCases, id: \.self) { corner in
                    Circle()
                        .fill(.white)
                        .frame(width: 22, height: 22)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .offset(x: (corner.isLeft ? box.minX : box.maxX) - 22, y: (corner.isTop ? box.minY : box.maxY) - 22)
                        .gesture(drag(in: frame) { start, x, y in corner.resize(start, x: x, y: y) })
                }
            }
        }
        .background(Color.black)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(action) {
                    dismiss()
                    done(crop)
                }
            }
            ToolbarItem(placement: .bottomBar) {
                Button("Whole Picture") { crop = CGRect(x: 0, y: 0, width: 1, height: 1) }
                    .disabled(crop == CGRect(x: 0, y: 0, width: 1, height: 1))
            }
        }
    }

    /// The picture's frame, fitted in the view with a margin for the corners.
    private func fitted(in size: CGSize) -> CGRect {
        let available = CGRect(origin: .zero, size: size).insetBy(dx: 24, dy: 24)
        let scale = min(available.width / CGFloat(picture.image.width), available.height / CGFloat(picture.image.height))
        let width = CGFloat(picture.image.width) * scale
        let height = CGFloat(picture.image.height) * scale
        return CGRect(x: available.midX - width / 2, y: available.midY - height / 2, width: width, height: height)
    }

    /// Changes the crop by a drag, in the picture's fraction.
    private func drag(in frame: CGRect, _ change: @escaping (CGRect, CGFloat, CGFloat) -> CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = dragStart ?? crop
                dragStart = start
                let moved = change(start, value.translation.width / frame.width, value.translation.height / frame.height)
                crop = Self.clamped(moved, moving: moved.size == start.size)
            }
            .onEnded { _ in dragStart = nil }
    }

    /// Keeps the crop in the picture: a moved one by sliding it back, a resized one by cutting it (Corner.resize keeps
    /// it at least 4% of the picture each way).
    private static func clamped(_ rect: CGRect, moving: Bool) -> CGRect {
        guard moving else { return rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1)) }
        let x = min(max(rect.minX, 0), 1 - rect.width)
        let y = min(max(rect.minY, 0), 1 - rect.height)
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        var isLeft: Bool { self == .topLeft || self == .bottomLeft }
        var isTop: Bool { self == .topLeft || self == .topRight }

        /// The crop with this corner moved.
        func resize(_ rect: CGRect, x: CGFloat, y: CGFloat) -> CGRect {
            let left = isLeft ? min(rect.minX + x, rect.maxX - 0.04) : rect.minX
            let right = isLeft ? rect.maxX : max(rect.maxX + x, rect.minX + 0.04)
            let top = isTop ? min(rect.minY + y, rect.maxY - 0.04) : rect.minY
            let bottom = isTop ? rect.maxY : max(rect.maxY + y, rect.minY + 0.04)
            return CGRect(x: left, y: top, width: right - left, height: bottom - top)
        }
    }
}

extension Picture {
    /// The part of the picture, normalized to it.
    func cropped(to part: CGRect) -> Picture {
        guard part != CGRect(x: 0, y: 0, width: 1, height: 1) else { return self }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let pixels = CGRect(x: part.minX * width, y: part.minY * height, width: part.width * width, height: part.height * height).integral
        return image.cropping(to: pixels).map(Picture.init(image:)) ?? self
    }
}
