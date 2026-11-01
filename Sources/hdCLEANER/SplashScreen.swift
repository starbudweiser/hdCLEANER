// Splash animé commun aux applis SwiftUI (règle Socle « Splash animé », modèle : le splash de mORTEX).
// Fichier autonome, à copier tel quel dans une autre appli Swift :
//   1. au lancement (applicationWillFinishLaunching, avant l'ouverture des fenêtres) : Splash.shared.start(Splash.Config(…))
//   2. sur la vue racine de la fenêtre principale : .splashGated()
// Chronologie : t = 0 splash visible → t = 2 s fenêtre de l'appli → t = 4 s sortie du splash (600 ms).
// Fenêtre pas prête à 2 s : elle s'ouvre dès qu'elle l'est et le splash l'attend avant de sortir.
// « Réduire les animations » (Réglages Système) : splash fixe, mêmes durées.
import AppKit
import SwiftUI

@MainActor
final class Splash {
    struct Config {
        /// Nom de l'appli ; ses `accentLetters` premières lettres prennent le dégradé d'accent.
        var title: String
        var accentLetters = 1
        /// Sous-titre court (déjà traduit), affiché en capitales espacées.
        var subtitle: String
        /// Mention discrète en bas à droite (version…), facultative.
        var footer = ""
        var icon: NSImage = NSApp.applicationIconImage
        /// Icône animée qui remplace `icon` (même cadre, même arrivée en tourbillon), facultative.
        var iconView: AnyView? = nil
        /// Couleur d'accent (aplat) : premières lettres du nom et filet.
        var accent = Color(red: 1, green: 0.369, blue: 0.039)
    }

    static let shared = Splash()

    #if HDCLEANER_SELFTEST
    /// Image fixe du splash (état final ou état de départ) pour les essais de rendu.
    static func previewView(_ config: Config, arrived: Bool) -> some View {
        let m = SplashModel()
        m.appeared = arrived
        m.reduceMotion = !arrived
        return SplashView(config: config, model: m)
    }
    #endif

    // Règle Socle : fenêtre de size-splash-width × size-splash-height (carte 476 × 166 et marge de 12 px).
    static let size = CGSize(width: 500, height: 190)
    static let openMainAfter: TimeInterval = 2
    static let minShown: TimeInterval = 4
    static let leaveDuration: TimeInterval = 0.6

    private var panel: NSPanel?
    private let model = SplashModel()
    private var shownAt = Date()
    private var mainOpenTime = false
    private var minShownReached = false
    private var mainShown = false
    private var leaving = false
    private var pending: NSWindow?
    private var gated = Set<ObjectIdentifier>()

    /// Trace la chronologie sur la sortie d'erreur si la variable SPLASH_TRACE est définie.
    private func trace(_ what: String) {
        guard ProcessInfo.processInfo.environment["SPLASH_TRACE"] != nil else { return }
        FileHandle.standardError.write(String(format: "splash %.3f s %@\n", Date().timeIntervalSince(shownAt), what).data(using: .utf8)!)
    }

    func start(_ config: Config) {
        guard panel == nil else { return }
        model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        // pas d'ombre native : sur une fenêtre transparente, macOS la dessine autour du cadre entier
        p.hasShadow = false
        p.isMovable = false
        p.level = .floating
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSHostingView(rootView: SplashView(config: config, model: model))
        host.frame = NSRect(origin: .zero, size: Self.size)
        p.contentView = host
        // centre exact de l'écran principal (NSWindow.center() place la fenêtre au tiers supérieur)
        if let sf = (NSScreen.main ?? NSScreen.screens.first)?.frame {
            p.setFrameOrigin(NSPoint(x: (sf.midX - Self.size.width / 2).rounded(), y: (sf.midY - Self.size.height / 2).rounded()))
        }
        p.orderFrontRegardless()
        panel = p
        shownAt = Date()
        model.appeared = true
        if let sf = (NSScreen.main ?? NSScreen.screens.first)?.frame {
            trace(String(format: "splash visible, écart au centre de l'écran : %.0f/%.0f px", p.frame.midX - sf.midX, p.frame.midY - sf.midY))
        }
        // fenêtre déjà créée (splash lancé tard) : retenue elle aussi
        for w in NSApp.windows where w !== p && w.canBecomeMain { gate(w) }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.openMainAfter) { [self] in
            mainOpenTime = true
            if let w = pending { reveal(w) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.minShown) { [self] in
            minShownReached = true
            leaveIfDone()
        }
        // garde-fou : sans fenêtre principale signalée, le splash ne reste pas indéfiniment
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [self] in
            mainShown = true
            leaveIfDone()
        }
    }

    /// Appelé quand la fenêtre principale reçoit sa vue (avant son affichage) : retenue jusqu'à t = 2 s.
    fileprivate func gate(_ window: NSWindow) {
        guard panel != nil, !mainShown, gated.insert(ObjectIdentifier(window)).inserted else { return }
        if mainOpenTime { reveal(window); return }
        trace("fenêtre prête, retenue (déjà visible : \(window.isVisible))")
        window.alphaValue = 0
        pending = window
    }

    private func reveal(_ window: NSWindow) {
        pending = nil
        window.alphaValue = 1
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel?.orderFrontRegardless()
        trace("fenêtre principale affichée")
        // le splash reste au moins un instant au-dessus d'une fenêtre ouverte tard
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            mainShown = true
            leaveIfDone()
        }
    }

    private func leaveIfDone() {
        guard minShownReached, mainShown, !leaving, panel != nil else { return }
        leaving = true
        trace("début de la sortie")
        model.leaving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.leaveDuration + 0.05) { [self] in
            panel?.orderOut(nil)
            panel = nil
            trace("splash fermé")
        }
    }
}

extension View {
    /// À poser sur la vue racine de la fenêtre principale : elle n'apparaît qu'à t = 2 s du splash.
    func splashGated() -> some View { background(SplashGate().frame(width: 0, height: 0)) }
}

private struct SplashGate: NSViewRepresentable {
    final class Probe: NSView {
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if let w = newWindow { MainActor.assumeIsolated { Splash.shared.gate(w) } }
        }
    }
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: Vue

@MainActor
final class SplashModel: ObservableObject {
    @Published var appeared = false
    @Published var leaving = false
    var reduceMotion = false
}

struct SplashView: View {
    let config: Splash.Config
    @ObservedObject var model: SplashModel

    private let card = CGSize(width: 476, height: 166)

    /// Animation après `delay` s, ou aucune si « réduire les animations » est actif.
    private func anim(_ a: Animation, _ delay: Double) -> Animation? {
        model.reduceMotion ? nil : a.delay(delay)
    }
    private static func curve(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ d: Double) -> Animation {
        .timingCurve(x1, y1, x2, y2, duration: d)
    }
    private var on: Bool { model.appeared || model.reduceMotion }

    var body: some View {
        ZStack {
            cardView
        }
        .frame(width: Splash.size.width, height: Splash.size.height)
        // sortie : zoom arrière avec léger rebond ; la carte ne dépasse jamais 104 % (≈ 491 px < 500 px de fenêtre)
        .scaleEffect(model.leaving && !model.reduceMotion ? 0.05 : 1)
        .animation(model.reduceMotion ? nil : Self.curve(0.6, -0.12, 0.735, 0.045, 0.6), value: model.leaving)
        .opacity(model.leaving ? 0 : 1)
        .animation(model.reduceMotion ? nil : .easeIn(duration: 0.18).delay(0.42), value: model.leaving)
    }

    private var cardView: some View {
        // carte plate (Socle « totalement plat ») : aplat et filet de 1 px, sans ombre, halo, flou ni dégradé
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return ZStack(alignment: .bottomTrailing) {
            HStack(spacing: 26) {
                icon
                text
            }
            // marge identique à gauche et à droite (Socle space-6), contenu centré
            .padding(.horizontal, pad)
            .frame(width: card.width, height: card.height)

            if !config.footer.isEmpty {
                Text(config.footer.uppercased())
                    .font(.system(size: 9.5, weight: .medium)).tracking(0.6)
                    .foregroundStyle(Color(white: 0.667))
                    .padding(.trailing, 18).padding(.bottom, 10)
            }
        }
        .frame(width: card.width, height: card.height)
        .background(shape.fill(Color(red: 0.106, green: 0.110, blue: 0.129)))
        .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }

    /// Icône de l'appli : arrivée en tourbillon.
    private var icon: some View {
        Group {
            if let v = config.iconView { v }
            else { Image(nsImage: config.icon).resizable().interpolation(.high) }
        }
            .frame(width: 108, height: 108)
            .rotationEffect(.degrees(on ? 0 : -420))
            .scaleEffect(on ? 1 : 0.2)
            .opacity(on ? 1 : 0)
            .animation(anim(Self.curve(0.22, 1, 0.36, 1, 1.3), 0), value: on)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(config.title.enumerated()), id: \.offset) { i, ch in
                    Text(String(ch)).font(.system(size: Self.titleSize, weight: .heavy)).tracking(0.5)
                        .foregroundStyle(i < config.accentLetters ? config.accent : .white)
                        .opacity(on ? 1 : 0)
                        .offset(y: on ? 0 : 14)
                        .rotation3DEffect(.degrees(on ? 0 : -95), axis: (1, 0, 0), anchor: UnitPoint(x: 0.5, y: 0.85), perspective: 0.6)
                        .animation(anim(Self.curve(0.2, 1.2, 0.4, 1, 0.7), 0.45 + Double(i) * 0.07), value: on)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(config.title)
            .lineLimit(1)

            Rectangle()
                .fill(config.accent)
                .frame(height: 2)
                .scaleEffect(x: on ? 1 : 0, anchor: .leading)
                .animation(anim(Self.curve(0.65, 0, 0.35, 1, 0.7), 0.95), value: on)
                .padding(.top, 10).padding(.bottom, 9)

            Text(config.subtitle.uppercased())
                .font(.system(size: subtitleSize, weight: .semibold)).tracking(4 * subtitleSize / 15)
                .foregroundStyle(Color(white: 0.847))
                .lineLimit(1)
                .opacity(on ? 1 : 0)
                .scaleEffect(x: on ? 1 : 1.25, anchor: .leading)
                .animation(anim(Self.curve(0.16, 1, 0.3, 1, 0.9), 1.1), value: on)
        }
        .fixedSize()
    }

    /// Marge intérieure de la carte, identique des deux côtés (Socle space-6).
    private let pad: CGFloat = 24
    /// Largeur utile du texte : carte − 2 marges − icône − écart.
    private var textWidth: CGFloat { card.width - 2 * pad - 108 - 26 }

    /// Nom de l'appli : taille fixe, identique dans toutes les applis (Socle size-splash-title, 40 px, graisse 800,
    /// interlettrage 0,5 px), prévue pour que le plus long nom tienne sans toucher le bord droit.
    private static let titleSize: CGFloat = 40

    /// Sous-titre : 15 pt, réduit seulement s'il ne tient pas sur une ligne dans la largeur utile.
    private var subtitleSize: CGFloat {
        let s = config.subtitle.uppercased(), tracking: CGFloat = 4
        let w = (s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold)]).width
            + tracking * CGFloat(s.count)
        return w <= textWidth ? 15 : floor(15 * textWidth / w * 10) / 10
    }
}
