//
//  StoreManager.swift
//  MyNaiWa (奶蛙时代 / Naiwa Ages)
//
//  StoreKit 2 — v1 has two products: the 打枪 founder pack (non-consumable,
//  grants infinite 打枪) and a 请奶蛙喝奶茶 tip (consumable, grants nothing —
//  pure thank-you). Ownership of the pack is re-granted from entitlements on
//  launch + restore.
//

import StoreKit
import Combine

@MainActor
final class StoreManager: ObservableObject {

    enum ProductID {
        static let gunPack = "lxxdesign.MyNaiWa.founderpack.gun"
        static let milkTea = "lxxdesign.MyNaiWa.tip.milktea"
        static let food    = "lxxdesign.MyNaiWa.tip.food"
        static let all = [gunPack, milkTea, food]
    }

    @Published private(set) var products: [Product] = []
    @Published private(set) var isBusy = false

    /// Fired when the founder gun pack is owned (fresh purchase, restore, or a
    /// transaction pushed from another device) → grant infinite 打枪.
    var onGunOwned: (() -> Void)?

    private var updatesTask: Task<Void, Never>?

    init() {
        updatesTask = listenForTransactions()
        Task { await loadProducts() }
    }
    deinit { updatesTask?.cancel() }

    func product(_ id: String) -> Product? { products.first { $0.id == id } }
    /// Localized price string (e.g. "¥1.00"), empty until products load.
    func displayPrice(_ id: String) -> String { product(id)?.displayPrice ?? "" }

    func loadProducts() async {
        do { products = try await Product.products(for: ProductID.all) }
        catch { print("⚠️ StoreKit load: \(error)") }
    }

    /// Buy a product. Returns true only on a verified, completed purchase.
    @discardableResult
    func purchase(_ id: String) async -> Bool {
        if product(id) == nil { await loadProducts() }
        guard let product = product(id) else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else { return false }
                await grant(transaction)
                await transaction.finish()
                return true
            case .userCancelled, .pending:
                return false
            @unknown default:
                return false
            }
        } catch {
            print("⚠️ purchase: \(error)")
            return false
        }
    }

    /// Restore purchases (required by App Review for the non-consumable pack).
    func restore() async {
        isBusy = true
        defer { isBusy = false }
        try? await AppStore.sync()
        await refreshEntitlements()
    }

    /// Re-grant currently-owned non-consumables — call on launch and after restore.
    func refreshEntitlements() async {
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result { await grant(transaction) }
        }
    }

    private func grant(_ transaction: Transaction) async {
        switch transaction.productID {
        case ProductID.gunPack: onGunOwned?()
        case ProductID.milkTea, ProductID.food: break   // consumable tips → grant nothing
        default: break
        }
    }

    private func listenForTransactions() -> Task<Void, Never> {
        Task { [weak self] in
            for await update in Transaction.updates {
                guard case .verified(let transaction) = update else { continue }
                await self?.grant(transaction)
                await transaction.finish()
            }
        }
    }
}
