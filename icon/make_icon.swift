// Renders the app icon: swift icon/make_icon.swift <output.png>
import AppKit
import SwiftUI

let copper = Color(red: 0.76, green: 0.52, blue: 0.33)
let ivory = Color(red: 0.95, green: 0.93, blue: 0.89)
let charcoal = Color(red: 0.13, green: 0.125, blue: 0.12)

struct FilmFrame: View {
    var body: some View {
        let size: CGFloat = 270, hole: CGFloat = 22, gap: CGFloat = 44
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous).fill(ivory)
            // The picture area, partly "rendered" from the top down.
            VStack(spacing: 0) {
                Rectangle().fill(copper).frame(height: 104)
                Rectangle().fill(charcoal)
            }
            .frame(width: 166, height: 166)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            ForEach(0..<5) { i in
                ForEach([-1.0, 1.0], id: \.self) { side in
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .frame(width: hole, height: hole)
                        .offset(x: side * (size / 2 - 26), y: CGFloat(i - 2) * gap)
                        .blendMode(.destinationOut)
                }
            }
        }
        .frame(width: size, height: size)
        .compositingGroup()
    }
}

struct Icon: View {
    var body: some View {
        let ring: CGFloat = 600, line: CGFloat = 34
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(charcoal)
                .overlay(
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .strokeBorder(ivory.opacity(0.08), lineWidth: 3)
                )
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.3), radius: 16, y: 8)

            Circle()
                .stroke(ivory.opacity(0.12), lineWidth: line)
                .frame(width: ring, height: ring)

            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(copper, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: ring, height: ring)

            FilmFrame()
        }
        .frame(width: 1024, height: 1024)
    }
}

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: Icon())
    renderer.scale = 1
    guard let cg = renderer.cgImage,
          let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
        fatalError("render failed")
    }
    try! png.write(to: URL(fileURLWithPath: output))
}
