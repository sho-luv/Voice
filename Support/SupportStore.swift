// SPDX-License-Identifier: GPL-3.0-or-later
// SupportStore.swift — "Support Voice": a one-time, pay-what-you-want Stripe Payment Link.
//
// Nothing in Voice is gated. The app is GPL and fully free; this is a tip jar
// with a thank-you badge. Flow:
//   1. The $3 / $5 / $10 / $20 buttons (and "pick your own") each open a Stripe
//      Payment Link in the browser with a random `client_reference_id`, so a
//      payment can be matched to this Mac if a receipt ever needs checking.
//   2. Stripe's after-payment redirect lands on faradaysoft.com/thanks, which
//      opens `voice://thanks`. The app marks this Mac as a supporter.
//   3. "Already chipped in?" marks it by hand: honor system, nothing to protect.
// The links live in Info.plist (VoiceSupportLinks) so the store can change
// without a code change. See SUPPORT.md for the Stripe dashboard steps.

import AppKit
import Foundation

final class SupportStore: ObservableObject {
    static let shared = SupportStore()

    @Published private(set) var isSupporter: Bool
    @Published private(set) var supportedAt: Date?
    /// Set when a `voice://thanks` URL arrives, so the Support screen can play the moment.
    @Published var pendingThanks = false

    private let defaults = UserDefaults.standard
    private let supporterKey = "supporter"
    private let supportedAtKey = "supportedAt"
    private let referenceKey = "supportReference"

    private init() {
        isSupporter = defaults.bool(forKey: supporterKey)
        supportedAt = defaults.object(forKey: supportedAtKey) as? Date
    }

    /// The fixed tip amounts shown as buttons, in order. Each has its own Payment Link.
    static let amounts = ["3", "5", "10", "20"]

    /// Payment Links from Info.plist (`VoiceSupportLinks`: "3", "5", "10", "20", "custom").
    static var links: [String: String] {
        Bundle.main.object(forInfoDictionaryKey: "VoiceSupportLinks") as? [String: String] ?? [:]
    }

    /// The link for an amount key, or the website's support page when it isn't set up.
    static func paymentURL(for key: String) -> URL {
        URL(string: links[key] ?? "") ?? URL(string: "https://faradaysoft.com/support")!
    }

    static var isConfigured: Bool {
        links.values.contains { $0.contains("stripe.com") }
    }

    /// A per-Mac random reference attached to the checkout (`client_reference_id`).
    var reference: String {
        if let existing = defaults.string(forKey: referenceKey) { return existing }
        let fresh = "voice-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(20)
        defaults.set(fresh, forKey: referenceKey)
        return fresh
    }

    /// Opens the checkout for an amount key ("3", "5", "10", "20" or "custom").
    func openCheckout(_ key: String = "custom") {
        var components = URLComponents(url: Self.paymentURL(for: key), resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        items.append(URLQueryItem(name: "client_reference_id", value: reference))
        components?.queryItems = items
        NSWorkspace.shared.open(components?.url ?? Self.paymentURL(for: key))
    }

    func markSupported(source: String) {
        NSLog("Voice: supporter marked (%@)", source)
        let now = Date()
        defaults.set(true, forKey: supporterKey)
        defaults.set(now, forKey: supportedAtKey)
        isSupporter = true
        supportedAt = now
    }

    func clear() {
        defaults.removeObject(forKey: supporterKey)
        defaults.removeObject(forKey: supportedAtKey)
        isSupporter = false
        supportedAt = nil
    }

    /// Handles `voice://` URLs. Returns true if the URL was ours.
    @discardableResult
    func handle(url: URL) -> Bool {
        guard url.scheme?.lowercased() == "voice" else { return false }
        switch url.host?.lowercased() {
        case "thanks":
            if !isSupporter { markSupported(source: "stripe redirect") }
            pendingThanks = true
            AppWindows.shared.showHome(route: .support)
        case "support":
            AppWindows.shared.showHome(route: .support)
        default:
            AppWindows.shared.showHome()
        }
        return true
    }

    var sinceText: String {
        guard let supportedAt else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: supportedAt)
    }
}
