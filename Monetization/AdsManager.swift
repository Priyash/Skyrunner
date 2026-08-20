import Foundation

/// Ad abstraction. Ships as a NO-OP/simulated stub so the game builds and runs
/// with zero third-party dependencies. To go live with real ads:
///
/// 1. Add the Google Mobile Ads SDK via Swift Package Manager:
///    https://github.com/googleads/swift-package-manager-google-mobile-ads
/// 2. Add `GADApplicationIdentifier` to Info.plist (your AdMob App ID),
///    plus the SKAdNetworkItems list from Google's docs.
/// 3. Replace the bodies below with GADInterstitialAd / GADRewardedAd
///    load + present calls (AdMob's docs have drop-in snippets).
/// 4. App Store requirement: because ads involve tracking, you must fill in
///    the App Privacy section in App Store Connect and (for personalized ads)
///    show the ATT prompt via AppTrackingTransparency.
///
/// Keeping this behind one class means the rest of the game never changes
/// when you swap ad networks.
final class AdsManager {
    static let shared = AdsManager()
    private init() {}

    /// Full-screen ad between levels. No-op in the stub.
    func showInterstitial() {
        guard !GameData.shared.adsRemoved else { return }
        print("[Ads] Interstitial would show here (stub).")
    }

    /// Opt-in rewarded ad. The stub simulates a 1.5s ad then grants the reward,
    /// so the revive flow is fully testable before AdMob is wired up.
    func showRewardedAd(completion: @escaping (Bool) -> Void) {
        print("[Ads] Rewarded ad would show here (stub). Granting reward in 1.5s…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            completion(true)
        }
    }
}
