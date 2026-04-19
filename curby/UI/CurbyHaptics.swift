//
//  CurbyHaptics.swift
//  curby
//
//  Centralized UIKit haptics for consistent tactile feedback.
//

import UIKit

enum CurbyHaptics {

    /// Light taps: toggles, recenter, secondary actions.
    static func light() {
        impact(.light)
    }

    /// Default feedback: selections, sheet controls.
    static func medium() {
        impact(.medium)
    }

    /// Strong emphasis: dropped pin, primary confirmations.
    static func heavy() {
        impact(.heavy)
    }

    /// Picker / list selection changes.
    static func selection() {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }

    /// Success, warning, or error outcomes.
    static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(type)
    }

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }
}
