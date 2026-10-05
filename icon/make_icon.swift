// Renders the app icon: swift icon/make_icon.swift <output.png>
import AppKit
import SwiftUI

let orange = Color(red: 0.96, green: 0.47, blue: 0.16)
let amber = Color(red: 1.0, green: 0.73, blue: 0.22)
let navyTop = Color(red: 0.09, green: 0.09, blue: 0.25)
let navyBottom = Color(red: 0.16, green: 0.13, blue: 0.42)

struct FilmFrame: View {
    var body: some View {
        let size: CGFloat = 250, hole: CGFloat = 22, gap: CGFloat = 40
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous).fill(.white)
            // The picture area, partly "rendered" from the top down.
            ZStack(alignment: .top) {
                Rectangle().fill(navyTop.opacity(0.95))
                LinearGradient(colors: [amber, orange], startPoint: .top, endPoint: .bottom)
                    .frame(height: 96)
            }
            .frame(width: 150, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            ForEach(0..<5) { i in
                ForEach([-1.0, 1.0], id: \.self) { side in
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .frame(width: hole, height: hole)
                        .offset(x: side * (size / 2 - 25), y: CGFloat(i - 2) * gap)
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
        let ring: CGFloat = 560, line: CGFloat = 58
        let progress = 0.72
        let endAngle = Angle.degrees(360 * progress - 90)
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [navyTop, navyBottom], startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 4)
                )
                .overlay(
                    RadialGradient(colors: [orange.opacity(0.22), .clear], center: .center,
                                   startRadius: 0, endRadius: 420)
                )
                .clipShape(RoundedRectangle(cornerRadius: 185, style: .continuous))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 10)

            Circle()
                .stroke(.white.opacity(0.09), lineWidth: line)
                .frame(width: ring, height: ring)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    AngularGradient(colors: [orange, amber], center: .center,
                                    startAngle: .degrees(0), endAngle: .degrees(360 * progress)),
                    style: StrokeStyle(lineWidth: line, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: ring, height: ring)
                .shadow(color: orange.opacity(0.8), radius: 24)

            Circle()
                .fill(.white)
                .frame(width: 30, height: 30)
                .shadow(color: amber, radius: 14)
                .shadow(color: .white, radius: 4)
                .offset(x: cos(endAngle.radians) * ring / 2, y: sin(endAngle.radians) * ring / 2)

            FilmFrame()
                .scaleEffect(1.15)
                .shadow(color: .black.opacity(0.3), radius: 10, y: 6)
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
