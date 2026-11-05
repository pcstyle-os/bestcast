import SwiftUI

struct EmptyResults: View {
    let text: String
    /// An unused screen names its own subject; a search that found nothing keeps this.
    var symbol = "magnifyingglass"
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.largeTitle)
                .symbolRenderingMode(.hierarchical).foregroundStyle(.tertiary)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
