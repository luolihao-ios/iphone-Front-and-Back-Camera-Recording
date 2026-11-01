import SwiftUI

enum CaptureMode: String, CaseIterable {
    case video
    case photo

    var title: String { L10n.string(self == .video ? "camera.video" : "camera.photo") }
}

struct CameraShortcutMenu: View {
    let layout: CaptureLayout
    @Binding var gridEnabled: Bool
    var maximumHeight: CGFloat = 442
    let onSelectLayout: (CaptureLayout) -> Void
    let onWindowSettings: () -> Void
    let onSettings: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {
                    shortcut(L10n.string("layout.grid"), symbol: "grid", selected: gridEnabled) { gridEnabled.toggle() }
                    shortcut(CaptureLayout.fullScreen.title, symbol: "viewfinder", selected: layout == .fullScreen) { onSelectLayout(.fullScreen) }
                    shortcut(CaptureLayout.split.title, symbol: "rectangle.split.1x2", selected: layout == .split) { onSelectLayout(.split) }
                    shortcut(CaptureLayout.sideBySide.title, symbol: "rectangle.split.2x1", selected: layout == .sideBySide) { onSelectLayout(.sideBySide) }
                    shortcut(CaptureLayout.pictureInPicture.title, symbol: "pip", selected: layout == .pictureInPicture) { onSelectLayout(.pictureInPicture) }
                    shortcut(L10n.string("window.shape"), symbol: "circle.square", selected: false, action: onWindowSettings)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: max(24, maximumHeight - 106))
            Button(action: onSettings) {
                VStack(spacing: 3) {
                    ZStack {
                        Image(systemName: "hexagon").font(.system(size: 29, weight: .medium))
                        Circle().stroke(lineWidth: 2).frame(width: 10, height: 10)
                    }
                    .frame(height: 30)
                    Text(L10n.string("settings.title")).font(.system(size: 11))
                }
                .frame(width: 48)
                .foregroundStyle(.white)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(L10n.string("settings.title"))
        }
        .padding(.vertical, 12)
        .frame(width: 48)
        .frame(maxHeight: maximumHeight)
        .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 24))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .buttonStyle(.plain)
    }

    private func shortcut(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 25, weight: .regular)).frame(height: 30)
                Text(title).font(.system(size: 11)).multilineTextAlignment(.center)
            }
            .foregroundStyle(selected ? .yellow : .white)
            .frame(width: 48)
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct SmallWindowPanel: View {
    @Binding var shape: String
    @Binding var scale: Double
    let close: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(L10n.string("window.shape")).font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark.circle.fill").font(.title2) }
                    .accessibilityLabel(L10n.string("window.shape.close"))
            }
            Picker(L10n.string("window.shape"), selection: $shape) {
                ForEach(SmallWindowShape.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            HStack {
                Image(systemName: "minus.magnifyingglass")
                Slider(value: $scale, in: 0.6...1.8)
                    .accessibilityLabel(L10n.string("window.size.accessibility"))
                Image(systemName: "plus.magnifyingglass")
            }
            Text(L10n.string("window.drag_hint")).font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .padding(.horizontal, 24)
    }
}

struct CompositionGrid: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                for part in 1...2 {
                    let x = proxy.size.width * CGFloat(part) / 3
                    let y = proxy.size.height * CGFloat(part) / 3
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                }
            }
            .stroke(.white.opacity(0.6), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
