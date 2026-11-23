import SwiftUI

struct DocumentBibliographyButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "books.vertical")
                .font(.system(size: 14))
                .foregroundStyle(Color(white: 0.35))
                .frame(width: 24, height: 24)
                .enlargedHitTarget(width: 32, height: 28)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Linked BibTeX")
        .help("View the document’s linked BibTeX entry")
    }
}
