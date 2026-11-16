import AppKit
import SwiftUI

/// Neutral near-black background. Colour lives in the controls, not in the canvas.
struct AppBackground: View {
    var body: some View {
        Color(red: 0.032, green: 0.034, blue: 0.040)
            .ignoresSafeArea()
    }
}
