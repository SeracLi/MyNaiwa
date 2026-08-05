//
//  Analytics.swift
//  MyNaiWa (奶蛙时代)
//
//  Thin analytics abstraction. Every event lives in `AnalyticsEvent` (one
//  catalog), and call sites only ever touch `Analytics.log(.something)`. The
//  backend is swappable — v1 ships with a console logger; wire a real provider
//  (国内首选友盟 UMeng；海外可用 TelemetryDeck) before launch by replacing
//  `Analytics.backend`, WITHOUT touching any call site.
//

import Foundation

enum Analytics {
    static var backend: AnalyticsBackend = ConsoleAnalytics()
    static func log(_ event: AnalyticsEvent) {
        backend.send(name: event.name, params: event.params)
    }
}

protocol AnalyticsBackend {
    func send(name: String, params: [String: Any])
}

/// Default backend — prints in DEBUG, no-op in release. Replace before shipping.
struct ConsoleAnalytics: AnalyticsBackend {
    func send(name: String, params: [String: Any]) {
        #if DEBUG
        let extra = params.isEmpty ? "" : " " + params.map { "\($0)=\($1)" }.sorted().joined(separator: " ")
        print("📊 \(name)\(extra)")
        #endif
    }
}

/// The v1 event catalog — deliberately small, aimed at the retention + purchase
/// funnels (what keeps users, what converts to paying).
enum AnalyticsEvent {
    case appOpen                                   // session start
    case firstInteraction                          // activation: ever interacted
    case talkUsed                                  // 奶蛙 actually spoke back
    case actionPlayed(id: String, tier: String)    // which action, which tier
    case panelOpened(kind: String)                 // "action" / "voice"
    case voiceSwitched(id: String)
    case lockedTapped(id: String, tier: String)    // tapped a locked item
    case unlockSucceeded(id: String, cost: Int)    // spent coins to unlock
    case unlockFailedNoCoins(id: String)           // wanted to unlock but broke
    case refilled(id: String)
    case founderDialogShown
    case founderPurchased
    case tipPurchased(kind: String)                // "milktea" / "food"
    case gatlingTriggered
    case taskClaimed(id: String, reward: Int)
    case rateTapped
    case shareTapped

    var name: String {
        switch self {
        case .appOpen:                return "app_open"
        case .firstInteraction:       return "first_interaction"
        case .talkUsed:               return "talk_used"
        case .actionPlayed:           return "action_played"
        case .panelOpened:            return "panel_opened"
        case .voiceSwitched:          return "voice_switched"
        case .lockedTapped:           return "locked_tapped"
        case .unlockSucceeded:        return "unlock_succeeded"
        case .unlockFailedNoCoins:    return "unlock_failed_no_coins"
        case .refilled:               return "refilled"
        case .founderDialogShown:     return "founder_dialog_shown"
        case .founderPurchased:       return "founder_purchased"
        case .tipPurchased:           return "tip_purchased"
        case .gatlingTriggered:       return "gatling_triggered"
        case .taskClaimed:            return "task_claimed"
        case .rateTapped:             return "rate_tapped"
        case .shareTapped:            return "share_tapped"
        }
    }

    var params: [String: Any] {
        switch self {
        case let .actionPlayed(id, tier):    return ["id": id, "tier": tier]
        case let .panelOpened(kind):         return ["kind": kind]
        case let .voiceSwitched(id):         return ["id": id]
        case let .lockedTapped(id, tier):    return ["id": id, "tier": tier]
        case let .unlockSucceeded(id, cost): return ["id": id, "cost": cost]
        case let .unlockFailedNoCoins(id):   return ["id": id]
        case let .refilled(id):              return ["id": id]
        case let .tipPurchased(kind):        return ["kind": kind]
        case let .taskClaimed(id, reward):   return ["id": id, "reward": reward]
        default:                             return [:]
        }
    }
}
