//! libsoxr 0.1.3 HQ streaming conversion. A single interleaved handle shares
//! timing across channels; unity-rate streams never touch their samples.
use std::ffi::{c_char, c_void, CStr};
use std::ptr;

#[link(name = "soxr", kind = "static")]
unsafe extern "C" {
    fn soxr_create(
        input_rate: f64,
        output_rate: f64,
        channels: u32,
        error: *mut *const c_char,
        io: *const c_void,
        quality: *const c_void,
        runtime: *const c_void,
    ) -> *mut c_void;
    fn soxr_process(
        handle: *mut c_void,
        input: *const c_void,
        input_frames: usize,
        consumed: *mut usize,
        output: *mut c_void,
        output_frames: usize,
        produced: *mut usize,
    ) -> *const c_char;
    fn soxr_delay(handle: *mut c_void) -> f64;
    fn soxr_clear(handle: *mut c_void) -> *const c_char;
    fn soxr_delete(handle: *mut c_void);
}

pub struct StreamResampler {
    handle: *mut c_void,
    channels: usize,
    ratio: f64,
    drained: bool,
}
// Each handle is exclusively owned and used by one decoder/mixer worker.
unsafe impl Send for StreamResampler {}
impl StreamResampler {
    pub fn new(input_rate: u32, output_rate: u32) -> Self {
        Self::with_rates(input_rate as f64, output_rate as f64)
    }
    pub fn stereo(input_rate: u32, output_rate: u32) -> Self {
        Self::with_channels(input_rate as f64, output_rate as f64, 2)
    }
    pub fn with_rates(input_rate: f64, output_rate: f64) -> Self {
        Self::with_channels(input_rate, output_rate, 1)
    }
    fn with_channels(input_rate: f64, output_rate: f64, channels: usize) -> Self {
        assert!(
            input_rate.is_finite()
                && output_rate.is_finite()
                && input_rate > 0.0
                && output_rate > 0.0
        );
        let mut error = ptr::null();
        let handle = if (input_rate - output_rate).abs() < 1e-6 {
            ptr::null_mut()
        } else {
            // Null specs select float32 interleaved, HQ, one worker in the pinned C API.
            unsafe {
                soxr_create(
                    input_rate,
                    output_rate,
                    channels as u32,
                    &mut error,
                    ptr::null(),
                    ptr::null(),
                    ptr::null(),
                )
            }
        };
        assert!(error.is_null(), "soxr create: {}", message(error));
        assert!(
            !handle.is_null() || (input_rate - output_rate).abs() < 1e-6,
            "soxr allocation failed"
        );
        Self {
            handle,
            channels,
            ratio: output_rate / input_rate,
            drained: false,
        }
    }
    pub fn passthrough(&self) -> bool {
        self.handle.is_null()
    }
    pub fn delay_frames(&self) -> f64 {
        if self.passthrough() {
            0.0
        } else {
            unsafe { soxr_delay(self.handle) }
        }
    }
    pub fn reset(&mut self) {
        if !self.passthrough() {
            let error = unsafe { soxr_clear(self.handle) };
            assert!(error.is_null(), "soxr reset: {}", message(error));
        }
        self.drained = false;
    }
    pub fn process(&mut self, input: &[f32]) -> Vec<f32> {
        assert_eq!(input.len() % self.channels, 0);
        if self.passthrough() {
            return input.to_vec();
        }
        assert!(!self.drained, "reset drained converter before reuse");
        let mut result = Vec::new();
        let mut cursor = 0;
        while cursor < input.len() {
            let frames = (input.len() - cursor) / self.channels;
            let capacity = (frames as f64 * self.ratio).ceil() as usize + 8192;
            let mut out = vec![0.0f32; capacity * self.channels];
            let (mut consumed, mut produced) = (0, 0);
            let error = unsafe {
                soxr_process(
                    self.handle,
                    input[cursor..].as_ptr().cast(),
                    frames,
                    &mut consumed,
                    out.as_mut_ptr().cast(),
                    capacity,
                    &mut produced,
                )
            };
            assert!(error.is_null(), "soxr process: {}", message(error));
            assert!(consumed > 0 || produced > 0, "soxr made no progress");
            result.extend_from_slice(&out[..produced * self.channels]);
            cursor += consumed * self.channels;
        }
        result
    }
    pub fn flush(&mut self) -> Vec<f32> {
        if self.passthrough() || self.drained {
            return Vec::new();
        }
        self.drained = true;
        let mut result = Vec::new();
        loop {
            let mut out = vec![0.0f32; 8192 * self.channels];
            let mut produced = 0;
            let error = unsafe {
                soxr_process(
                    self.handle,
                    ptr::null(),
                    0,
                    ptr::null_mut(),
                    out.as_mut_ptr().cast(),
                    8192,
                    &mut produced,
                )
            };
            assert!(error.is_null(), "soxr flush: {}", message(error));
            result.extend_from_slice(&out[..produced * self.channels]);
            if produced == 0 {
                break;
            }
        }
        result
    }
}
impl Drop for StreamResampler {
    fn drop(&mut self) {
        if !self.handle.is_null() {
            unsafe { soxr_delete(self.handle) };
        }
    }
}
fn message(error: *const c_char) -> String {
    if error.is_null() {
        String::new()
    } else {
        unsafe { CStr::from_ptr(error) }
            .to_string_lossy()
            .into_owned()
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
        let input: Vec<f32> = (0..24_000)
            .map(|i| ((i as f32) * 0.01).sin() * 0.5)
            .collect();
        let out = r.process(&input);
        assert!(!out.is_empty(), "process() produced nothing before flush");
        assert!(
            out.len() > 20_000,
            "suspiciously few samples: {}",
            out.len()
        );
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
    #[test]
    fn stereo_chunk_boundaries_and_drain_are_exact() {
        let input: Vec<f32> = (0..44101)
            .flat_map(|i| {
                let s = (i as f32 * 0.093).sin() * 0.2;
                [s, -s]
            })
            .collect();
        let render = |chunk: usize| {
            let mut r = StreamResampler::stereo(44100, 48000);
            let mut out = Vec::new();
            for b in input.chunks(chunk * 2) {
                out.extend(r.process(b));
            }
            out.extend(r.flush());
            assert!(r.flush().is_empty());
            out
        };
        let baseline = render(44101);
        assert_eq!(
            baseline.len() / 2,
            (44101f64 * 48000.0 / 44100.0).round() as usize
        );
        for chunk in [1, 7, 511, 4096] {
            let x = render(chunk);
            assert_eq!(x.len(), baseline.len());
            assert!(x.iter().zip(&baseline).all(|(a, b)| (a - b).abs() < 2e-7));
            assert!(x.chunks_exact(2).all(|p| (p[0] + p[1]).abs() < 1e-7));
        }
    }

    fn spectral_amplitude(pcm: &[f32], rate: u32, hz: f64) -> f64 {
        let frames = pcm.len() / 2;
        let start = rate as usize / 4;
        let end = (rate as usize * 3 / 4).min(frames);
        let (mut c, mut s) = (0.0, 0.0);
        for i in start..end {
            let phase = 2.0 * std::f64::consts::PI * hz * i as f64 / rate as f64;
            c += pcm[i * 2] as f64 * phase.cos();
            s += pcm[i * 2] as f64 * phase.sin();
        }
        2.0 * c.hypot(s) / (end - start) as f64
    }
    #[test]
    fn hq_conversion_meets_passband_and_alias_gates() {
        let tone = |input: u32, output: u32, hz: f64| {
            let x: Vec<f32> = (0..input)
                .flat_map(|i| {
                    let x = (2.0 * std::f64::consts::PI * hz * i as f64 / input as f64).sin()
                        as f32
                        * 0.5;
                    [x, -x]
                })
                .collect();
            let mut r = StreamResampler::stereo(input, output);
            let mut y = r.process(&x);
            y.extend(r.flush());
            y
        };
        for (input, output) in [(44100, 48000), (48000, 44100)] {
            for hz in [100.0, 1000.0, 10000.0, 19000.0, 20000.0] {
                let y = tone(input, output, hz);
                let db = 20.0 * (spectral_amplitude(&y, output, hz) / 0.5).log10();
                assert!(db.abs() <= 0.05, "{input}→{output}, {hz}: {db} dB");
            }
        }
        for (input, output, hz, image) in [
            (48000, 44100, 23000.0, 21100.0),
            (44100, 48000, 21500.0, 22600.0),
        ] {
            let y = tone(input, output, hz);
            let db = 20.0 * spectral_amplitude(&y, output, image).max(1e-15).log10();
            assert!(db <= -100.0, "{input}→{output} image: {db} dBFS");
        }
    }
}
