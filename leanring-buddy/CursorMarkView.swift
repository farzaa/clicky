import SwiftUI

/// Lucide `MousePointer2` equivalent — cursor buddy mark.
struct CursorMarkView: View {
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: "cursorarrow")
            .font(.system(size: size * 0.85, weight: .medium))
            .foregroundStyle(DS.foreground)
            .symbolRenderingMode(.monochrome)
    }
}
