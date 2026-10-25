import SwiftUI

enum CaptureMode: String, CaseIterable {
    case video = "视频"
    case photo = "拍照"
}

struct CameraShortcutMenu: View {
    let layout: CaptureLayout
    @Binding var gridEnabled: Bool
    let onSelectLayout: (CaptureLayout) -> Void
    let onWindowSettings: () -> Void
    let onSettings: () -> Void

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
        VStack(spacing: 12) {
            shortcut("网格", symbol: "grid", selected: gridEnabled) { gridEnabled.toggle() }
            shortcut("全屏", symbol: "viewfinder", selected: layout == .fullScreen) { onSelectLayout(.fullScreen) }
            shortcut("上下", symbol: "rectangle.split.1x2", selected: layout == .split) { onSelectLayout(.split) }
            shortcut("左右", symbol: "rectangle.split.2x1", selected: layout == .sideBySide) { onSelectLayout(.sideBySide) }
            shortcut("画中画", symbol: "pip", selected: layout == .pictureInPicture) { onSelectLayout(.pictureInPicture) }
            shortcut("小窗", symbol: "arrow.up.left.and.arrow.down.right", selected: false, action: onWindowSettings)
            Button(action: onSettings) {
                VStack(spacing: 3) {
                    ZStack {
                        Image(systemName: "hexagon").font(.system(size: 29, weight: .medium))
                        Circle().stroke(lineWidth: 2).frame(width: 10, height: 10)
                    }
                    .frame(height: 30)
                    Text("设置").font(.system(size: 11))
                }
                .frame(width: 48)
                .foregroundStyle(.white)
            }
            .accessibilityLabel("设置")
        }
        .padding(.vertical, 12)
        .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 24))
        .buttonStyle(.plain)
        }
        .frame(width: 48)
        .frame(maxHeight: 404)
    }

    private func shortcut(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 25, weight: .regular)).frame(height: 30)
                Text(title).font(.system(size: 11))
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
                Text("小窗").font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark.circle.fill").font(.title2) }
                    .accessibilityLabel("关闭小窗设置")
            }
            Picker("形状", selection: $shape) {
                ForEach(SmallWindowShape.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            HStack {
                Image(systemName: "minus.magnifyingglass")
                Slider(value: $scale, in: 0.6...1.8)
                    .accessibilityLabel("小窗大小")
                Image(systemName: "plus.magnifyingglass")
            }
            Text("按住小画面可拖动位置").font(.caption).foregroundStyle(.secondary)
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
