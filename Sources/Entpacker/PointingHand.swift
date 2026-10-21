import AppKit
import SwiftUI

enum PointingHand {
    private static var depth = 0

    static func enter() {
        depth += 1
        NSCursor.pointingHand.set()
    }

    static func leave() {
        depth = max(depth - 1, 0)
        if depth == 0 {
            NSCursor.arrow.set()
        } else {
            NSCursor.pointingHand.set()
        }
    }
}

private struct PointingHandModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if hovering, isEnabled {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.16))
                        .allowsHitTesting(false)
                }
            }
            .onContinuousHover { phase in
                guard isEnabled else {
                    if hovering {
                        hovering = false
                        PointingHand.leave()
                    }
                    return
                }
                switch phase {
                case .active:
                    if !hovering {
                        hovering = true
                        PointingHand.enter()
                    }
                case .ended:
                    if hovering {
                        hovering = false
                        PointingHand.leave()
                    }
                }
            }
            .onDisappear {
                if hovering {
                    hovering = false
                    PointingHand.leave()
                }
            }
    }
}

extension View {
    func pointingHand() -> some View {
        modifier(PointingHandModifier())
    }
}
