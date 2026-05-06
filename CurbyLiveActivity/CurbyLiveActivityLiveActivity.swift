//
//  CurbyLiveActivityLiveActivity.swift
//  CurbyLiveActivity
//
//  Created by Bilal Shihab on 5/5/26.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct CurbyLiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // Dynamic stateful properties about your activity go here!
        var emoji: String
    }

    // Fixed non-changing properties about your activity go here!
    var name: String
}

struct CurbyLiveActivityLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CurbyLiveActivityAttributes.self) { context in
            // Lock screen/banner UI goes here
            VStack {
                Text("Hello \(context.state.emoji)")
            }
            .activityBackgroundTint(Color.cyan)
            .activitySystemActionForegroundColor(Color.black)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI goes here.  Compose the expanded UI through
                // various regions, like leading/trailing/center/bottom
                DynamicIslandExpandedRegion(.leading) {
                    Text("Leading")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("Trailing")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Bottom \(context.state.emoji)")
                    // more content
                }
            } compactLeading: {
                Text("L")
            } compactTrailing: {
                Text("T \(context.state.emoji)")
            } minimal: {
                Text(context.state.emoji)
            }
            .widgetURL(URL(string: "http://www.apple.com"))
            .keylineTint(Color.red)
        }
    }
}

extension CurbyLiveActivityAttributes {
    fileprivate static var preview: CurbyLiveActivityAttributes {
        CurbyLiveActivityAttributes(name: "World")
    }
}

extension CurbyLiveActivityAttributes.ContentState {
    fileprivate static var smiley: CurbyLiveActivityAttributes.ContentState {
        CurbyLiveActivityAttributes.ContentState(emoji: "😀")
     }
     
     fileprivate static var starEyes: CurbyLiveActivityAttributes.ContentState {
         CurbyLiveActivityAttributes.ContentState(emoji: "🤩")
     }
}

#Preview("Notification", as: .content, using: CurbyLiveActivityAttributes.preview) {
   CurbyLiveActivityLiveActivity()
} contentStates: {
    CurbyLiveActivityAttributes.ContentState.smiley
    CurbyLiveActivityAttributes.ContentState.starEyes
}
