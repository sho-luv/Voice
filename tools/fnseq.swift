// SPDX-License-Identifier: GPL-3.0-or-later
// tools/fnseq.swift — Dev tool: post a timed fn / Escape sequence to test the hotkey tap.
// Build: swiftc -O tools/fnseq.swift -o build/fnseq   (the terminal needs Accessibility to post events)
// Use:   build/fnseq down 300 up                  push-to-talk hold of 300 ms
//        build/fnseq down 60 up 150 down 60 up     double-tap (hands-free on); "down 60 up" again stops it
//        build/fnseq down 900 esc 200 up           Escape cancels a hold
// Posts a timed sequence of fn presses from one process: tokens are "down", "up", "esc", or a number of ms to wait.
import CoreGraphics
import Foundation
let source = CGEventSource(stateID: .hidSystemState)
func fn(_ down: Bool) {
    guard let e = CGEvent(keyboardEventSource: source, virtualKey: 63, keyDown: down) else { return }
    e.type = .flagsChanged
    e.flags = down ? [.maskSecondaryFn] : []
    e.post(tap: .cghidEventTap)
}
for token in CommandLine.arguments.dropFirst() {
    switch token {
    case "down": fn(true)
    case "up": fn(false)
    case "esc":
        CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
    default:
        if let ms = Double(token) { Thread.sleep(forTimeInterval: ms / 1000) }
    }
}
print("sequence posted")
