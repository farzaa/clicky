import SwiftUI

/// Star row; interactive when `onChange` is provided.
struct StarRatingView: View {
    var rating: Int
    var maxStars: Int = 5
    /// Slightly smaller so file rows don’t squeeze text in narrow panels.
    var size: CGFloat = 11
    var onChange: ((Int) -> Void)? = nil

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1 ... maxStars, id: \.self) { i in
                if let onChange {
                    Button {
                        onChange(i)
                    } label: {
                        Image(systemName: i <= rating ? "star.fill" : "star")
                            .font(.system(size: size))
                            .foregroundStyle(DS.foreground)
                    }
                    .buttonStyle(.plain)
                } else {
                    Image(systemName: i <= rating ? "star.fill" : "star")
                        .font(.system(size: size))
                        .foregroundStyle(DS.foreground)
                }
            }
        }
        .accessibilityLabel("Rating \(rating) out of \(maxStars)")
    }
}
