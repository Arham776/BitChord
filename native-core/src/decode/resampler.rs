//! Stateful windowed-sinc resampler for the playback path.
//!
//! Same kernel family as the offline `Resample` port in `analyzer` (32
//! zero crossings, Blackman window, kernel table) but streaming: it keeps
//! unconsumed input history across calls so arbitrary-length streams resample
//! with one continuous phase. Interior samples only render once both kernel
//! edges are available; `flush` drains the tail with clamped edges (matching
//! the offline port's edge behavior — no zero-pad ring at track start).

const ZERO_CROSSINGS: f64 = 32.0;
const KERNEL_RESOLUTION: f64 = 512.0;

fn sinc(x: f64) -> f64 {
    if x.abs() < 1e-12 {
        return 1.0;
    }
    let scaled = core::f64::consts::PI * x;
    scaled.sin() / scaled
}

fn blackman(position: f64) -> f64 {
    let two_pi = 2.0 * core::f64::consts::PI;
    0.42 - 0.5 * (two_pi * position).cos() + 0.08 * (two_pi * 2.0 * position).cos()
}

pub struct StreamResampler {
    input_rate: f64,
    output_rate: f64,
    ratio: f64,
    #[allow(dead_code)]
    cutoff: f64,
    half_width: f64,
    kernel: Vec<f64>,
    /// Unconsumed input samples; `history[0]` sits at absolute input
    /// position `history_start`.
    history: Vec<f64>,
    history_start: i64,
    /// Absolute input position of the next output sample's centre.
    next_centre: f64,
    primed: bool,
}

impl StreamResampler {
    pub fn new(input_rate: u32, output_rate: u32) -> Self {
        let input_rate = input_rate as f64;
        let output_rate = output_rate as f64;
        let ratio = output_rate / input_rate;
        let cutoff = 0.5 * ratio.min(1.0);
        let half_width = ZERO_CROSSINGS / (2.0 * cutoff);
        let table_size = (half_width * KERNEL_RESOLUTION).ceil() as usize + 2;
        let mut kernel = Vec::with_capacity(table_size);
        for index in 0..table_size {
            let offset = index as f64 / KERNEL_RESOLUTION;
            let window = blackman((offset + half_width) / (2.0 * half_width));
            kernel.push(2.0 * cutoff * sinc(2.0 * cutoff * offset) * window);
        }
        Self {
            input_rate,
            output_rate,
            ratio,
            cutoff,
            half_width,
            kernel,
            history: Vec::with_capacity((half_width as usize + 1) * 2),
            history_start: 0,
            next_centre: 0.0,
            primed: false,
        }
    }

    pub fn passthrough(&self) -> bool {
        (self.input_rate - self.output_rate).abs() < 1e-6
    }

    /// Pushes input samples, returns resampled output. Call
    /// [`StreamResampler::flush`] at end of stream to drain the kernel tail.
    pub fn process(&mut self, input: &[f32]) -> Vec<f32> {
        if self.passthrough() {
            return input.to_vec();
        }
        self.history.extend(input.iter().map(|v| *v as f64));
        let end = self.history_start + self.history.len() as i64;
        let mut output = Vec::new();
        // Render as soon as the kernel's look-ahead fits in history. The
        // look-behind is always available (history is only dropped up to
        // next_centre - half_width) *except* at stream start, where
        // render_at's edge clamp applies — the same semantics as the offline
        // port's start edge. Gating on look-behind availability here would
        // stall the first sample forever: nothing exists before position 0.
        while self.next_centre + self.half_width < end as f64 {
            let centre = self.next_centre - self.history_start as f64;
            output.push(self.render_at(&self.history, centre));
            self.next_centre += 1.0 / self.ratio;
        }
        // Drop history no future centre can look back into.
        let drop_to = ((self.next_centre - self.half_width).floor() as i64 - self.history_start)
            .clamp(0, self.history.len() as i64) as usize;
        self.history.drain(..drop_to);
        self.history_start += drop_to as i64;
        self.primed = true;
        output
    }

    /// Drains the kernel tail after end-of-stream (clamped edges).
    pub fn flush(&mut self) -> Vec<f32> {
        if self.passthrough() || !self.primed {
            self.history.clear();
            return Vec::new();
        }
        let mut output = Vec::new();
        let end = (self.history_start + self.history.len() as i64 - 1) as f64;
        while self.next_centre <= end {
            let centre = self.next_centre - self.history_start as f64;
            output.push(self.render_at(&self.history, centre));
            self.next_centre += 1.0 / self.ratio;
        }
        self.history.clear();
        self.primed = false;
        output
    }

    fn render_at(&self, full: &[f64], centre: f64) -> f32 {
        let first_tap = (centre - self.half_width).ceil() as i64;
        let last_tap = (centre + self.half_width).floor() as i64;
        let mut sum = 0.0;
        let mut weight_sum = 0.0;
        for tap in first_tap..=last_tap {
            let offset = (centre - tap as f64).abs();
            let scaled = offset * KERNEL_RESOLUTION;
            let slot = scaled as usize;
            if slot + 1 >= self.kernel.len() {
                continue;
            }
            let fraction = scaled - slot as f64;
            let weight = self.kernel[slot] + fraction * (self.kernel[slot + 1] - self.kernel[slot]);
            let clamped = tap.clamp(0, full.len() as i64 - 1) as usize;
            sum += weight * full[clamped];
            weight_sum += weight;
        }
        if weight_sum != 0.0 {
            (sum / weight_sum) as f32
        } else {
            0.0
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unity_rate_passthrough() {
        let mut r = StreamResampler::new(48_000, 48_000);
        let input: Vec<f32> = (0..1000).map(|i| i as f32 / 1000.0).collect();
        assert_eq!(r.process(&input), input);
    }

    #[test]
    fn resample_preserves_dc_and_length_within_tolerance() {
        // 2:1 downsample of a constant signal must stay constant; length ratio
        // within a kernel-width.
        let mut r = StreamResampler::new(48_000, 24_000);
        let input = vec![0.5f32; 48_000];
        let mut out = r.process(&input);
        out.extend(r.flush());
        assert!((out.len() as i64 - 24_000).abs() < 40, "len {}", out.len());
        let mid = &out[1000..2000];
        for v in mid {
            assert!((v - 0.5).abs() < 1e-3, "dc drift {v}");
        }
    }

    #[test]
    fn process_emits_output_before_flush() {
        // Regression: a render gate that waited for look-behind data at
        // stream start stalled the first sample forever — everything only
        // appeared at flush. Mid-stream calls must produce audio.
        let mut r = StreamResampler::new(44_100, 48_000);
        let input: Vec<f32> = (0..24_000).map(|i| ((i as f32) * 0.01).sin() * 0.5).collect();
        let out = r.process(&input);
        assert!(!out.is_empty(), "process() produced nothing before flush");
        assert!(out.len() > 20_000, "suspiciously few samples: {}", out.len());
    }

    #[test]
    fn streaming_matches_whole_buffer_resampling() {
        // Two halves streamed must track one-shot closely.
        let input: Vec<f32> = (0..48_000)
            .map(|i| ((i as f32) * 0.01).sin() * 0.5)
            .collect();
        let mut streamed = StreamResampler::new(48_000, 44_100);
        let mut out = streamed.process(&input[..24_000]);
        out.extend(streamed.process(&input[24_000..]));
        out.extend(streamed.flush());

        let mut whole = StreamResampler::new(48_000, 44_100);
        let mut expected = whole.process(&input);
        expected.extend(whole.flush());
        assert_eq!(out.len(), expected.len());
        let max_diff = out
            .iter()
            .zip(expected.iter())
            .map(|(a, b)| (a - b).abs())
            .fold(0.0f32, f32::max);
        assert!(max_diff < 1e-4, "max diff {max_diff}");
    }

    #[test]
    fn chunked_streaming_matches_two_chunk_streaming() {
        let input: Vec<f32> = (0..96_000)
            .map(|i| ((i as f32) * 0.023).sin() * 0.4)
            .collect();
        let mut a = StreamResampler::new(48_000, 44_100);
        let mut out_a = Vec::new();
        for chunk in input.chunks(4096) {
            out_a.extend(a.process(chunk));
        }
        out_a.extend(a.flush());

        let mut b = StreamResampler::new(48_000, 44_100);
        let mut out_b = b.process(&input);
        out_b.extend(b.flush());
        assert_eq!(out_a.len(), out_b.len());
        let max_diff = out_a
            .iter()
            .zip(out_b.iter())
            .map(|(x, y)| (x - y).abs())
            .fold(0.0f32, f32::max);
        assert!(max_diff < 1e-4, "max diff {max_diff}");
    }
}
