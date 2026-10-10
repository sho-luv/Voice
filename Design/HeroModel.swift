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
        switch style {
        case .stage: return make(head: head, stand: stand)
        case .vintage: return makeVintage(head: head, stand: stand)
        case .ribbon: return makeRibbon(head: head, stand: stand)
        case .podcast: return makePodcast(head: head, stand: stand)
        }
    }

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
        head.scale = SCNVector3(1, 1, 0.78)
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
        let slatPipe: CGFloat = 0.028
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
        let spine = SCNBox(width: 0.09, height: drumHeight + 0.1, length: 0.06, chamferRadius: 0.025)
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

        // Wedge neck (the badge block) in the upright frame, then the stand.
        let neck = SCNBox(width: 0.46, height: 0.52, length: 0.4, chamferRadius: 0.06)
        neck.materials = [standMaterial]
        let neckNode = SCNNode(geometry: neck)
        neckNode.position = SCNVector3(0, -0.2, -0.02)
        root.addChildNode(neckNode)
        let stem = SCNCylinder(radius: 0.08, height: 0.3)
        stem.materials = [standMaterial]
        let stemNode = SCNNode(geometry: stem)
        stemNode.position = SCNVector3(0, floorY + 0.2, 0)
        root.addChildNode(stemNode)
        let base = SCNCylinder(radius: 0.48, height: 0.08)
        base.radialSegmentCount = 64
        base.materials = [standMaterial]
        let baseNode = SCNNode(geometry: base)
        baseNode.position = SCNVector3(0, floorY + 0.04, 0)
        root.addChildNode(baseNode)

        let lampMaterial = lamp()
        let lampNode = SCNNode(geometry: lampSphere(lampMaterial, radius: 0.045))
        lampNode.position = SCNVector3(0, -0.05, 0.2)
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

    // MARK: Podcast (a slim broadcast mic, foam over the front half, side pivot on a tall desk stand)

    static func makePodcast(head headColor: NSColor, stand standColor: NSColor) -> Nodes {
        let root = SCNNode()
        let tilt: CGFloat = 0.55
        let pivotY: CGFloat = 0.42
        // The body hangs off a side pivot; it tilts, the stand doesn't.
        let body = SCNNode()
        body.eulerAngles = SCNVector3(0, 0, tilt)
        body.position = SCNVector3(0.02, pivotY, 0)
        root.addChildNode(body)

        let standMaterial = clay(standColor, roughness: 0.7)
        let bodyRadius: CGFloat = 0.23
        let barrel = SCNCylinder(radius: bodyRadius, height: 1.25)
        barrel.radialSegmentCount = 48
        barrel.materials = [standMaterial]
        body.addChildNode(SCNNode(geometry: barrel))
        // Flat rear with a soft edge.
        let tailRim = SCNTorus(ringRadius: bodyRadius - 0.04, pipeRadius: 0.04)
        tailRim.materials = [standMaterial]
        let tailRimNode = SCNNode(geometry: tailRim)
        tailRimNode.position = SCNVector3(0, -0.625, 0)
        body.addChildNode(tailRimNode)

        // Foam windscreen over the front half: extra-rough clay, stronger felt normal, no grille.
        let headMaterial = clay(headColor, roughness: 1.0)
        headMaterial.normal.intensity = 1.0
        headMaterial.normal.contentsTransform = SCNMatrix4MakeScale(6, 6, 1)
        let foam = SCNCapsule(capRadius: bodyRadius + 0.035, height: 0.78)
        foam.capSegmentCount = 24
        foam.materials = [headMaterial]
        let head = SCNNode(geometry: foam)
        head.position = SCNVector3(0, 0.44, 0)
        body.addChildNode(head)

        // Collar where foam meets body, and the status lamp on it.
        let collar = SCNTorus(ringRadius: bodyRadius, pipeRadius: 0.025)
        collar.materials = [standMaterial]
        let collarNode = SCNNode(geometry: collar)
        collarNode.position = SCNVector3(0, 0.04, 0)
        body.addChildNode(collarNode)
        let lampMaterial = lamp()
        let lampNode = SCNNode(geometry: lampSphere(lampMaterial, radius: 0.035))
        lampNode.position = SCNVector3(0, 0.0, bodyRadius + 0.01)
        body.addChildNode(lampNode)

        // Side pivot: a thumb-screw knob on the camera side of the body, at its middle.
        let knob = SCNCylinder(radius: 0.11, height: 0.07)
        knob.radialSegmentCount = 32
        knob.materials = [standMaterial]
        let knobNode = SCNNode(geometry: knob)
        knobNode.eulerAngles = SCNVector3(CGFloat.pi / 2, 0, 0)
        knobNode.position = SCNVector3(0, 0, bodyRadius + 0.04)
        body.addChildNode(knobNode)

        // Single arm from the pivot down and back to the top of the pole (upright frame).
        let armZ = bodyRadius + 0.04
        let armDrop: CGFloat = 0.32
        let armDown = SCNBox(width: 0.07, height: armDrop, length: 0.07, chamferRadius: 0.02)
        armDown.materials = [standMaterial]
        let armDownNode = SCNNode(geometry: armDown)
        armDownNode.position = SCNVector3(0.02, pivotY - armDrop / 2, armZ)
        root.addChildNode(armDownNode)
        let armBack = SCNBox(width: 0.07, height: 0.07, length: armZ + 0.07, chamferRadius: 0.02)
        armBack.materials = [standMaterial]
        let armBackNode = SCNNode(geometry: armBack)
        armBackNode.position = SCNVector3(0.02, pivotY - armDrop, armZ / 2)
        root.addChildNode(armBackNode)

        // Tall thin pole with a knurled adjustment collar, on a wide flat base.
        let poleTop = pivotY - armDrop
        let pole = SCNCylinder(radius: 0.045, height: poleTop - floorY)
        pole.radialSegmentCount = 32
        pole.materials = [standMaterial]
        let poleNode = SCNNode(geometry: pole)
        poleNode.position = SCNVector3(0.02, (poleTop + floorY) / 2, 0)
        root.addChildNode(poleNode)
        let knurl = SCNCylinder(radius: 0.085, height: 0.2)
        knurl.radialSegmentCount = 12 // faceted on purpose: reads as a grip
        knurl.materials = [standMaterial]
        let knurlNode = SCNNode(geometry: knurl)
        knurlNode.position = SCNVector3(0.02, floorY + 0.45, 0)
        root.addChildNode(knurlNode)
        let base = SCNCylinder(radius: 0.6, height: 0.05)
        base.radialSegmentCount = 64
        base.materials = [standMaterial]
        let baseNode = SCNNode(geometry: base)
        baseNode.position = SCNVector3(0.02, floorY + 0.025, 0)
        root.addChildNode(baseNode)
        let baseStep = SCNCylinder(radius: 0.42, height: 0.04)
        baseStep.radialSegmentCount = 64
        baseStep.materials = [standMaterial]
        let baseStepNode = SCNNode(geometry: baseStep)
        baseStepNode.position = SCNVector3(0.02, floorY + 0.07, 0)
        root.addChildNode(baseStepNode)

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
