// SPDX-License-Identifier: GPL-3.0-or-later
// HeroSceneView.swift — The live, touchable microphone: SceneKit inside SwiftUI.

import SceneKit
import SwiftUI

/// Drives the microphone's animations. Owned by the screen that shows the mic.
final class MicController: ObservableObject {
    fileprivate var nodes: MicModel.Nodes?
    fileprivate var turntable: SCNNode?
    private(set) var isListening = false
    private var themeID: String?
    private var lampColor = NSColor.red

    private var levelSmoothed: CGFloat = 0

    func attach(_ nodes: MicModel.Nodes, turntable: SCNNode) {
        let wasListening = isListening
        self.nodes = nodes
        self.turntable = turntable
        themeID = nil
        isListening = false
        if wasListening { setListening(true, breathe: false) }
    }

    /// Recording: the lamp glows in the accent color and the head breathes
    /// (or, with `breathe: false`, swells with the audio level from `setLevel`).
    func setListening(_ on: Bool, breathe: Bool = true) {
        guard let nodes, on != isListening else { return }
        isListening = on
        levelSmoothed = 0
        nodes.head.removeAction(forKey: "breathe")
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.25
        nodes.lampMaterial.emission.contents = on ? lampColor : NSColor.black
        SCNTransaction.commit()
        if on && !breathe {
            return
        }
        if on {
            let grow = SCNAction.scale(to: 1.07, duration: 0.55)
            grow.timingMode = .easeInEaseOut
            let shrink = SCNAction.scale(to: 1.0, duration: 0.55)
            shrink.timingMode = .easeInEaseOut
            nodes.head.runAction(.repeatForever(.sequence([grow, shrink])), forKey: "breathe")
        } else {
            nodes.head.runAction(.scale(to: 1.0, duration: 0.2), forKey: "breathe")
        }
    }

    /// Audio-driven: the head grows with your voice. Call at the waveform rate (~30 Hz).
    func setLevel(_ level: CGFloat) {
        guard let head = nodes?.head, isListening else { return }
        levelSmoothed += (min(1, max(0, level)) - levelSmoothed) * 0.4
        let s = 1 + levelSmoothed * 0.32
        head.scale = SCNVector3(s, s, s)
    }

    /// Transcribing: the lamp blinks.
    func setThinking(_ on: Bool) {
        guard let nodes else { return }
        nodes.head.removeAction(forKey: "think")
        if on {
            let color = lampColor
            let lampOn = SCNAction.run { _ in nodes.lampMaterial.emission.contents = color }
            let lampOff = SCNAction.run { _ in nodes.lampMaterial.emission.contents = NSColor.black }
            nodes.head.runAction(.repeatForever(.sequence([lampOn, .wait(duration: 0.22), lampOff, .wait(duration: 0.22)])), forKey: "think")
        } else {
            nodes.lampMaterial.emission.contents = NSColor.black
        }
    }

    /// Quick "no": a side-to-side wobble, for errors.
    func shake() {
        guard let root = nodes?.root else { return }
        root.removeAction(forKey: "shake")
        let tilt = SCNAction.rotateBy(x: 0, y: 0, z: 0.14, duration: 0.05)
        root.runAction(.sequence([tilt, tilt.reversed(), tilt.reversed(), tilt, tilt, tilt.reversed(), tilt.reversed(), tilt]), forKey: "shake")
    }

    /// Small hop plus a squash, for "done".
    func bounce() {
        squash(amount: 0.06)
        guard let head = nodes?.head else { return }
        let up = SCNAction.moveBy(x: 0, y: 0.08, z: 0, duration: 0.07)
        up.timingMode = .easeOut
        let down = SCNAction.moveBy(x: 0, y: -0.08, z: 0, duration: 0.09)
        down.timingMode = .easeIn
        head.runAction(.sequence([up, down]), forKey: "hop")
    }

    /// The big moment: a full spin, a jump, a heavy landing with a clunk.
    func celebrate(completion: (() -> Void)? = nil) {
        guard let root = nodes?.root, let turntable else { completion?(); return }
        turntable.removeAllActions()
        let spin = SCNAction.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 0.6)
        spin.timingMode = .easeInEaseOut
        let up = SCNAction.moveBy(x: 0, y: 0.5, z: 0, duration: 0.3)
        up.timingMode = .easeOut
        let down = SCNAction.moveBy(x: 0, y: -0.5, z: 0, duration: 0.22)
        down.timingMode = .easeIn
        let land = SCNAction.run { _ in
            DispatchQueue.main.async {
                Feedback.clunk()
                self.squash(amount: 0.14)
                completion?()
            }
        }
        turntable.runAction(.sequence([spin, .run { node in node.eulerAngles.y = MicSceneView.restYaw }]))
        root.runAction(.sequence([up, down, land]), forKey: "jump")
    }

    /// Squash and stretch on the whole mic, springing back.
    private func squash(amount: CGFloat) {
        guard let body = nodes?.root else { return }
        body.removeAction(forKey: "squash")
        let squash = SCNAction.customAction(duration: 0.5) { node, elapsed in
            let t = elapsed / 0.5
            // Damped oscillation: hits hard, wobbles, settles.
            let s = amount * exp(-6 * t) * cos(18 * t)
            node.scale = SCNVector3(1 + s * 0.6, 1 - s, 1 + s * 0.6)
        }
        body.runAction(squash, forKey: "squash")
    }

    func apply(_ theme: Theme, animated: Bool = true) {
        guard let nodes, theme.id != themeID else { return }
        themeID = theme.id
        lampColor = theme.nsAccent
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 0.45 : 0
        nodes.headMaterial.diffuse.contents = theme.heroPrimary
        nodes.standMaterial.diffuse.contents = theme.heroSecondary
        if isListening { nodes.lampMaterial.emission.contents = lampColor }
        SCNTransaction.commit()
    }
}

/// The hero microphone: real 3D, lit, casting a soft shadow. Click it, or flick it to spin.
struct MicSceneView: NSViewRepresentable {
    @ObservedObject var controller: MicController
    var interactive = true
    /// Camera distance: smaller is a bigger mic.
    var zoom: CGFloat = 6.4
    /// A fixed style (the style picker's previews); nil follows the chosen style.
    var style: MicStyle?
    var onTap: (() -> Void)?
    @Environment(\.theme) private var theme
    @EnvironmentObject private var themes: ThemeStore

    private var effectiveStyle: MicStyle { style ?? themes.heroStyle }

    /// Resting angle: turned a little so it reads as a solid object.
    static let restYaw: CGFloat = -0.38

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 30
        view.isPlaying = true
        view.rendersContinuously = false

        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        MicModel.stage(in: scene)
        _ = MicModel.camera(in: scene, distance: zoom)

        let nodes = MicModel.make(style: effectiveStyle, head: theme.heroPrimary, stand: theme.heroSecondary)
        context.coordinator.builtStyle = effectiveStyle
        let turntable = SCNNode()
        turntable.eulerAngles = SCNVector3(0.05, Self.restYaw, 0)
        turntable.addChildNode(nodes.root)
        let bob = SCNNode()
        bob.addChildNode(turntable)
        scene.rootNode.addChildNode(bob)

        // Idle: a slow float, like it's hovering over the table.
        let up = SCNAction.moveBy(x: 0, y: 0.06, z: 0, duration: 1.8)
        up.timingMode = .easeInEaseOut
        bob.runAction(.repeatForever(.sequence([up, up.reversed()])))

        view.scene = scene
        controller.attach(nodes, turntable: turntable)
        controller.apply(theme, animated: false)

        if interactive {
            let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap))
            view.addGestureRecognizer(click)
            let pan = NSPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
            view.addGestureRecognizer(pan)
        }
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.builtStyle != effectiveStyle, let turntable = controller.turntable {
            // Swap the geometry in place; the turntable, bob and lights stay.
            turntable.childNodes.forEach { $0.removeFromParentNode() }
            let nodes = MicModel.make(style: effectiveStyle, head: theme.heroPrimary, stand: theme.heroSecondary)
            turntable.addChildNode(nodes.root)
            controller.attach(nodes, turntable: turntable)
            context.coordinator.builtStyle = effectiveStyle
            controller.apply(theme, animated: false)
            Feedback.pop()
            return
        }
        controller.apply(theme)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: MicSceneView
        var builtStyle: MicStyle?
        private var startYaw: CGFloat = 0
        private var lastDetentYaw: CGFloat = 0
        /// One click per this much rotation, like a dial.
        private let detent: CGFloat = 0.32

        init(_ parent: MicSceneView) { self.parent = parent }

        @objc func tap() {
            Feedback.thock()
            parent.onTap?()
        }

        @objc func pan(_ gesture: NSPanGestureRecognizer) {
            guard let turntable = parent.controller.turntable else { return }
            switch gesture.state {
            case .began:
                turntable.removeAllActions()
                startYaw = turntable.eulerAngles.y
                lastDetentYaw = startYaw
            case .changed:
                let yaw = startYaw + gesture.translation(in: gesture.view).x * 0.012
                turntable.eulerAngles.y = yaw
                if abs(yaw - lastDetentYaw) >= detent {
                    lastDetentYaw = yaw
                    Feedback.ratchet()
                }
            case .ended, .cancelled:
                let velocity = gesture.velocity(in: gesture.view).x
                let current = turntable.eulerAngles.y
                // A hard flick spins it all the way around before it settles back.
                let spins: CGFloat = abs(velocity) > 900 ? (velocity > 0 ? 1 : -1) * 2 * .pi : 0
                if spins != 0 { Feedback.whoosh() }
                let target = MicSceneView.restYaw + spins
                let detent = self.detent
                let lastTick = DetentTracker(current)
                let duration: CGFloat = spins == 0 ? 0.7 : 1.1
                let spin = SCNAction.customAction(duration: TimeInterval(duration)) { node, elapsed in
                    let t = elapsed / duration
                    // Ease out with a little overshoot.
                    let eased = 1 - pow(1 - t, 3) + sin(t * .pi) * 0.08
                    let yaw = current + (target - current) * eased
                    node.eulerAngles.y = yaw
                    // Clicks tick past as it spins, slowing down as it settles.
                    if lastTick.passed(yaw, detent: detent) {
                        DispatchQueue.main.async { Feedback.ratchet() }
                    }
                }
                turntable.runAction(.sequence([spin, .run { node in node.eulerAngles.y = MicSceneView.restYaw }]))
            default:
                break
            }
        }
    }
}

/// Rings that pulse out from the mic (used while listening and on the thank-you moment).
struct PulseRings: View {
    let trigger: Int
    var color: Color
    @State private var rings: [UUID] = []

    var body: some View {
        ZStack {
            ForEach(rings, id: \.self) { id in
                Ring(color: color) { rings.removeAll { $0 == id } }
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, _ in
            for delay in [0.0, 0.18, 0.36] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { rings.append(UUID()) }
            }
        }
    }

    private struct Ring: View {
        let color: Color
        let done: () -> Void
        @State private var expanded = false

        var body: some View {
            Circle()
                .stroke(color, lineWidth: expanded ? 1 : 6)
                .scaleEffect(expanded ? 1.5 : 0.35)
                .opacity(expanded ? 0 : 0.7)
                .onAppear {
                    withAnimation(.easeOut(duration: 1.0)) { expanded = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.05, execute: done)
                }
        }
    }
}

/// Remembers the last detent angle across SceneKit's per-frame action callbacks (render thread).
private final class DetentTracker: @unchecked Sendable {
    private var last: CGFloat
    private let lock = NSLock()
    init(_ start: CGFloat) { last = start }

    func passed(_ yaw: CGFloat, detent: CGFloat) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard abs(yaw - last) >= detent else { return false }
        last = yaw
        return true
    }
}
