import SwiftUI

/// Upstream `LyricsOffsetSheet`: the listener's own correction to synced lyrics.
///
/// ## Why it exists
///
/// Word-synced timings are only as good as the copy they were made for, and the
/// copy you are hearing is not always the copy they were made against — a
/// different encode, a different release, a Bluetooth route with its own
/// latency. A consistent 200 ms of lag on every track is not something to report,
/// it is something to correct once and forget.
///
/// ## Why the range is generous
///
/// ±5 s, in 100 ms steps, is upstream's. The upper half is for the case where
/// the timings are for a *different* recording of the same song — an intro that
/// is longer on the version you have. The lower half is for round-trip delay.
/// Both ends are real reasons to reach for this control, and a range that only
/// covered the first would make the second impossible to fix.
struct LyricsOffsetSheet: View {
    @Environment(PlaybackController.self) private var controller
    @Environment(\.dismiss) private var dismiss

    /// Read from the engine's own settings rather than a `@State` copy, so the
    /// slider and the stepper buttons cannot disagree about the value: both are
    /// writing and re-reading the one number.
    private var offsetMs: Int32 {
        LyricsOffsetBridge.offsetMs()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer(minLength: 12)

                // The value, large, so the sheet is legible at arm's length —
                // this is a control adjusted by feel while a track plays, and
                // the number is the feedback.
                Text(LyricsOffsetBridge.format(offsetMs))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy, value: offsetMs)
                    .foregroundStyle(.primary)
                    .padding(.bottom, 4)

                Text("Positive values show lyrics later")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 24)

                // The buttons, either side of the slider, so the sheet can be
                // worked entirely from the two — a drag on a trackpad is not
                // available to everyone, and 100 ms is a fine grain to aim at.
                HStack(spacing: 20) {
                    stepButton("minus", label: "Earlier", delta: -LyricsOffsetBridge.stepMs) {
                        LyricsOffsetBridge.decrease()
                    }
                    Slider(
                        value: Binding(
                            get: { LyricsOffsetBridge.fraction(offsetMs) },
                            set: { LyricsOffsetBridge.set(fraction: $0) }
                        ),
                        in: 0...1
                    )
                    .accessibilityLabel("Lyrics offset")
                    .accessibilityValue(LyricsOffsetBridge.format(offsetMs))
                    .accessibilityHint("Swipe up or down to adjust when the lyrics appear")
                    stepButton("plus", label: "Later", delta: LyricsOffsetBridge.stepMs) {
                        LyricsOffsetBridge.increase()
                    }
                }
                .padding(.horizontal, 28)

                // Reset, and only while there is something to reset. A disabled
                // button is a worse answer than a button that is not there.
                if offsetMs != 0 {
                    Button("Reset") {
                        LyricsOffsetBridge.reset()
                    }
                    .padding(.top, 20)
                }

                Spacer(minLength: 0)

                Text("""
                    This is a preference, not a per-track setting — the same lag \
                    applies to every track, so it is set once.
                    """)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 20)
            }
            .navigationTitle("Lyrics Offset")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(iOS)
        // Upstream puts its player sheets up as a bottom drawer: dark over a
        // scrim, a grab handle, a title, drag down to put it away. The handle
        // and the drag are what `.presentationDetents` and
        // `.presentationDragIndicator` are *for* — building a handle by hand
        // would be a second, worse implementation of a control the platform
        // already has, and one that would not animate with the sheet.
        .presentationDetents([.height(340)])
        .presentationDragIndicator(.visible)
        #endif
    }

    /// A −/+ button, disabled at whichever end of the range it has reached.
    ///
    /// Disabled rather than clamped-and-silent: a button that stops doing
    /// anything should say so, and `LyricsOffset` clamping as well is belt and
    /// braces for the case where the stored value was out of range to begin with.
    private func stepButton(
        _ icon: String, label: String, delta: Int32, action: @escaping () -> Void
    ) -> some View {
        let atLimit = delta < 0
            ? offsetMs <= LyricsOffsetBridge.minMs
            : offsetMs >= LyricsOffsetBridge.maxMs
        return Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .bold))
                .frame(width: 44, height: 44)
                .background(.quaternary, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(atLimit)
        .opacity(atLimit ? 0.35 : 1)
        .accessibilityLabel(label)
    }
}
