import GumboCore
import SwiftUI

/// A single Form row for file work, with an independently accessible stop action.
struct OperationProgressView: View {
    let title: String
    var subtitle: String? = nil
    var currentItem: String? = nil
    var fractionCompleted: Double? = nil
    var counter: String? = nil
    var isStopping = false
    let onStop: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 16) {
                    heading
                    Spacer(minLength: 0)
                    stopButton
                }
                VStack(alignment: .leading, spacing: 4) {
                    heading
                    stopButton
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let fractionCompleted {
                    ProgressView(value: min(1, max(0, fractionCompleted)))
                        .progressViewStyle(.linear)
                        .tint(Palette.accent)
                        .accessibilityLabel(title)
                        .accessibilityValue(counter ?? "")
                }
                if let counter {
                    Text(counter)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if let currentItem, !currentItem.isEmpty {
                    Text(currentItem)
                        .font(.subheadline)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var heading: some View {
        HStack(spacing: 10) {
            if fractionCompleted == nil {
                ProgressView()
                    .controlSize(.small)
                    .tint(Palette.accent)
                    .accessibilityHidden(true)
            }
            Text(isStopping ? "Stopping…" : title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stopButton: some View {
        Button(action: onStop) {
            Text("Stop")
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Palette.accent.opacity(0.08), in: Capsule())
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
            #if os(tvOS)
            .buttonStyle(.bordered)
            #else
            .buttonStyle(.plain)
            #endif
            .foregroundStyle(Palette.accent)
            .opacity(isStopping ? 0.5 : 1)
            .disabled(isStopping)
            .accessibilityIdentifier("operation.stop")
    }
}
