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

    /// Outcome of a purchase attempt. We distinguish these so the UI can react
    /// correctly: only `.failed` deserves an error prompt, `.cancelled` is silent,
    /// and `.pending` means the reward arrives later via the transaction listener
    /// (Ask-to-Buy / deferred), so we tell the user to wait rather than nothing.
    enum PurchaseResult { case success, cancelled, pending, failed }

    @Published private(set) var products: [Product] = []
    @Published private(set) var isBusy = false

    /// Fired when the founder gun pack is owned (fresh purchase, restore, or a
    /// transaction pushed from another device) → grant infinite 打枪. It fires from
    /// `grant()` — the single point BOTH the purchase() return path and the async
    /// `Transaction.updates` listener funnel through — so the unlock (and its
    /// celebration) reaches the user no matter which path delivers the deal.
    var onGunOwned: (() -> Void)? { didSet { flushPendingGrants() } }

    /// Fired when a consumable tip (奶茶 / 美食) is paid — kind is "milktea"/"food".
    /// Also routed through `grant()`, so an async/deferred tip still counts.
    var onTipPaid: ((String) -> Void)? { didSet { flushPendingGrants() } }

    /// Product IDs that were delivered before their callback was wired (e.g. an
    /// unfinished transaction from a crashed session arrives via the listener
    /// during init, before ContentView's .task assigns the callbacks). We buffer
    /// them and replay once a callback is set — otherwise a consumable tip's count
    /// would be finished-and-lost forever.
    private var pendingGrants: [String] = []

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

    /// Buy a product. The result tells the caller exactly what happened so it can
    /// give the right feedback (success celebration / silent cancel / "processing"
    /// / error) instead of the old silent no-op that read like a broken app.
    @discardableResult
    func purchase(_ id: String) async -> PurchaseResult {
        if product(id) == nil { await loadProducts() }
        guard let product = product(id) else { return .failed }
        isBusy = true
        defer { isBusy = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await grant(transaction)
                    await transaction.finish()
                    return .success
                case .unverified(let transaction, _):
                    // Don't grant an unverified deal, but finish it so it stops
                    // replaying through Transaction.updates forever.
                    await transaction.finish()
                    return .failed
                }
            case .userCancelled:
                return .cancelled
            case .pending:
                // Deferred (Ask-to-Buy, SCA, etc.). It'll land later in the
                // listener, which grants + celebrates then.
                return .pending
            @unknown default:
                return .failed
            }
        } catch {
            print("⚠️ purchase: \(error)")
            return .failed
        }
    }

    /// Restore purchases (required by App Review for the non-consumable pack).
    /// Returns true if anything was actually restored (drives user feedback).
    @discardableResult
    func restore() async -> Bool {
        isBusy = true
        defer { isBusy = false }
        try? await AppStore.sync()
        var found = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                await grant(transaction)
                found = true
            }
        }
        return found
    }

    /// Re-grant currently-owned non-consumables — call on launch and after restore.
    func refreshEntitlements() async {
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result { await grant(transaction) }
        }
    }

    private func grant(_ transaction: Transaction) async {
        dispatchGrant(transaction.productID)
    }

    /// Route a delivered productID to its callback, or buffer it if the callback
    /// isn't wired yet (see pendingGrants).
    private func dispatchGrant(_ productID: String) {
        switch productID {
        case ProductID.gunPack:
            if let cb = onGunOwned { cb() } else { pendingGrants.append(productID) }
        case ProductID.milkTea:
            if let cb = onTipPaid { cb("milktea") } else { pendingGrants.append(productID) }
        case ProductID.food:
            if let cb = onTipPaid { cb("food") } else { pendingGrants.append(productID) }
        default:
            break
        }
    }

    /// Replay buffered grants once a callback is assigned. Clears the buffer first
    /// so anything still un-wired is simply re-buffered (no double-fire).
    private func flushPendingGrants() {
        guard !pendingGrants.isEmpty else { return }
        let items = pendingGrants
        pendingGrants = []
        for id in items { dispatchGrant(id) }
    }

    private func listenForTransactions() -> Task<Void, Never> {
        Task { [weak self] in
            for await update in Transaction.updates {
                switch update {
                case .verified(let transaction):
                    await self?.grant(transaction)
                    await transaction.finish()
                case .unverified(let transaction, _):
                    // Finish so it doesn't replay endlessly; never grant it.
                    await transaction.finish()
                @unknown default:
                    break
                }
            }
        }
    }
}
