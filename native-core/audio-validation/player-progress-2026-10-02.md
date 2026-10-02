# Player progress and Automix marker — 2026-10-02

Phone logs confirmed Opus/WebM tracks with zero declared/container duration. The maintained extractor supplies duration, but the bridge discarded it. Duration now travels through Kotlin/Swift stream payloads, load requests and growing/completed file metadata. Legacy cache metadata is repaired asynchronously without holding playback behind a network request. The progress fill remains visible during Automix.

The transition marker previously assumed the blend finished at file end. It now uses the constrained plan's transitionEndSeconds and fadeSeconds, falling back to duration only for the initial safety plan. That initial queued safety plan is published immediately while analysis runs.

Validation:
- iOS Debug device build and macOS Release build passed.
- Shared duration bridge tests passed, including compatibility with older payloads.
- Native mixer test `the_blend_ends_at_the_plans_anchor_not_the_file_end` passed.
- iPhone En Ki: 39/39 checks passed with empty queue duration text, including positive resolver duration/progress, actual seeking, nine Next selections at four-second intervals, three Back selections and return to first track. Report: iphone-progress-duration-2026-10-02.json.
- Earlier navigation fixtures supplied a synthetic three-minute duration and therefore missed this regression; this fixture no longer supplies it.
- The transition-marker change is validated against native scheduling semantics; visual alignment during a complete live Automix blend was not observed on hardware in this run.
- Separate macOS live media check served one track; Shooter returned HTTP 403 there. On-device navigation checks passed. No claim of universal provider availability is made.
