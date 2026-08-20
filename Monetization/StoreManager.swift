import Foundation
import StoreKit

/// StoreKit 2 manager. Handles product loading, purchases, restore,
/// and background transaction updates (Ask to Buy, refunds, cross-device).
@MainActor
final class StoreManager {
    static let shared = StoreManager()

    private(set) var products: [String: Product] = [:]
    private var updatesTask: Task<Void, Never>?

    private init() {
        // Listen for transactions that arrive outside a direct purchase flow.
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.handle(result)
            }
        }
        Task {
            await self.loadProducts()
            await self.refreshEntitlements()
        }
    }

    func loadProducts() async {
        do {
            let ids = [ProductID.removeAds, ProductID.coins500]
            let fetched = try await Product.products(for: ids)
            for p in fetched { products[p.id] = p }
        } catch {
            print("StoreKit: failed to load products — \(error)")
        }
    }

    func purchase(productID: String) async {
        if products[productID] == nil { await loadProducts() }
        guard let product = products[productID] else {
            print("StoreKit: product \(productID) unavailable")
            return
        }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                await handle(verification)
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            print("StoreKit: purchase failed — \(error)")
        }
    }

    func restorePurchases() async {
        try? await AppStore.sync()
        await refreshEntitlements()
    }

    /// Re-derive non-consumable state from current entitlements.
    func refreshEntitlements() async {
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == ProductID.removeAds,
               transaction.revocationDate == nil {
                GameData.shared.adsRemoved = true
            }
        }
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else { return }
        switch transaction.productID {
        case ProductID.removeAds:
            GameData.shared.adsRemoved = transaction.revocationDate == nil
        case ProductID.coins500:
            if transaction.revocationDate == nil {
                GameData.shared.addCoins(500)
            }
        default:
            break
        }
        await transaction.finish()
    }
}
