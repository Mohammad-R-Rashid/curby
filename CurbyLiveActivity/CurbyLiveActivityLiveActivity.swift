//
//  CurbyLiveActivityLiveActivity.swift
//  CurbyLiveActivity
//
//  Lock-screen banner + Dynamic Island UI for the Curby parking Live Activity.
//  The `CurbyLiveActivityAttributes` struct lives in the main app target
//  (curby/LiveActivity/CurbyLiveActivityAttributes.swift) and is also a
//  member of this widget target.
//

import ActivityKit
import SwiftUI
import WidgetKit

struct CurbyLiveActivityLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CurbyLiveActivityAttributes.self) { context in
            // ── Lock screen / banner ──
            LockScreenView(context: context)
                .activityBackgroundTint(.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)

        } dynamicIsland: { context in
            // ── Dynamic Island ──
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.attributes.parkingName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: "p.circle.fill")
                            .foregroundStyle(.blue)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(context.state.etaText)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                        Text(context.state.distanceText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.hasEnteredWalkingRadius {
                        Link(destination: URL(string: "curby://refine-parking")!) {
                            HStack(spacing: 6) {
                                Image(systemName: "sparkles")
                                Text("Open Curby to refine parking")
                                    .font(.system(size: 13, weight: .semibold))
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.right.square.fill")
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.blue.gradient, in: RoundedRectangle(cornerRadius: 10))
                        }
                    } else {
                        HStack(spacing: 8) {
                            Text("Heading to \(context.attributes.destinationName)")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            BusynessChip(label: context.state.busynessLabel)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "p.circle.fill")
                    .foregroundStyle(.blue)
            } compactTrailing: {
                Text(context.state.etaText)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            } minimal: {
                Image(systemName: "p.circle.fill")
                    .foregroundStyle(.blue)
            }
            .widgetURL(URL(string: "curby://refine-parking"))
            .keylineTint(.blue)
        }
    }
}

// MARK: - Lock Screen

private struct LockScreenView: View {
    let context: ActivityViewContext<CurbyLiveActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "p.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.parkingName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("near \(context.attributes.destinationName)")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(context.state.etaText)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(context.state.distanceText)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }

            if context.state.hasEnteredWalkingRadius {
                Link(destination: URL(string: "curby://refine-parking")!) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                        Text("Open Curby to refine parking")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color.blue.gradient, in: RoundedRectangle(cornerRadius: 10))
                }
            } else {
                HStack(spacing: 8) {
                    BusynessChip(label: context.state.busynessLabel)
                    Spacer()
                    Text("Tap to refine when you arrive")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
        }
        .padding(14)
    }
}

// MARK: - Busyness Chip

private struct BusynessChip: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint, in: Capsule())
    }

    private var tint: Color {
        switch label.lowercased() {
        case "open": return .green
        case "busy": return .orange
        case "very busy": return .red
        default: return .gray
        }
    }
}

#Preview("Lock screen", as: .content, using: CurbyLiveActivityAttributes.preview) {
    CurbyLiveActivityLiveActivity()
} contentStates: {
    CurbyLiveActivityAttributes.ContentState.driving
    CurbyLiveActivityAttributes.ContentState.arrived
}

extension CurbyLiveActivityAttributes {
    fileprivate static var preview: CurbyLiveActivityAttributes {
        CurbyLiveActivityAttributes(
            destinationName: "Apple Park",
            parkingName: "Visitor Garage",
            walkingRadiusMeters: 400
        )
    }
}

extension CurbyLiveActivityAttributes.ContentState {
    fileprivate static var driving: CurbyLiveActivityAttributes.ContentState {
        .init(
            distanceToDestinationMeters: 4_300,
            etaMinutes: 11,
            hasEnteredWalkingRadius: false,
            busynessLabel: "Busy",
            lastUpdated: .now
        )
    }
    fileprivate static var arrived: CurbyLiveActivityAttributes.ContentState {
        .init(
            distanceToDestinationMeters: 220,
            etaMinutes: 1,
            hasEnteredWalkingRadius: true,
            busynessLabel: "Open",
            lastUpdated: .now
        )
    }
}
