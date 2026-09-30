//! Reference libopus decoding with explicit stereo layout, header gain and
//! bounded pre-skip spanning packets. Container trims and header pre-skip must
//! not be applied twice.
use super::DecodeError;
use symphonia::core::{
    audio::{
        layouts, AsGenericAudioBufferRef, AudioBuffer, AudioMut, AudioSpec, GenericAudioBufferRef,
    },
    codecs::{
        audio::{AudioCodecParameters, AudioDecoder, AudioDecoderOptions, FinalizeResult},
        registry::RegisterableAudioDecoder,
        CodecInfo,
    },
    errors::Result,
    packet::PacketRef,
};

pub struct OpusDecoder {
    inner: Box<dyn AudioDecoder>,
    params: AudioCodecParameters,
    buffer: AudioBuffer<f32>,
    skip: usize,
    gain: f32,
}
impl OpusDecoder {
    pub fn open(
        params: &AudioCodecParameters,
        at_start: bool,
    ) -> std::result::Result<Box<dyn AudioDecoder>, DecodeError> {
        let mut params = params.clone();
        let count = params.channels.as_ref().map(|c| c.count()).unwrap_or(0);
        params.channels = Some(match count {
            1 => layouts::CHANNEL_LAYOUT_MONO,
            2 => layouts::CHANNEL_LAYOUT_STEREO,
            _ => {
                return Err(DecodeError(
                    "unsupported Opus mapping: positioned mono/stereo required".into(),
                ))
            }
        });
        let mut skip = 0;
        let mut gain = 1.0;
        if let Some(extra) = params.extra_data.as_mut() {
            if extra.len() >= 19 && &extra[..8] == b"OpusHead" {
                skip = u16::from_le_bytes([extra[10], extra[11]]) as usize;
                gain =
                    10f32.powf(i16::from_le_bytes([extra[16], extra[17]]) as f32 / (256.0 * 20.0));
                // This wrapper owns the delay across packets and across seeks.
                extra[10] = 0;
                extra[11] = 0;
            }
        }
        let rate = params.sample_rate.unwrap_or(48000);
        skip = skip * rate as usize / 48000;
        let inner = symphonia_adapter_libopus::OpusDecoder::try_registry_new(
            &params,
            &AudioDecoderOptions::default(),
        )
        .map_err(|e| DecodeError(format!("Opus: {e}")))?;
        let spec = AudioSpec::new(rate, params.channels.clone().unwrap());
        Ok(Box::new(Self {
            inner,
            params,
            buffer: AudioBuffer::new(spec, 5760),
            skip: if at_start { skip } else { 0 },
            gain,
        }))
    }
}
impl AudioDecoder for OpusDecoder {
    fn reset(&mut self) {
        self.inner.reset();
        self.skip = 0;
        self.buffer.clear();
    }
    fn codec_info(&self) -> &CodecInfo {
        self.inner.codec_info()
    }
    fn codec_params(&self) -> &AudioCodecParameters {
        &self.params
    }
    fn decode_ref(&mut self, packet: &PacketRef<'_>) -> Result<GenericAudioBufferRef<'_>> {
        let decoded = self.inner.decode_ref(packet)?;
        let mut pcm = Vec::new();
        super::copy_interleaved_f32(&decoded, &mut pcm);
        let count = self.params.channels.as_ref().unwrap().count();
        let frames = pcm.len() / count;
        for value in &mut pcm {
            *value *= self.gain;
        }
        self.buffer.clear();
        self.buffer.render_uninit(Some(frames));
        self.buffer.copy_from_slice_interleaved(&&pcm[..]);
        self.skip = self.skip.saturating_sub(packet.trim_start.get() as usize);
        let trim = self.skip.min(frames);
        self.skip -= trim;
        self.buffer.trim(trim, 0);
        Ok(self.buffer.as_generic_audio_buffer_ref())
    }
    fn finalize(&mut self) -> FinalizeResult {
        self.inner.finalize()
    }
    fn last_decoded(&self) -> GenericAudioBufferRef<'_> {
        self.buffer.as_generic_audio_buffer_ref()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use symphonia::core::{
        audio::{Channels, Position},
        packet::PacketBuilder,
    };
    fn params(skip: u16, gain: i16) -> AudioCodecParameters {
        let mut head = b"OpusHead\x01\x02".to_vec();
        head.extend(skip.to_le_bytes());
        head.extend(48000u32.to_le_bytes());
        head.extend(gain.to_le_bytes());
        head.push(0);
        let mut p = AudioCodecParameters::new();
        p.for_codec(symphonia::core::codecs::audio::well_known::CODEC_ID_OPUS)
            .with_sample_rate(48000)
            .with_channels(Channels::from(Position::FRONT_LEFT | Position::FRONT_RIGHT))
            .with_extra_data(head.into_boxed_slice());
        p
    }
    #[test]
    fn header_delay_can_span_multiple_packets() {
        let mut decoder = OpusDecoder::open(&params(1920, 0), true).unwrap();
        let packet = PacketBuilder::new()
            .track_id(0)
            .pts(symphonia::core::units::Timestamp::ZERO)
            .dur(symphonia::core::units::Duration::new(960))
            .data(vec![0xf8, 0xff, 0xfe].into_boxed_slice())
            .build();
        assert_eq!(decoder.decode(&packet).unwrap().frames(), 0);
        assert_eq!(decoder.decode(&packet).unwrap().frames(), 0);
        assert_eq!(decoder.decode(&packet).unwrap().frames(), 960);
        let mut sought = OpusDecoder::open(&params(1920, 0), false).unwrap();
        assert_eq!(sought.decode(&packet).unwrap().frames(), 960);
    }
    #[test]
    fn codec_output_gain_is_applied_to_pcm() {
        unsafe extern "C" {
            fn opus_encoder_create(
                rate: i32,
                channels: i32,
                application: i32,
                error: *mut i32,
            ) -> *mut std::ffi::c_void;
            fn opus_encode_float(
                encoder: *mut std::ffi::c_void,
                input: *const f32,
                frames: i32,
                data: *mut u8,
                max: i32,
            ) -> i32;
            fn opus_encoder_destroy(encoder: *mut std::ffi::c_void);
        }
        let mut status = 0;
        let encoder = unsafe { opus_encoder_create(48000, 2, 2049, &mut status) };
        assert_eq!(status, 0);
        assert!(!encoder.is_null());
        let pcm: Vec<f32> = (0..960)
            .flat_map(|i| {
                let s = (i as f32 * 0.137).sin() * 0.1;
                [s, s]
            })
            .collect();
        let mut bytes = vec![0u8; 4000];
        let n = unsafe { opus_encode_float(encoder, pcm.as_ptr(), 960, bytes.as_mut_ptr(), 4000) };
        unsafe { opus_encoder_destroy(encoder) };
        assert!(n > 0);
        bytes.truncate(n as usize);
        let packet = PacketBuilder::new()
            .track_id(0)
            .pts(symphonia::core::units::Timestamp::ZERO)
            .dur(symphonia::core::units::Duration::new(960))
            .data(bytes.into_boxed_slice())
            .build();
        let mut unity = OpusDecoder::open(&params(0, 0), true).unwrap();
        let mut boosted = OpusDecoder::open(&params(0, 1792), true).unwrap();
        let mut a = Vec::new();
        super::super::copy_interleaved_f32(&unity.decode(&packet).unwrap(), &mut a);
        let mut b = Vec::new();
        super::super::copy_interleaved_f32(&boosted.decode(&packet).unwrap(), &mut b);
        let expected = 10f32.powf(7.0 / 20.0);
        assert!(a.iter().any(|v| v.abs() > 0.01));
        for (a, b) in a.into_iter().zip(b) {
            assert!((a * expected - b).abs() < 1e-6);
        }
    }
}
