import AppKit
import SwiftUI

/// Icône animée du splash : le plateau d'un disque dur qui tourne et son bras de lecture qui vient se poser.
/// Mêmes formes et mêmes couleurs que l'icône de l'appli (assets/make_icon.py), à plat (Socle : ni ombre ni dégradé).
struct DiskMark: View {
    /// Faux : plateau au repos et bras relevé ; vrai : plateau tourné d'un tour et bras posé.
    var on: Bool
    var animated = true

    private let tile = Color(red: 0.149, green: 0.157, blue: 0.173)
    private let platter = Color(red: 0.227, green: 0.239, blue: 0.263)
    private let ink = Color(red: 0.106, green: 0.114, blue: 0.129)
    private let paper = Color(red: 0.949, green: 0.949, blue: 0.949)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous).fill(tile)
            // plateau : disque, secteur libéré à la couleur du logo, deux pistes ; il fait un tour pendant l'arrivée
            ZStack {
                Circle().fill(platter)
                Sector(degrees: 115).fill(Brand.color)
                Circle().stroke(tile, lineWidth: 1.4).padding(12)
                Circle().stroke(tile, lineWidth: 1.4).padding(24)
                Circle().fill(ink).frame(width: 18, height: 18)
                Circle().fill(paper).frame(width: 8, height: 8)
            }
            .frame(width: 70, height: 70)
            .rotationEffect(.degrees(on ? 360 : 0))
            .animation(animated ? .timingCurve(0.22, 1, 0.36, 1, duration: 1.6).delay(0.2) : nil, value: on)
            // bras de lecture : pivote en bas à droite, passe de « relevé » à « posé sur le plateau »
            ZStack {
                Capsule().fill(paper).frame(width: 46, height: 6)
                Circle().fill(paper).frame(width: 14, height: 14).offset(x: 23)
            }
            .frame(width: 46, height: 6)
            .position(x: 88 - 23, y: 88)
            .rotationEffect(.degrees(on ? 45 : 82), anchor: UnitPoint(x: 1, y: 0.5))
            .animation(animated ? .timingCurve(0.22, 1, 0.36, 1, duration: 1.1).delay(0.9) : nil, value: on)
        }
        .frame(width: 108, height: 108)
    }
}

/// Part de disque partant du haut, dans le sens des aiguilles d'une montre.
struct Sector: Shape {
    var degrees: Double

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        p.move(to: c)
        p.addArc(center: c, radius: min(rect.width, rect.height) / 2, startAngle: .degrees(-90), endAngle: .degrees(-90 + degrees), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// Version qui s'anime d'elle-même à son apparition (celle que montre le splash).
struct AnimatedDiskMark: View {
    @State private var on = false
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var body: some View {
        DiskMark(on: on || reduceMotion, animated: !reduceMotion).onAppear { on = true }
    }
}

/// Filigrane du fond de la colonne de gauche : un plateau de disque dur très pâle, à demi sorti du cadre par le bas.
struct DiskWatermark: View {
    var body: some View {
        GeometryReader { geo in
            let d = max(geo.size.width * 1.7, 260)
            ZStack {
                Circle().fill(Color.white.opacity(0.025))
                Sector(degrees: 100).fill(Brand.color.opacity(0.075))
                ForEach([0.14, 0.27, 0.40, 0.53, 0.66], id: \.self) { inset in
                    Circle().stroke(Color.white.opacity(0.05), lineWidth: 1).padding(d * inset / 2)
                }
                Circle().fill(Color.white.opacity(0.04)).frame(width: d * 0.16, height: d * 0.16)
                Circle().stroke(Color.white.opacity(0.07), lineWidth: 1.5).frame(width: d * 0.16, height: d * 0.16)
                // bras de lecture
                Capsule().fill(Color.white.opacity(0.05)).frame(width: d * 0.50, height: 8)
                    .offset(x: d * 0.30, y: d * 0.20).rotationEffect(.degrees(-38))
            }
            .frame(width: d, height: d)
            .position(x: geo.size.width * 0.58, y: geo.size.height - d * 0.20)
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
