import SwiftUI
import VetCore

/// The Liquid Glass icon rail: Review, Files, Browser, and Run at the bottom.
struct RailView: View {
    static let width: CGFloat = 56
    let state: ShellState
    let onSelect: (RailTab) -> Void

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(spacing: 10) {
                ForEach(RailTab.allCases) { tab in
                    RailButton(tab: tab, isSelected: state.selected == tab, badge: state.badges[tab] ?? 0) {
                        onSelect(tab)
                    }
                }
                Spacer()
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 38, height: 38)
                    .glassEffect(.regular, in: .circle)
                    .help("Run (coming soon)")
            }
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RailButton: View {
    let tab: RailTab
    let isSelected: Bool
    let badge: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: tab.symbolName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .frame(width: 38, height: 38)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(isSelected ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .circle)
        .overlay(alignment: .topTrailing) {
            if badge > 0 {
                Text("\(badge)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 15, minHeight: 15)
                    .background(Capsule().fill(.red))
                    .offset(x: 4, y: -4)
            }
        }
        .help(tab.title)
    }
}
