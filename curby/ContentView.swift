//
//  ContentView.swift
//  curby
//
//  Created by Mohammad Rashid on 11/1/1447 AH.


import SwiftUI

/// Root composition view — creates all dependencies and presents the map.
struct ContentView: View {

    // MARK: - Dependencies

    /// Location data source — provides GPS coordinates, speed, heading.
    @State private var locationService = LocationService()

    /// Motion classification — stationary / walking / driving.
    @State private var motionStateManager: MotionStateManager

    /// Camera orchestrator — viewport state, follow/explore modes.
    @State private var cameraController: CameraController

    // MARK: - Init

    init() {
        let location = LocationService()
        let motion = MotionStateManager(locationService: location)
        let camera = CameraController(locationService: location, motionStateManager: motion)

        _locationService = State(initialValue: location)
        _motionStateManager = State(initialValue: motion)
        _cameraController = State(initialValue: camera)
    }

    // MARK: - Body

    var body: some View {
        CurbyMapView(
            cameraController: cameraController,
            locationService: locationService,
            motionStateManager: motionStateManager
        )
        .onAppear {
            locationService.requestPermission()
        }
    }
}

#Preview {
    ContentView()
}
