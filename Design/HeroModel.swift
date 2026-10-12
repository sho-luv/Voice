// SPDX-License-Identifier: GPL-3.0-or-later
// HeroModel.swift — The hero object: a chunky clay handheld microphone built from primitives.
//
// Shared by the app (live, animated, in MicSceneView) and tools/render_icons.swift
// (offscreen snapshot for the app icon). Keep this file free of SwiftUI.

import AppKit
import SceneKit

/// The four microphones. All share the materials, lights, camera and animations;
/// only the geometry differs. `head` is the part that swells with your voice.
enum MicStyle: String, CaseIterable, Identifiable {
    case stage, vintage, ribbon, podcast
    var id: String { rawValue }

    var name: String {
        switch self {
        case .stage: return "Stage"
        case .vintage: return "Vintage"
        case .ribbon: return "Ribbon"
        case .podcast: return "Podcast"
        }
    }

    var tagline: String {
        switch self {
        case .stage: return "Handheld, leaning in"
        case .vintage: return "Fifties slot grille"
        case .ribbon: return "Ring, spokes, copper"
        case .podcast: return "Foam, yoke, desk stand"
        }
    }
}

enum MicModel {
    /// Where the shadow floor sits; the base rests on it.
    static let floorY: CGFloat = -0.72

    static func make(style: MicStyle, head: NSColor, stand: NSColor) -> Nodes {
        // Styles with a designed render in the bundle show that image exactly; the
        // primitive builds below are the fallback (and what the icon tool uses).
        if let image = renderImage(for: style) {
            return makeImageMic(image, lamp: renderLamp[style] ?? CGPoint(x: 0.5, y: 0.5))
        }
        switch style {
        case .stage: return make(head: head, stand: stand)
        case .vintage: return makeVintage(head: head, stand: stand)
        case .ribbon: return makeRibbon(head: head, stand: stand)
        case .podcast: return makePodcast(head: head, stand: stand)
        }
    }

    // MARK: Designed renders (Resources/Mics/<style>.png, transparent, square)

    /// Where the red lamp dot sits in each render, as fractions of width and height from the top left.
    static let renderLamp: [MicStyle: CGPoint] = [
        .vintage: CGPoint(x: 0.465, y: 0.662),
        .podcast: CGPoint(x: 0.662, y: 0.345),
        .ribbon: CGPoint(x: 0.479, y: 0.291),
    ]

    private static var renderCache: [MicStyle: NSImage] = [:]

    static func renderImage(for style: MicStyle) -> NSImage? {
        if let cached = renderCache[style] { return cached }
        guard let url = Bundle.main.url(forResource: style.rawValue, withExtension: "png", subdirectory: "Mics"),
              let image = NSImage(contentsOf: url) else { return nil }
        renderCache[style] = image
        return image
    }

    /// The render on a camera-facing card, standing on the floor, with a glow over its lamp.
    /// The colours are baked into the image, so themes don't recolour it.
    static func makeImageMic(_ image: NSImage, lamp: CGPoint) -> Nodes {
        let root = SCNNode()
        let size: CGFloat = 2.3
        let card = SCNPlane(width: size, height: size)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = image
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        card.materials = [material]
        let head = SCNNode(geometry: card)
        head.castsShadow = false
        // The renders' bases end 8-14% above the image bottom; lift the card so the lowest
        // one clears the floor plane, which would otherwise clip it.
        head.position = SCNVector3(0, floorY + size * 0.45, 0)
        head.constraints = [SCNBillboardConstraint()]
        root.addChildNode(head)

        // Additive glow: black adds nothing, the accent colour lights the dot up.
        let lampMaterial = SCNMaterial()
        lampMaterial.lightingModel = .constant
        lampMaterial.diffuse.contents = NSColor.black
        lampMaterial.emission.contents = NSColor.black
        lampMaterial.transparent.contents = glowTile
        lampMaterial.blendMode = .add
        lampMaterial.writesToDepthBuffer = false
        let glow = SCNPlane(width: size * 0.09, height: size * 0.09)
        glow.materials = [lampMaterial]
        let glowNode = SCNNode(geometry: glow)
        glowNode.position = SCNVector3((lamp.x - 0.5) * size, (0.5 - lamp.y) * size, 0.01)
        glowNode.renderingOrder = 10
        head.addChildNode(glowNode)

        // Themes recolour these, but nothing draws with them.
        return Nodes(root: root, head: head, headMaterial: SCNMaterial(), standMaterial: SCNMaterial(), lampMaterial: lampMaterial)
    }

    /// Soft round falloff, white in the middle, for the lamp glow's alpha.
    static let glowTile: CGImage = {
        let size = 64
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
        let c = CGPoint(x: size / 2, y: size / 2)
        context.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(size) / 2, options: [])
        return context.makeImage()!
    }()

    struct Nodes {
        let root: SCNNode
        let head: SCNNode
        let headMaterial: SCNMaterial
        let standMaterial: SCNMaterial
        /// Small lamp on the base; glows while listening.
        let lampMaterial: SCNMaterial
    }

    /// Lean of the whole mic, so it reads as a handheld being held, not a thing on a stand.
    static let lean: CGFloat = -0.5

    static func make(head headColor: NSColor, stand standColor: NSColor) -> Nodes {
        let root = SCNNode()
        // Everything hangs off `body`, which leans; `root` stays upright for the
        // turntable spin and the squash-and-stretch.
        let body = SCNNode()
        body.eulerAngles = SCNVector3(0, 0, lean)
        body.position = SCNVector3(0.1, 0.25, 0)
        root.addChildNode(body)

        // Grille ball: clay diffuse modulated by a dot tile.
        let headMaterial = clay(headColor)
        headMaterial.multiply.contents = grilleTile
        headMaterial.multiply.wrapS = .repeat
        headMaterial.multiply.wrapT = .repeat
        headMaterial.multiply.contentsTransform = SCNMatrix4MakeScale(10, 5, 1)
        let sphere = SCNSphere(radius: 0.52)
        sphere.segmentCount = 64
        sphere.materials = [headMaterial]
        let head = SCNNode(geometry: sphere)
        head.position = SCNVector3(0, 0.78, 0)
        body.addChildNode(head)

        let standMaterial = clay(standColor, roughness: 0.8)

        // Collar between the ball and the handle.
        let collar = SCNCylinder(radius: 0.31, height: 0.16)
        collar.radialSegmentCount = 48
        collar.materials = [standMaterial]
        let collarNode = SCNNode(geometry: collar)
        collarNode.position = SCNVector3(0, 0.3, 0)
        body.addChildNode(collarNode)

        // Long tapered handle, slightly wider at the top.
        let handle = SCNCone(topRadius: 0.27, bottomRadius: 0.2, height: 1.45)
        handle.radialSegmentCount = 48
        handle.materials = [standMaterial]
        let handleNode = SCNNode(geometry: handle)
        handleNode.position = SCNVector3(0, -0.5, 0)
        body.addChildNode(handleNode)

        // Rounded butt so the handle doesn't end in a hard disc.
        let butt = SCNSphere(radius: 0.2)
        butt.segmentCount = 32
        butt.materials = [standMaterial]
        let buttNode = SCNNode(geometry: butt)
        buttNode.position = SCNVector3(0, -1.225, 0)
        body.addChildNode(buttNode)

        // Lamp: a bead on the front of the handle, just under the collar. Glows while listening.
        let lampMaterial = SCNMaterial()
        lampMaterial.lightingModel = .physicallyBased
        lampMaterial.diffuse.contents = NSColor(white: 0.12, alpha: 1)
        lampMaterial.roughness.contents = 0.35
        lampMaterial.emission.contents = NSColor.black
        let lamp = SCNSphere(radius: 0.055)
        lamp.materials = [lampMaterial]
        let lampNode = SCNNode(geometry: lamp)
        lampNode.position = SCNVector3(0, 0.05, 0.255)
        body.addChildNode(lampNode)

        return Nodes(root: root, head: head, headMaterial: headMaterial, standMaterial: standMaterial, lampMaterial: lampMaterial)
    }

    // MARK: Vintage (a fifties "55": tall rounded head, horizontal slats over a coloured mesh)

    static func makeVintage(head headColor: NSColor, stand standColor: NSColor) -> Nodes {
        let root = SCNNode()
        let body = SCNNode()
        body.eulerAngles = SCNVector3(-0.24, 0, 0) // tips back a little, like it's on a stand
        body.position = SCNVector3(0, 0.12, 0)
        root.addChildNode(body)

        // The head is a drum (the coloured mesh) under a chrome dome, with chrome ribs around
        // the front. The whole group is flattened front-to-back so it reads as the 55's pill shape.
        let headMaterial = clay(headColor, roughness: 0.85)
        headMaterial.multiply.contents = grilleTile
        headMaterial.multiply.wrapS = .repeat
        headMaterial.multiply.wrapT = .repeat
        headMaterial.multiply.contentsTransform = SCNMatrix4MakeScale(4, 4, 1)
        let standMaterial = clay(standColor, roughness: 0.55)
        let chrome = clay(standColor, roughness: 0.4)
        let drumRadius: CGFloat = 0.48
        let drumHeight: CGFloat = 1.0
        let head = SCNNode()
        head.position = SCNVector3(0, 0.5, 0)
        head.scale = SCNVector3(1, 1, 0.62)
        body.addChildNode(head)

        let drum = SCNCylinder(radius: drumRadius, height: drumHeight)
        drum.radialSegmentCount = 64
        drum.materials = [headMaterial]
        head.addChildNode(SCNNode(geometry: drum))
        let dome = SCNSphere(radius: drumRadius)
        dome.segmentCount = 48
        dome.materials = [chrome]
        let domeNode = SCNNode(geometry: dome)
        domeNode.position = SCNVector3(0, drumHeight / 2, 0)
        head.addChildNode(domeNode)

        // Horizontal slats wrap the drum and continue up over the dome, like a radiator grille,
        // with a vertical spine down the centre of the front.
        let slatPipe: CGFloat = 0.036
        var slatY: CGFloat = -drumHeight / 2 + 0.1
        while slatY <= drumHeight / 2 {
            let slat = SCNTorus(ringRadius: drumRadius + 0.015, pipeRadius: slatPipe)
            slat.ringSegmentCount = 64
            slat.materials = [chrome]
            let slatNode = SCNNode(geometry: slat)
            slatNode.position = SCNVector3(0, slatY, 0)
            head.addChildNode(slatNode)
            slatY += 0.14
        }
        for h: CGFloat in [0.13, 0.26, 0.37, 0.44] {
            let r = (drumRadius * drumRadius - h * h).squareRoot() + 0.01
            let slat = SCNTorus(ringRadius: r, pipeRadius: slatPipe)
            slat.ringSegmentCount = 64
            slat.materials = [chrome]
            let slatNode = SCNNode(geometry: slat)
            slatNode.position = SCNVector3(0, drumHeight / 2 + h, 0)
            head.addChildNode(slatNode)
        }
        let spine = SCNBox(width: 0.12, height: drumHeight + 0.1, length: 0.07, chamferRadius: 0.03)
        spine.materials = [chrome]
        let spineNode = SCNNode(geometry: spine)
        spineNode.position = SCNVector3(0, 0.05, drumRadius + 0.02)
        head.addChildNode(spineNode)
        let spineCap = SCNSphere(radius: 0.05)
        spineCap.materials = [chrome]
        let spineCapNode = SCNNode(geometry: spineCap)
        spineCapNode.position = SCNVector3(0, drumHeight / 2 + 0.12, drumRadius - 0.04)
        head.addChildNode(spineCapNode)

        // Solid band around the bottom of the head.
        let band = SCNCylinder(radius: drumRadius + 0.07, height: 0.2)
        band.radialSegmentCount = 64
        band.materials = [standMaterial]
        let bandNode = SCNNode(geometry: band)
        bandNode.position = SCNVector3(0, -drumHeight / 2 - 0.02, 0)
        head.addChildNode(bandNode)
        let headSize = (w: drumRadius * 2, h: drumHeight, d: drumRadius * 2 * 0.78)

        // Pivot: thumb screws on both sides of the band.
        for sign: CGFloat in [-1, 1] {
            let knob = SCNCylinder(radius: 0.1, height: 0.08)
            knob.radialSegmentCount = 24
            knob.materials = [standMaterial]
            let knobNode = SCNNode(geometry: knob)
            knobNode.eulerAngles = SCNVector3(0, 0, CGFloat.pi / 2)
            knobNode.position = SCNVector3(sign * (headSize.w / 2 + 0.1), -0.05, 0)
            body.addChildNode(knobNode)
        }

        // Hinge block under the head, a round neck with the lamp on its front, a thick base.
        let hinge = SCNBox(width: 0.4, height: 0.22, length: 0.3, chamferRadius: 0.06)
        hinge.materials = [standMaterial]
        let hingeNode = SCNNode(geometry: hinge)
        hingeNode.position = SCNVector3(0, -0.12, 0)
        root.addChildNode(hingeNode)
        let neckTop: CGFloat = -0.2
        let neck = SCNCylinder(radius: 0.22, height: neckTop - floorY - 0.12)
        neck.radialSegmentCount = 48
        neck.materials = [standMaterial]
        let neckNode = SCNNode(geometry: neck)
        neckNode.position = SCNVector3(0, (neckTop + floorY + 0.12) / 2, 0)
        root.addChildNode(neckNode)
        let baseRadius: CGFloat = 0.62
        let base = SCNCylinder(radius: baseRadius - 0.07, height: 0.16)
        base.radialSegmentCount = 64
        base.materials = [standMaterial]
        let baseNode = SCNNode(geometry: base)
        baseNode.position = SCNVector3(0, floorY + 0.08, 0)
        root.addChildNode(baseNode)
        let baseEdge = SCNTorus(ringRadius: baseRadius - 0.07, pipeRadius: 0.07)
        baseEdge.ringSegmentCount = 64
        baseEdge.materials = [standMaterial]
        let baseEdgeNode = SCNNode(geometry: baseEdge)
        baseEdgeNode.position = SCNVector3(0, floorY + 0.08, 0)
        root.addChildNode(baseEdgeNode)

        let lampMaterial = lamp()
        let lampNode = SCNNode(geometry: lampSphere(lampMaterial, radius: 0.04))
        lampNode.position = SCNVector3(0, -0.36, 0.215)
        root.addChildNode(lampNode)

        return Nodes(root: root, head: head, headMaterial: headMaterial, standMaterial: standMaterial, lampMaterial: lampMaterial)
    }

    // MARK: Ribbon (a ring with the capsule on spokes, over a copper body)

    static func makeRibbon(head headColor: NSColor, stand standColor: NSColor) -> Nodes {
        let root = SCNNode()
        let faceCamera = SCNVector3(CGFloat.pi / 2, 0, 0)
        let centerY: CGFloat = 0.5

        let standMaterial = clay(standColor, roughness: 0.55)
        let ring = SCNTorus(ringRadius: 0.8, pipeRadius: 0.05)
        ring.ringSegmentCount = 72
        ring.materials = [standMaterial]
        let ringNode = SCNNode(geometry: ring)
        ringNode.eulerAngles = faceCamera
        ringNode.position = SCNVector3(0, centerY, 0)
        root.addChildNode(ringNode)

        let headMaterial = clay(headColor, roughness: 0.7)
        headMaterial.multiply.contents = grilleTile
        headMaterial.multiply.wrapS = .repeat
        headMaterial.multiply.wrapT = .repeat
        headMaterial.multiply.contentsTransform = SCNMatrix4MakeScale(6, 6, 1)
        let capsule = SCNCylinder(radius: 0.34, height: 0.18)
        capsule.radialSegmentCount = 64
        capsule.materials = [headMaterial]
        let head = SCNNode(geometry: capsule)
        head.eulerAngles = faceCamera
        head.position = SCNVector3(0, centerY, 0)
        root.addChildNode(head)
        let rim = SCNTorus(ringRadius: 0.36, pipeRadius: 0.035)
        rim.materials = [standMaterial]
        let rimNode = SCNNode(geometry: rim)
        rimNode.eulerAngles = faceCamera
        rimNode.position = SCNVector3(0, centerY, 0)
        root.addChildNode(rimNode)

        // Four spokes from the capsule rim to the ring.
        for i in 0..<4 {
            let angle = CGFloat.pi / 4 + CGFloat(i) * CGFloat.pi / 2
            let spoke = SCNCylinder(radius: 0.025, height: 0.44)
            spoke.materials = [standMaterial]
            let spokeNode = SCNNode(geometry: spoke)
            spokeNode.position = SCNVector3(cos(angle) * 0.59, centerY + sin(angle) * 0.59, 0)
            spokeNode.eulerAngles = SCNVector3(0, 0, angle - CGFloat.pi / 2)
            root.addChildNode(spokeNode)
        }

        let stem = SCNCylinder(radius: 0.07, height: 0.24)
        stem.materials = [standMaterial]
        let stemNode = SCNNode(geometry: stem)
        stemNode.position = SCNVector3(0, centerY - 0.8 - 0.08, 0)
        root.addChildNode(stemNode)
        let bodyMaterial = clay(standColor, roughness: 0.5)
        let bodyCyl = SCNCylinder(radius: 0.17, height: 0.5)
        bodyCyl.radialSegmentCount = 48
        bodyCyl.materials = [bodyMaterial]
        let bodyNode = SCNNode(geometry: bodyCyl)
        bodyNode.position = SCNVector3(0, floorY + 0.25, 0)
        root.addChildNode(bodyNode)

        let lampMaterial = lamp()
        let lampNode = SCNNode(geometry: lampSphere(lampMaterial, radius: 0.045))
        lampNode.position = SCNVector3(0, floorY + 0.3, 0.17)
        root.addChildNode(lampNode)

        return Nodes(root: root, head: head, headMaterial: headMaterial, standMaterial: standMaterial, lampMaterial: lampMaterial)
    }

    // MARK: Podcast (a fat short body, foam over the top half, thin U-yoke, stubby stand; see reference/podcast.png)

    static func makePodcast(head headColor: NSColor, stand standColor: NSColor) -> Nodes {
        let root = SCNNode()
        // Leans to the right and a little away from the camera, so the flat bottom shows.
        let body = SCNNode()
        body.eulerAngles = SCNVector3(0.2, 0, -0.34)
        body.position = SCNVector3(0.1, 0.42, 0)
        root.addChildNode(body)

        let standMaterial = clay(standColor, roughness: 0.72)
        let bodyRadius: CGFloat = 0.36
        // Barrel with a soft flat bottom.
        let barrel = SCNCylinder(radius: bodyRadius, height: 0.72)
        barrel.radialSegmentCount = 64
        barrel.materials = [standMaterial]
        let barrelNode = SCNNode(geometry: barrel)
        barrelNode.position = SCNVector3(0, -0.3, 0)
        body.addChildNode(barrelNode)
        let bottomRim = SCNTorus(ringRadius: bodyRadius - 0.05, pipeRadius: 0.05)
        bottomRim.materials = [standMaterial]
        let bottomRimNode = SCNNode(geometry: bottomRim)
        bottomRimNode.position = SCNVector3(0, -0.66, 0)
        body.addChildNode(bottomRimNode)

        // Foam: a capsule a touch wider than the barrel, extra rough, strong felt normal.
        let headMaterial = clay(headColor, roughness: 1.0)
        headMaterial.normal.intensity = 1.1
        headMaterial.normal.contentsTransform = SCNMatrix4MakeScale(7, 7, 1)
        let foam = SCNCapsule(capRadius: bodyRadius + 0.025, height: 1.05)
        foam.capSegmentCount = 24
        foam.materials = [headMaterial]
        let head = SCNNode(geometry: foam)
        head.position = SCNVector3(0, 0.52, 0)
        body.addChildNode(head)

        // Seam line at the foam, and the lamp just under it on the front.
        let seam = SCNTorus(ringRadius: bodyRadius + 0.005, pipeRadius: 0.014)
        seam.materials = [standMaterial]
        let seamNode = SCNNode(geometry: seam)
        seamNode.position = SCNVector3(0, 0.06, 0)
        body.addChildNode(seamNode)
        let lampMaterial = lamp()
        let lampNode = SCNNode(geometry: lampSphere(lampMaterial, radius: 0.04))
        lampNode.position = SCNVector3(0, -0.03, bodyRadius - 0.005)
        body.addChildNode(lampNode)

        // Thumb knobs on the sides, and a thin round U-yoke that tilts with the body
        // and wraps under its bottom.
        let knobY: CGFloat = -0.3
        for sign: CGFloat in [-1, 1] {
            let knob = SCNCylinder(radius: 0.13, height: 0.11)
            knob.radialSegmentCount = 32
            knob.materials = [standMaterial]
            let knobNode = SCNNode(geometry: knob)
            knobNode.eulerAngles = SCNVector3(0, 0, CGFloat.pi / 2)
            knobNode.position = SCNVector3(sign * (bodyRadius + 0.1), knobY, 0)
            body.addChildNode(knobNode)
        }
        let yokeRadius: CGFloat = bodyRadius + 0.11
        let yokeCenterY: CGFloat = -0.3
        let yoke = SCNShape(path: uPath(outer: yokeRadius, inner: yokeRadius - 0.07, legHeight: knobY - yokeCenterY),
                            extrusionDepth: 0.07)
        yoke.chamferRadius = 0.03
        yoke.materials = [standMaterial]
        let yokeNode = SCNNode(geometry: yoke)
        yokeNode.position = SCNVector3(0, yokeCenterY, 0)
        body.addChildNode(yokeNode)

        // Stem drops straight down from the yoke's lowest point (in the upright frame);
        // thick disc base with a rounded edge.
        let yokeBottom = body.convertPosition(SCNVector3(0, yokeCenterY - yokeRadius + 0.03, 0), to: root)
        let stem = SCNCylinder(radius: 0.1, height: yokeBottom.y - floorY)
        stem.radialSegmentCount = 32
        stem.materials = [standMaterial]
        let stemNode = SCNNode(geometry: stem)
        stemNode.position = SCNVector3(yokeBottom.x, (yokeBottom.y + floorY) / 2, yokeBottom.z)
        root.addChildNode(stemNode)
        let baseRadius: CGFloat = 0.62
        let base = SCNCylinder(radius: baseRadius - 0.07, height: 0.16)
        base.radialSegmentCount = 64
        base.materials = [standMaterial]
        let baseNode = SCNNode(geometry: base)
        baseNode.position = SCNVector3(yokeBottom.x, floorY + 0.08, yokeBottom.z)
        root.addChildNode(baseNode)
        let baseEdge = SCNTorus(ringRadius: baseRadius - 0.07, pipeRadius: 0.07)
        baseEdge.ringSegmentCount = 64
        baseEdge.materials = [standMaterial]
        let baseEdgeNode = SCNNode(geometry: baseEdge)
        baseEdgeNode.position = SCNVector3(yokeBottom.x, floorY + 0.08, yokeBottom.z)
        root.addChildNode(baseEdgeNode)

        return Nodes(root: root, head: head, headMaterial: headMaterial, standMaterial: standMaterial, lampMaterial: lampMaterial)
    }

    // MARK: Shared parts

    /// A U-shaped bracket, open at the top, as a filled outline for extrusion (in the XY plane).
    static func uPath(outer R: CGFloat, inner r: CGFloat, legHeight L: CGFloat) -> NSBezierPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -R, y: L))
        path.addLine(to: CGPoint(x: -R, y: 0))
        path.addArc(center: .zero, radius: R, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
        path.addLine(to: CGPoint(x: R, y: L))
        path.addLine(to: CGPoint(x: r, y: L))
        path.addLine(to: CGPoint(x: r, y: 0))
        path.addArc(center: .zero, radius: r, startAngle: 2 * .pi, endAngle: .pi, clockwise: true)
        path.addLine(to: CGPoint(x: -r, y: L))
        path.closeSubpath()
        let bezier = NSBezierPath(cgPath: path)
        bezier.flatness = 0.004
        return bezier
    }

    static func lamp() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = NSColor(white: 0.12, alpha: 1)
        material.roughness.contents = 0.35
        material.emission.contents = NSColor.black
        return material
    }

    static func lampSphere(_ material: SCNMaterial, radius: CGFloat) -> SCNSphere {
        let sphere = SCNSphere(radius: radius)
        sphere.materials = [material]
        return sphere
    }

    /// Opaque vertical bars with transparent gaps: the chrome ribs of a fifties mic, as a cut-out.
    static let ribTile: CGImage = {
        let size = 128
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.clear(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        let pitch = 16
        for col in 0..<(size / pitch) {
            context.fill(CGRect(x: col * pitch + 4, y: 0, width: 8, height: size))
        }
        return context.makeImage()!
    }()

    /// White tile with dark horizontal bars: the slot grille of a fifties mic.
    static let slotTile: CGImage = {
        let size = 128
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(CGColor(gray: 0.22, alpha: 1))
        let pitch = 16
        for row in 0..<(size / pitch) {
            context.fill(CGRect(x: 0, y: row * pitch + 5, width: size, height: 7))
        }
        return context.makeImage()!
    }()

    /// Matte, slightly fuzzy material: very rough PBR plus a fine noise normal map.
    static func clay(_ color: NSColor, roughness: CGFloat = 0.92) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = color
        material.roughness.contents = roughness
        material.metalness.contents = 0.0
        material.normal.contents = feltNormalMap
        material.normal.intensity = 0.55
        material.normal.wrapS = .repeat
        material.normal.wrapT = .repeat
        material.normal.contentsTransform = SCNMatrix4MakeScale(3, 3, 1)
        return material
    }

    /// Random per-pixel normals around "straight out": reads as felt/flocking under light.
    static let feltNormalMap: CGImage = {
        let size = 256
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        var seed: UInt32 = 0x1234_5678
        func rand() -> Int { seed = seed &* 1_664_525 &+ 1_013_904_223; return Int(seed >> 24) }
        for i in 0..<(size * size) {
            pixels[i * 4] = UInt8(clamping: 128 + (rand() - 128) / 3)
            pixels[i * 4 + 1] = UInt8(clamping: 128 + (rand() - 128) / 3)
            pixels[i * 4 + 2] = 255
        }
        let context = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return context.makeImage()!
    }()

    /// White tile with a staggered grid of darker dots. Multiplied over the head's
    /// diffuse it reads as a mic grille in any theme color.
    static let grilleTile: CGImage = {
        let size = 128
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        let pitch = 16
        for row in 0..<(size / pitch) {
            for col in 0..<(size / pitch) {
                let offset = row % 2 == 0 ? 0 : pitch / 2
                let x = col * pitch + offset
                let y = row * pitch
                context.fillEllipse(in: CGRect(x: x + 3, y: y + 3, width: 9, height: 9))
            }
        }
        return context.makeImage()!
    }()

    /// Lights and a shadow-catching floor, shared by the live view and the icon renderer.
    static func stage(in scene: SCNScene, floorY: CGFloat = MicModel.floorY) {
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.intensity = 380
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light!.type = .directional
        key.light!.intensity = 1_250
        key.light!.castsShadow = true
        key.light!.shadowMode = .deferred
        key.light!.shadowRadius = 14
        key.light!.shadowSampleCount = 24
        key.light!.shadowColor = NSColor(white: 0, alpha: 0.5)
        key.eulerAngles = SCNVector3(-1.0, -0.55, 0)
        scene.rootNode.addChildNode(key)

        let rim = SCNNode()
        rim.light = SCNLight()
        rim.light!.type = .directional
        rim.light!.intensity = 520
        rim.eulerAngles = SCNVector3(-0.3, 2.6, 0)
        scene.rootNode.addChildNode(rim)

        // A plain plane, not SCNFloor: SCNFloor adds a reflection pass that, with a
        // shadow-only material, logs "FloorPass is not linked" every frame.
        let floor = SCNPlane(width: 12, height: 12)
        let catcher = SCNMaterial()
        catcher.lightingModel = .shadowOnly
        floor.materials = [catcher]
        let floorNode = SCNNode(geometry: floor)
        floorNode.eulerAngles.x = -.pi / 2
        floorNode.position = SCNVector3(0, floorY, 0)
        scene.rootNode.addChildNode(floorNode)
    }

    static func camera(in scene: SCNScene, distance: CGFloat = 6.4) -> SCNNode {
        let node = SCNNode()
        node.camera = SCNCamera()
        node.camera!.fieldOfView = 30
        node.position = SCNVector3(0, 0.8, distance)
        node.look(at: SCNVector3(0, 0.25, 0))
        scene.rootNode.addChildNode(node)
        return node
    }
}
