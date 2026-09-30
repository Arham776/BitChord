//! AAC AudioSpecificConfig stays intact: no forced LC, channel or rate rewrite.
use super::{aac_audio_object_type, DecodeError};
use std::ffi::c_void;
use symphonia::core::audio::{
    AsGenericAudioBufferRef, AudioBuffer, AudioMut, AudioSpec, GenericAudioBufferRef,
};
use symphonia::core::codecs::audio::{AudioCodecParameters, AudioDecoder, FinalizeResult};
use symphonia::core::codecs::CodecInfo;
use symphonia::core::errors::{Error, Result};
use symphonia::core::packet::PacketRef;

unsafe extern "C" {
    fn bch_aac_create(
        asc: *const u8,
        size: u32,
        rate: *mut f64,
        channels: *mut u32,
        mask: *mut u64,
        he: i32,
        ps: i32,
        error: *mut i32,
    ) -> *mut c_void;
    fn bch_aac_decode(
        handle: *mut c_void,
        packet: *const u8,
        size: u32,
        output: *mut f32,
        capacity: u32,
        frames: *mut u32,
    ) -> i32;
    fn bch_aac_reset(handle: *mut c_void);
    fn bch_aac_destroy(handle: *mut c_void);
}
pub struct AppleAacDecoder {
    handle: *mut c_void,
    params: AudioCodecParameters,
    buffer: AudioBuffer<f32>,
    pcm: Vec<f32>,
    trim_scale: f64,
}
// AudioDecoder ownership stays on one decode worker; accesses require &mut self.
unsafe impl Send for AppleAacDecoder {}
unsafe impl Sync for AppleAacDecoder {}
impl AppleAacDecoder {
    pub fn open(
        params: &AudioCodecParameters,
    ) -> std::result::Result<Box<dyn AudioDecoder>, DecodeError> {
        let asc = params
            .extra_data
            .as_ref()
            .ok_or_else(|| DecodeError("AAC has no AudioSpecificConfig".into()))?;
        let mut rate = params.sample_rate.unwrap_or(0) as f64;
        let mut channels = params
            .channels
            .as_ref()
            .map(|c| c.count() as u32)
            .unwrap_or(0);
        let mut error = 0;
        let mut mask = 0u64;
        let he = super::is_he_aac(params);
        let ps = aac_audio_object_type(asc) == Some(29);
        let handle = unsafe {
            bch_aac_create(
                asc.as_ptr(),
                asc.len() as u32,
                &mut rate,
                &mut channels,
                &mut mask,
                he as i32,
                ps as i32,
                &mut error,
            )
        };
        if handle.is_null() {
            return Err(DecodeError(format!(
                "AudioToolbox AAC initialization: {error}"
            )));
        }
        let layout = symphonia::core::audio::Channels::from(
            symphonia::core::audio::Position::from_bits(mask)
                .expect("validated Apple channel mask"),
        );
        let trim_scale = rate / params.sample_rate.unwrap_or(rate as u32) as f64;
        let mut params = params.clone();
        params.sample_rate = Some(rate as u32);
        params.channels = Some(layout.clone());
        Ok(Box::new(Self {
            handle,
            params,
            buffer: AudioBuffer::new(AudioSpec::new(rate as u32, layout), 4096),
            trim_scale,
            pcm: vec![0.0; 4096 * channels as usize],
        }))
    }
}
impl Drop for AppleAacDecoder {
    fn drop(&mut self) {
        unsafe { bch_aac_destroy(self.handle) }
    }
}
impl AudioDecoder for AppleAacDecoder {
    fn reset(&mut self) {
        unsafe { bch_aac_reset(self.handle) };
        self.buffer.clear();
    }
    fn codec_info(&self) -> &CodecInfo {
        &CodecInfo {
            short_name: "aac",
            long_name: "Apple AudioToolbox AAC",
            profiles: &[],
        }
    }
    fn codec_params(&self) -> &AudioCodecParameters {
        &self.params
    }
    fn decode_ref(&mut self, packet: &PacketRef<'_>) -> Result<GenericAudioBufferRef<'_>> {
        self.buffer.clear();
        let mut frames = 0;
        let status = unsafe {
            bch_aac_decode(
                self.handle,
                packet.data.as_ptr(),
                packet.data.len() as u32,
                self.pcm.as_mut_ptr(),
                4096,
                &mut frames,
            )
        };
        if status != 0 {
            return Err(Error::Unsupported("AudioToolbox AAC packet failed"));
        }
        let channels = self.params.channels.as_ref().unwrap().count();
        self.buffer.render_uninit(Some(frames as usize));
        self.buffer
            .copy_from_slice_interleaved(&&self.pcm[..frames as usize * channels]);
        self.buffer.trim(
            (packet.trim_start.get() as f64 * self.trim_scale).round() as usize,
            (packet.trim_end.get() as f64 * self.trim_scale).round() as usize,
        );
        Ok(self.buffer.as_generic_audio_buffer_ref())
    }
    fn finalize(&mut self) -> FinalizeResult {
        self.buffer.clear();
        let mut frames = 0;
        let status = unsafe {
            bch_aac_decode(
                self.handle,
                std::ptr::null(),
                0,
                self.pcm.as_mut_ptr(),
                4096,
                &mut frames,
            )
        };
        if status == 0 {
            self.buffer.render_uninit(Some(frames as usize));
            let ch = self.params.channels.as_ref().unwrap().count();
            self.buffer
                .copy_from_slice_interleaved(&&self.pcm[..frames as usize * ch]);
        }
        FinalizeResult::default()
    }
    fn last_decoded(&self) -> GenericAudioBufferRef<'_> {
        self.buffer.as_generic_audio_buffer_ref()
    }
}

pub fn file_timing(path: &str, output_rate: u32) -> Option<(u64, usize)> {
    unsafe extern "C" {
        fn bch_aac_file_timing(
            path: *const u8,
            length: u32,
            rate: *mut f64,
            valid: *mut i64,
            priming: *mut i32,
            padding: *mut i32,
        ) -> i32;
    }
    let (mut rate, mut valid, mut priming, mut padding) = (0.0, 0i64, 0i32, 0i32);
    let status = unsafe {
        bch_aac_file_timing(
            path.as_ptr(),
            path.len() as u32,
            &mut rate,
            &mut valid,
            &mut priming,
            &mut padding,
        )
    };
    if status != 0 || rate <= 0.0 || valid <= 0 || priming < 0 || padding < 0 {
        return None;
    }
    let scale = output_rate as f64 / rate;
    Some((
        (valid as f64 * scale).round() as u64,
        (priming as f64 * scale).round() as usize,
    ))
}
