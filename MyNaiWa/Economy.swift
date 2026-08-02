//
//  Economy.swift
//  MyNaiWa (奶蛙时代)
//
//  Slice A — the coin + asset-state data layer. Headless: it owns 奶币 and every
//  unlockable asset's progress (unlocked / remaining uses / infinite / previews /
//  discovered) and persists a single snapshot to UserDefaults + iCloud KV, newest
//  write wins. UI gating (locks, popups, badges) comes in later slices.
//

import SwiftUI
import Combine

// MARK: - Asset tiers

/// How an asset is gated. Body-tap reactions (自带) aren't modeled here — they're
/// always-free zone reactions handled directly by the player.
enum AssetTier: String, Codable {
    case gift     // 赠送 — infinite, free, shown
    case free     // 免费 — locked; unlock 50→+5 uses; refill 100→+10
    case pack     // 礼包 — founder ¥ IAP → infinite; before buy: 2 free previews
    case hidden   // 隐藏 — not shown until triggered; on trigger +5 uses; then 100/10

    /// Can an asset with this tier + progress be played right now?
    func isPlayable(_ p: AssetProgress) -> Bool {
        switch self {
        case .gift:   return true
        case .free:   return p.unlocked && (p.infinite || p.uses > 0)
        case .pack:   return p.infinite || p.previewsUsed < Economy.packPreviewLimit
        case .hidden: return p.discovered && (p.infinite || p.uses > 0)
        }
    }

    /// Is the asset visible in its panel at all? (隐藏 stays hidden until found.)
    func isVisible(_ p: AssetProgress) -> Bool {
        switch self {
        case .hidden: return p.discovered
        default:      return true
        }
    }
}

// MARK: - Per-asset persisted progress

struct AssetProgress: Codable, Equatable {
    var unlocked: Bool = false      // free: coins spent · pack: bought · hidden: triggered
    var infinite: Bool = false      // owned pack (later: VIP)
    var uses: Int = 0               // remaining metered uses (free / hidden)
    var previewsUsed: Int = 0       // pack: free previews consumed
    var discovered: Bool = false    // hidden: has been triggered/seen
}

// MARK: - Economy store

@MainActor
final class Economy: ObservableObject {

    // Tunable v1 numbers (see the economy memory).
    static let startingCoins   = 50
    static let freeUnlockCost  = 50
    static let freeUnlockUses  = 5
    static let refillCost      = 100
    static let refillUses      = 10
    static let packPreviewLimit = 2

    @Published private(set) var coins: Int = 0
    @Published private(set) var assets: [String: AssetProgress] = [:]

    private var updatedAt: Double = 0
    private let defaults = UserDefaults.standard
    private let cloud = NSUbiquitousKeyValueStore.default
    private let key = "naiwa_economy_v1"
    private var cloudObserver: NSObjectProtocol?

    init() {
        // Newest snapshot wins between the local copy and iCloud (single-user,
        // rare concurrent edits — whole-snapshot newest-wins avoids per-field
        // merge bugs that would resurrect or drop spent coins).
        let local  = Self.decode(defaults.data(forKey: key))
        let remote = Self.decode(cloud.data(forKey: key))
        if let best = [local, remote].compactMap({ $0 }).max(by: { $0.updatedAt < $1.updatedAt }) {
            apply(best)
        } else {
            // Fresh install — grant the starting balance.
            coins = Self.startingCoins
            assets = [:]
            updatedAt = Date().timeIntervalSince1970
            persist()
        }

        cloudObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.adoptCloudIfNewer() }
        }
        cloud.synchronize()
    }

    deinit {
        if let o = cloudObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: Coins

    func earn(_ n: Int) {
        guard n != 0 else { return }
        coins = max(0, coins + n)
        bump()
    }

    /// Spend if affordable. Returns false (and changes nothing) when short.
    @discardableResult
    func spend(_ n: Int) -> Bool {
        guard n >= 0, coins >= n else { return false }
        coins -= n
        bump()
        return true
    }

    // MARK: Assets

    func progress(_ id: String) -> AssetProgress { assets[id] ?? AssetProgress() }

    func isPlayable(_ id: String, tier: AssetTier) -> Bool { tier.isPlayable(progress(id)) }
    func isVisible(_ id: String, tier: AssetTier) -> Bool { tier.isVisible(progress(id)) }

    /// 免费 unlock: pay 50, mark unlocked, grant 5 uses. Returns false if short.
    @discardableResult
    func unlockFree(_ id: String) -> Bool {
        guard spend(Self.freeUnlockCost) else { return false }
        mutate(id) { $0.unlocked = true; $0.uses += Self.freeUnlockUses }
        return true
    }

    /// Refill an already-unlocked metered asset: pay 100, +10 uses.
    @discardableResult
    func refill(_ id: String) -> Bool {
        guard spend(Self.refillCost) else { return false }
        mutate(id) { $0.uses += Self.refillUses }
        return true
    }

    /// Consume one use of a metered asset (no-op if infinite / empty).
    func consumeUse(_ id: String) {
        mutate(id) { if !$0.infinite && $0.uses > 0 { $0.uses -= 1 } }
    }

    /// 礼包 free preview consumed.
    func consumePreview(_ id: String) {
        mutate(id) { $0.previewsUsed += 1 }
    }

    /// 礼包 IAP finished → own it forever.
    func markPackOwned(_ id: String) {
        mutate(id) { $0.unlocked = true; $0.infinite = true }
    }

    /// 隐藏 triggered → reveal + grant the initial 5 uses.
    func discoverHidden(_ id: String) {
        mutate(id) { $0.discovered = true; $0.unlocked = true; $0.uses += Self.freeUnlockUses }
    }

    // MARK: Debug (dev-only)

    func debugGrant(_ n: Int) { earn(n) }

    func debugReset() {
        coins = Self.startingCoins
        assets = [:]
        bump()
    }

    // MARK: Persistence

    private func mutate(_ id: String, _ f: (inout AssetProgress) -> Void) {
        var p = assets[id] ?? AssetProgress()
        f(&p)
        assets[id] = p
        bump()
    }

    private func bump() {
        updatedAt = Date().timeIntervalSince1970
        persist()
    }

    private func persist() {
        let snap = Snapshot(coins: coins, assets: assets, updatedAt: updatedAt)
        guard let data = try? JSONEncoder().encode(snap) else { return }
        defaults.set(data, forKey: key)
        cloud.set(data, forKey: key)
    }

    private func adoptCloudIfNewer() {
        guard let remote = Self.decode(cloud.data(forKey: key)), remote.updatedAt > updatedAt else { return }
        apply(remote)
    }

    private func apply(_ s: Snapshot) {
        coins = s.coins
        assets = s.assets
        updatedAt = s.updatedAt
    }

    private static func decode(_ data: Data?) -> Snapshot? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    private struct Snapshot: Codable {
        var coins: Int
        var assets: [String: AssetProgress]
        var updatedAt: Double
    }
}
