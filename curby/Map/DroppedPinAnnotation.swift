//
//  DroppedPinAnnotation.swift
//  curby
//
//  Draggable pin the user drops by long-pressing the map.
//

import SwiftUI

/// The visual pin that animates in on drop and lifts while being dragged.
struct DroppedPinView: View {
    @Binding var isDragging: Bool
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: () -> Void
    let onTap: () -> Void

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            // Head
            ZStack {
                // Ground shadow — lifts when dragging
                Ellipse()
                    .fill(.black.opacity(isDragging ? 0.18 : 0.09))
                    .frame(
                        width: isDragging ? 54 : 40,
                        height: isDragging ? 18 : 10
                    )
                    .blur(radius: isDragging ? 8 : 3)
                    .offset(y: isDragging ? 30 : 22)

                Circle()
                    .fill(.white)
                    .frame(width: 46, height: 46)
                    .shadow(
                        color: .black.opacity(isDragging ? 0.22 : 0.10),
                        radius: isDragging ? 14 : 5,
                        y: isDragging ? 10 : 3
                    )

                Image(systemName: "mappin.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 34, height: 34)
                    .foregroundStyle(Color.accentColor)
            }
            .scaleEffect(isDragging ? 1.22 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.52), value: isDragging)

            // Stem
            Rectangle()
                .fill(.white)
                .frame(width: 3, height: 8)
                .shadow(color: .black.opacity(0.08), radius: 1, y: 1)

            // Tip
            Triangle()
                .fill(.white)
                .frame(width: 9, height: 6)
                .rotationEffect(.degrees(180))
                .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
                .offset(y: -1)
        }
        .scaleEffect(appeared ? 1.0 : 0.05)
        .offset(y: appeared ? 0 : -30)
        .onAppear {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.48)) {
                appeared = true
            }
        }
        .onTapGesture {
            onTap()
        }
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    if !isDragging { isDragging = true }
                    onDragChanged(value.translation)
                }
                .onEnded { _ in
                    isDragging = false
                    onDragEnded()
                }
        )
    }
}
