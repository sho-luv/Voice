// SPDX-License-Identifier: GPL-3.0-or-later
// tools/icon/main.swift — Render the app icon from the hero microphone.
//
// Usage (from the repo root):
//   swiftc -O Design/HeroModel.swift tools/icon/main.swift -o build/render_icon
//   build/render_icon icon.png            # 1024x1024 PNG
//   build-app.sh turns icon.png into Voice.icns via iconutil.
//
// The icon is the Midnight mic on a charcoal squircle, lit like the app.

import AppKit
import SceneKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let size = 1024

let scene = SCNScene()
MicModel.stage(in: scene)
let camera = MicModel.camera(in: scene, distance: 5.5)
camera.look(at: SCNVector3(0.05, 0.42, 0))
let style = MicStyle(rawValue: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "") ?? .stage
let nodes = MicModel.make(style: style, head: NSColor(srgbRed: 1.0, green: 0.18, blue: 0.18, alpha: 1), stand: NSColor(white: 0.17, alpha: 1))
let turntable = SCNNode()
turntable.eulerAngles = SCNVector3(0.06, -0.38, 0)
turntable.addChildNode(nodes.root)
scene.rootNode.addChildNode(turntable)
nodes.lampMaterial.emission.contents = NSColor(srgbRed: 1.0, green: 0.18, blue: 0.18, alpha: 1)
scene.background.contents = NSColor.clear

guard let device = MTLCreateSystemDefaultDevice() else { fatalError("No Metal device") }
let renderer = SCNRenderer(device: device, options: nil)
renderer.scene = scene
renderer.pointOfView = camera
renderer.isJitteringEnabled = true
let mic = renderer.snapshot(atTime: 0, with: CGSize(width: size, height: size), antialiasingMode: .multisampling4X)

// macOS icon: a squircle filling ~80% of the canvas (the system adds the shadow).
let canvas = NSImage(size: NSSize(width: size, height: size))
canvas.lockFocus()
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()
let inset = CGFloat(size) * 0.1
let tile = NSRect(x: inset, y: inset, width: CGFloat(size) - 2 * inset, height: CGFloat(size) - 2 * inset)
let squircle = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.2237, yRadius: tile.height * 0.2237)
NSColor(srgbRed: 0.078, green: 0.078, blue: 0.078, alpha: 1).setFill()
squircle.fill()
squircle.addClip()
mic.draw(in: tile.insetBy(dx: -tile.width * 0.02, dy: -tile.height * 0.02), from: .zero, operation: .sourceOver, fraction: 1)
canvas.unlockFocus()

guard let tiff = canvas.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("encode failed") }
try! png.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
