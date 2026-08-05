//
//  TaskCenterView.swift
//  MyNaiWa (奶蛙时代)
//
//  每日任务中心 — opened by tapping the 🪙 pill. Shows the balance + the 3 daily
//  tasks with progress and a claim button. White page, matches SettingsView.
//  (Final visual identity will diverge from the old 奶蛙 app later.)
//

import SwiftUI

struct TaskCenterView: View {
    @ObservedObject var economy: Economy
    let onClose: () -> Void
    @Environment(\.horizontalSizeClass) private var hSizeClass

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    // Balance header — big coin above the number.
                    VStack(spacing: 6) {
                        Image("奶币").resizable().scaledToFit().frame(width: 60, height: 60)
                        Text("\(economy.coins)")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundColor(.black)
                            .contentTransition(.numericText())
                        Text("完成活动赚奶币，解锁更多动作和音色")
                            .font(.system(size: 13))
                            .foregroundColor(.gray)
                            .padding(.top, 2)
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 26)

                    // Daily tasks
                    VStack(spacing: 0) {
                        ForEach(Array(DailyTask.all.enumerated()), id: \.element.id) { index, task in
                            taskRow(task)
                            if index < DailyTask.all.count - 1 { divider }
                        }
                    }

                    Text("每日 0 点刷新")
                        .font(.system(size: 12))
                        .foregroundColor(Color(.systemGray2))
                        .padding(.top, 22)
                        .padding(.bottom, 32)
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.black)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }
            ToolbarItem(placement: .principal) {
                Text("活动中心")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.black)
            }
        }
        .animation(.snappy, value: economy.coins)
    }

    private func taskRow(_ task: DailyTask) -> some View {
        let complete = economy.isTaskComplete(task)
        let claimed = economy.isTaskClaimed(task)
        return HStack(spacing: 12) {
            Text(task.emoji)
                .font(.system(size: 26))
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.black)
                HStack(spacing: 3) {
                    Text("+\(task.reward)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(red: 0.95, green: 0.6, blue: 0.15))
                    Image("奶币").resizable().scaledToFit().frame(width: 12, height: 12)
                }
            }
            Spacer()
            claimButton(task, complete: complete, claimed: claimed)
        }
        .padding(.horizontal, hSizeClass == .regular ? 24 : 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private func claimButton(_ task: DailyTask, complete: Bool, claimed: Bool) -> some View {
        if claimed {
            Text("已领取")
                .font(.system(size: 13))
                .foregroundColor(Color(.systemGray2))
                .frame(width: 70, height: 32)
        } else if complete {
            Button {
                _ = economy.claimTask(task)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Text("领取")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 70, height: 32)
                    .background(Capsule().fill(Color.black))
            }
        } else {
            Text("进行中")
                .font(.system(size: 13))
                .foregroundColor(Color(.systemGray2))
                .frame(width: 70, height: 32)
                .background(Capsule().fill(Color(.systemGray6)))
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.black.opacity(0.08))
            .frame(height: 0.5)
            .padding(.horizontal, hSizeClass == .regular ? 24 : 20)
    }
}

#Preview {
    NavigationStack {
        TaskCenterView(economy: Economy(), onClose: {})
    }
}
