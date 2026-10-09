# Support Voice: the Stripe setup

Voice has no paywall. "Support Voice" is a one-time, pay-what-you-want tip through a
Stripe Payment Link. This is the reusable process for any app that wants a tip jar or
a paid upgrade: the app only needs a URL, Stripe hosts the checkout, and a redirect
brings the person back into the app.

## How it works in the app

1. `SupportView` (heart button, or menu bar > Support Voice) shows $3 / $5 / $10 / $20
   buttons and "pick your own amount"; each opens its Payment Link in the browser.
   `SupportStore.openCheckout(key)` appends `client_reference_id=<voice-...>`,
   a random per-Mac token, so a payment can be matched to a Mac if that is ever needed.
2. Stripe's after-payment redirect goes to `https://faradaysoft.com/thanks`, which opens
   `voice://thanks` (a link and an automatic redirect). The app registers the `voice`
   URL scheme (`CFBundleURLTypes` in `Info.plist`) and handles it in
   `AppDelegate.handleURLEvent`, which marks this Mac as a supporter and plays the moment.
3. "Already chipped in? Mark it" sets the badge by hand. Nothing is verified. The badge
   unlocks nothing, so there is nothing to protect.

The link comes from `Info.plist` > `VoiceSupportURL`. Until it contains a `stripe.com`
URL, the Support screen shows a "payment link not set up yet" pill.

## Current state (2026-10-08)

| Thing | Value |
|---|---|
| Stripe account | `acct_1TF0IGE0h3RZWa8f`, business name still "New business" (rename to Faraday Soft in Settings > Business details) |
| Product (test mode) | "Support Voice", `prod_VPCJ79RJzd0KKw`, customer chooses price, preset $9, min $3, max $500 |
| Prices (test mode) | $3, $5, $10, $20 one-off, plus "customer chooses" (preset $9, min $3, max $500) |
| Payment Links (test mode) | $3 `test_7sYaEX1ePfNS3VZ0s1dfG01`, $5 `test_8x228r9Ll7hmbor7UtdfG02`, $10 `test_3cI8wPe1B7hm647eiRdfG03`, $20 `test_eVq00j9LlfNSdwzb6FdfG04`, custom `test_eVq00jg9JfNS78bcaJdfG00` (all `https://buy.stripe.com/...`) |
| After payment | Redirect to `https://faradaysoft.com/thanks/?session_id={CHECKOUT_SESSION_ID}` |
| In the app | `Info.plist` `VoiceSupportLinks` dict (keys 3, 5, 10, 20, custom); swap for the live links before release |

Sandbox objects do not carry over to live mode. After "Verify your business" activates the
account, recreate the product and link in live mode (same settings, takes two minutes), put
the `https://buy.stripe.com/...` (no `test_`) URLs in `Info.plist` and `support/index.html`.

## Stripe dashboard, step by step

1. **Account.** stripe.com > Start now. Business: Enfrosec LLC (dba Faraday Soft).
   Complete the activation (EIN or SSN, bank account). Until activated, links work in
   test mode only (URLs start with `https://buy.stripe.com/test_...`).
2. **Product.** Product catalog > Add product. Name "Support Voice", description
   "A one-time thank-you. Voice stays free for everyone." One-time price. Choose
   **Customer chooses price** (pay what you want); set a minimum (for example $3) and a
   suggested amount ($9). Save.
3. **Payment Link.** Payment links > New. Pick the product. Under *After payment* choose
   **Don't show confirmation page** and set the redirect to
   `https://faradaysoft.com/thanks?session_id={CHECKOUT_SESSION_ID}`.
   Options worth turning on: collect the email (for a receipt), promotion codes off,
   adjustable quantity off. Create, then copy the URL (`https://buy.stripe.com/...`).
4. **App.** Put that URL in `Info.plist` under `VoiceSupportURL`. Rebuild. The
   "not set up yet" pill disappears.
5. **Thanks page.** Add `tools/thanks.html` to the faradaysoft.com repo as
   `thanks/index.html` (or `thanks.html`). It opens `voice://thanks` automatically and
   has a button in case the browser blocks the redirect.
6. **Test.** With the link in test mode, pay with card `4242 4242 4242 4242`, any future
   date, any CVC. Confirm the browser bounces to the thanks page and Voice shows
   "THANK YOU." and the supporter badge. Then switch the link to live mode.

## Reusing this for another app

- Paid upgrade instead of a tip: same Payment Link, fixed price, and the redirect carries
  `{CHECKOUT_SESSION_ID}`. To actually gate a feature, verify the session server side
  (a Cloudflare Worker calling `GET /v1/checkout/sessions/{id}` with the secret key) and
  hand the app a signed license. Voice does not do this on purpose.
- Mac App Store apps use StoreKit 2 instead (see Lock Chimes' `ProStore.swift`); Stripe
  is for direct-download apps and websites.
- Fees (2026): 2.9% + $0.30 per card payment. Stripe is not a merchant of record; sales
  tax, if any, is on the business. Downloadable software is generally exempt in
  California. Check with the accountant before relying on that.
