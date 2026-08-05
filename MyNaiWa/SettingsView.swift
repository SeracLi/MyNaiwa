//
//  SettingsView.swift
//  MyNaiWa (奶蛙时代)
//
//  First-version settings — deliberately minimal. Ported from the shipped 奶蛙
//  app's SettingsView, trimmed to: rate · share · FAQ · privacy · terms ·
//  other works · version. No season/stats/store/localization yet.
//

import SwiftUI

// MARK: - App version

enum AppVersion {
    static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}

// MARK: - Share sheet

/// Thin wrapper over UIActivityViewController for the 分享给朋友 flow.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var store: StoreManager
    /// Called by the back button. Passed in (rather than using `\.dismiss`) so
    /// the host can show/hide the page instantly instead of the sheet slide.
    let onClose: () -> Void

    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var showShareSheet = false
    @State private var showTipChooser = false
    @State private var thanksKind: TipKind?

    /// Which tip was just paid — drives the (differentiated) thank-you card.
    private enum TipKind {
        case milktea, food
        var image: String { self == .milktea ? "打赏奶茶" : "打赏美食" }
        var title: String { self == .milktea ? "谢谢你的奶茶 🧋" : "谢谢你的美食 😋" }
    }

    /// 奶蛙时代's App Store id.
    private static let appStoreId = "6796403986"
    private static let appStoreURL = "https://apps.apple.com/app/id\(appStoreId)"

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        // Rate & Share
                        settingsRow(emoji: "🤩", title: "去给奶蛙时代评分") {
                            openURL("\(Self.appStoreURL)?action=write-review")
                        }
                        settingsRow(emoji: "📤", title: "分享给朋友") {
                            showShareSheet = true
                        }

                        divider

                        // FAQ
                        settingsRow(emoji: "🤔", title: "常见疑问解答") {
                            openURL("https://windream.super.site/to-the-moon/questions")
                        }

                        divider

                        // Tip + restore
                        settingsRow(emoji: "🍰", title: "请奶蛙吃点好的") {
                            withAnimation(.easeOut(duration: 0.18)) { showTipChooser = true }
                        }
                        settingsRow(emoji: "🔄", title: "恢复购买") {
                            Task { await store.restore() }
                        }

                        divider

                        // Legal
                        settingsRow(emoji: "🔒", title: "隐私政策") {
                            openURL("https://windream.super.site/to-the-moon/privacy-policy")
                        }
                        settingsRow(emoji: "📄", title: "服务条款") {
                            openURL("https://windream.super.site/to-the-moon/terms-of-use")
                        }
                    }
                    .padding(.top, 8)

                    otherWorksSection
                        .padding(.top, 28)

                    Text("v\(AppVersion.current)")
                        .font(.system(size: 13))
                        .foregroundColor(Color(.systemGray))
                        .padding(.top, 40)
                        .padding(.bottom, 32)
                }
            }

            // Tip chooser — 奶茶 or 美食, each with its designed image + price.
            if showTipChooser {
                Color.black.opacity(0.35).ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { showTipChooser = false } }
                VStack(spacing: 18) {
                    Text("请奶蛙吃点好的 💛")
                        .font(.system(size: 17, weight: .bold)).foregroundColor(.black)
                    HStack(spacing: 16) {
                        tipOption(image: "打赏奶茶", title: "喝奶茶",
                                  id: StoreManager.ProductID.milkTea, fallback: "¥6")
                        tipOption(image: "打赏美食", title: "吃美食",
                                  id: StoreManager.ProductID.food, fallback: "¥12")
                    }
                    Button("以后再说") {
                        withAnimation(.easeOut(duration: 0.15)) { showTipChooser = false }
                    }
                    .font(.system(size: 15)).foregroundColor(.secondary)
                }
                .padding(24)
                .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color(red: 1.0, green: 0.99, blue: 0.97)))
                .shadow(color: .black.opacity(0.28), radius: 26, y: 12)
                .padding(.horizontal, 40)
                .transition(.scale(scale: 0.88).combined(with: .opacity))
            }

            // Differentiated thank-you card — big image, vertically centered.
            if let kind = thanksKind {
                Color.black.opacity(0.4).ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { thanksKind = nil } }
                VStack(spacing: 16) {
                    Image(kind.image).resizable().scaledToFit().frame(width: 112, height: 112)
                    Text(kind.title)
                        .font(.system(size: 19, weight: .bold)).foregroundColor(.black)
                    Text("奶蛙收到啦，抱抱你！\n你的支持是它穿越更多时代的动力 💛")
                        .font(.system(size: 14)).foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { thanksKind = nil }
                    } label: {
                        Text("不客气~")
                            .font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Color.black)
                            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                    }
                }
                .padding(24)
                .frame(width: 286)
                .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color(red: 1.0, green: 0.99, blue: 0.97)))
                .shadow(color: .black.opacity(0.28), radius: 26, y: 12)
                .transition(.scale(scale: 0.88).combined(with: .opacity))
            }
        }
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: { onClose() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.black)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }
            ToolbarItem(placement: .principal) {
                Text("设置")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.black)
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [URL(string: Self.appStoreURL)!])
        }
    }

    // MARK: Row

    private func settingsRow(emoji: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(emoji)
                    .font(.system(size: 22))
                    .frame(width: 28)
                Text(title)
                    .font(.system(size: 17))
                    .foregroundColor(.black)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.black.opacity(0.4))
            }
            .padding(.horizontal, hSizeClass == .regular ? 24 : 32)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.black.opacity(0.12))
            .frame(height: 0.5)
            .padding(.horizontal, hSizeClass == .regular ? 24 : 32)
            .padding(.vertical, 4)
    }

    /// One tip choice (奶茶 / 美食) — image + name + price, buys on tap.
    private func tipOption(image: String, title: String, id: String, fallback: String) -> some View {
        let price = store.displayPrice(id)
        return Button {
            Task {
                if await store.purchase(id) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showTipChooser = false
                        thanksKind = (id == StoreManager.ProductID.milkTea) ? .milktea : .food
                    }
                }
            }
        } label: {
            VStack(spacing: 8) {
                Image(image).resizable().scaledToFit().frame(width: 74, height: 74)
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundColor(.black)
                Text(price.isEmpty ? fallback : price)
                    .font(.system(size: 13, weight: .medium)).foregroundColor(.secondary)
            }
            .frame(width: 108, height: 150)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black.opacity(0.04)))
        }
    }

    // MARK: Other Works — cross-promo to the developer's other apps

    private struct OtherApp: Identifiable {
        let id: String
        let name: String
        let subtitle: String
        let iconAsset: String
        var url: URL { URL(string: "https://apps.apple.com/app/id\(id)")! }
    }

    private static let otherApps: [OtherApp] = [
        OtherApp(id: "6761310915", name: "奶蛙",   subtitle: "点一下就狂笑",        iconAsset: "奶蛙logo"),
        OtherApp(id: "6762385358", name: "奶蛙奏乐", subtitle: "奶蛙专属音乐键盘",  iconAsset: "奶蛙奏乐logo"),
        OtherApp(id: "6760925662", name: "我的刀盾", subtitle: "抽象魔性的赛博神兽", iconAsset: "我的刀盾logo"),
        OtherApp(id: "6760971231", name: "蝶藏",   subtitle: "世界蝴蝶博物馆",      iconAsset: "蝶藏logo"),
        OtherApp(id: "6761893904", name: "浪花",   subtitle: "绝美LED交互海洋",     iconAsset: "浪花logo"),
        OtherApp(id: "6762512673", name: "炉火",   subtitle: "可吹气触摸的LED火焰", iconAsset: "炉火logo"),
        OtherApp(id: "6789243926", name: "雨落",   subtitle: "可触碰的唯美雨天",     iconAsset: "雨落logo"),
    ]

    private var otherWorksSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("其他作品")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.gray)
                .padding(.horizontal, hSizeClass == .regular ? 24 : 32)
                .padding(.bottom, 10)

            VStack(spacing: 0) {
                ForEach(Self.otherApps) { app in
                    otherAppRow(app)
                    if app.id != Self.otherApps.last?.id {
                        divider
                    }
                }
            }
        }
    }

    private func otherAppRow(_ app: OtherApp) -> some View {
        Button {
            UIApplication.shared.open(app.url)
        } label: {
            HStack(spacing: 14) {
                Image(app.iconAsset)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(Color.black.opacity(0.06), lineWidth: 0.5)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.black)
                    Text(app.subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.black.opacity(0.4))
            }
            .padding(.horizontal, hSizeClass == .regular ? 24 : 32)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
    }

    // MARK: Helpers

    private func openURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url)
    }
}

#Preview {
    NavigationStack {
        SettingsView(store: StoreManager(), onClose: {})
    }
}
