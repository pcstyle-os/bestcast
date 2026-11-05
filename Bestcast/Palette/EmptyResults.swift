import SwiftUI

struct EmptyResults: View {
    let text: String
    /// An unused screen names its own subject; a search that found nothing keeps this.
    var symbol = "magnifyingglass"
    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: symbol).font(.largeTitle)
                .symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
