//
//  curbyApp.swift
//  curby
//
//  Created by Mohammad Rashid on 11/1/1447 AH.
//

import SwiftUI

@main
struct curbyApp: App {

    @AppStorage("curby_has_completed_onboarding") private var hasCompletedOnboarding = false

    var body: some Scene {
        WindowGroup {
            if hasCompletedOnboarding {
                MainNavigationView()
            } else {
                OnboardingView(hasCompletedOnboarding: $hasCompletedOnboarding)
            }
        }
    }
}
