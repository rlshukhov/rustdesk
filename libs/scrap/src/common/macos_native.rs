//! ScreenCaptureKit NV12 surfaces passed directly to a hardware-only VideoToolbox session.
use crate::{
    codec::{EncoderApi, EncoderCfg},
    hwcodec::{HwRamEncoder, HwRamEncoderConfig},
    EncodeInput, EncodeYuvFormat, Frame, Pixfmt, TraitCapturer,
};
use base::message_proto::{EncodedVideoFrame, EncodedVideoFrames, VideoFrame};
use hbb_common::{anyhow::anyhow, bail, bytes::Bytes, ResultType};
use std::{
    ffi::c_void,
    io,
    ptr::NonNull,
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration, Instant},
};

// A broken native stream/encoder falls back for the rest of this host process.
// This prevents retries on every service restart while retaining the legacy encoder.
static FAILED: AtomicBool = AtomicBool::new(false);

extern "C" {
    fn rd_sck_start(display: u32, width: u32, height: u32) -> *mut c_void;
    fn rd_sck_take(capture: *mut c_void, buffer: *mut *mut c_void) -> i32;
    fn rd_sck_free(capture: *mut c_void);
    fn rd_cv_retain(buffer: *mut c_void);
    fn rd_cv_release(buffer: *mut c_void);
    fn rd_cv_rgba(buffer: *mut c_void, bytes: *mut u8, width: usize, height: usize) -> i32;
    fn rd_vt_new(width: u32, height: u32, hevc: bool, kbps: u32, gop: u32) -> *mut c_void;
    fn rd_vt_encode(
        encoder: *mut c_void,
        buffer: *mut c_void,
        ms: i64,
        bytes: *mut *const u8,
        length: *mut usize,
        key: *mut bool,
    ) -> i32;
    fn rd_vt_quality(encoder: *mut c_void, kbps: u32) -> i32;
    fn rd_vt_free(encoder: *mut c_void);
}

pub fn available() -> bool {
    !FAILED.load(Ordering::Relaxed)
}

pub fn disable() {
    FAILED.store(true, Ordering::Relaxed);
}

pub struct PixelBuffer {
    inner: NonNull<c_void>,
    width: usize,
    height: usize,
}

impl Clone for PixelBuffer {
    fn clone(&self) -> Self {
        unsafe { rd_cv_retain(self.inner.as_ptr()) };
        Self {
            inner: self.inner,
            width: self.width,
            height: self.height,
        }
    }
}

impl Drop for PixelBuffer {
    fn drop(&mut self) {
        unsafe { rd_cv_release(self.inner.as_ptr()) };
    }
}

impl PixelBuffer {
    pub fn rgba(&self) -> ResultType<(usize, usize, Vec<u8>)> {
        let length = self
            .width
            .checked_mul(self.height)
            .and_then(|n| n.checked_mul(4))
            .ok_or_else(|| anyhow!("Screenshot dimensions overflow"))?;
        let mut bytes = vec![0; length];
        if unsafe {
            rd_cv_rgba(
                self.inner.as_ptr(),
                bytes.as_mut_ptr(),
                self.width,
                self.height,
            )
        } != 0
        {
            bail!("Failed to convert ScreenCaptureKit screenshot");
        }
        Ok((self.width, self.height, bytes))
    }
}

pub struct Capturer {
    inner: NonNull<c_void>,
    width: usize,
    height: usize,
    first_frame_wait: Option<Instant>,
}

impl Capturer {
    pub fn new(display: u32, width: usize, height: usize) -> ResultType<Self> {
        let inner = NonNull::new(unsafe { rd_sck_start(display, width as _, height as _) })
            .ok_or_else(|| anyhow!("ScreenCaptureKit could not start for display {display}"))?;
        Ok(Self {
            inner,
            width,
            height,
            first_frame_wait: Some(Instant::now()),
        })
    }
}

impl TraitCapturer for Capturer {
    fn frame(&mut self, _timeout: Duration) -> io::Result<Frame<'_>> {
        let mut buffer = std::ptr::null_mut();
        match unsafe { rd_sck_take(self.inner.as_ptr(), &mut buffer) } {
            1 => {
                let inner =
                    NonNull::new(buffer).ok_or_else(|| io::Error::other("Empty CVPixelBuffer"))?;
                self.first_frame_wait = None;
                Ok(Frame::MacPixelBuffer(PixelBuffer {
                    inner,
                    width: self.width,
                    height: self.height,
                }))
            }
            0 if self
                .first_frame_wait
                .map(|start| start.elapsed() > Duration::from_secs(5))
                .unwrap_or(false) =>
            {
                disable();
                Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "ScreenCaptureKit produced no first frame",
                ))
            }
            0 => Err(io::ErrorKind::WouldBlock.into()),
            _ => {
                disable();
                Err(io::Error::other("ScreenCaptureKit stream stopped"))
            }
        }
    }
}

impl Drop for Capturer {
    fn drop(&mut self) {
        unsafe { rd_sck_free(self.inner.as_ptr()) };
    }
}

pub struct Encoder {
    inner: NonNull<c_void>,
    config: HwRamEncoderConfig,
    bitrate: u32,
}

impl EncoderApi for Encoder {
    fn new(cfg: EncoderCfg, i444: bool) -> ResultType<Self> {
        let config = match cfg {
            EncoderCfg::HWRAM(config)
                if !i444
                    && matches!(
                        config.name.as_str(),
                        "h264_videotoolbox" | "hevc_videotoolbox"
                    ) =>
            {
                config
            }
            _ => bail!("Native VideoToolbox requires H264/HEVC 4:2:0"),
        };
        let bitrate =
            HwRamEncoder::bitrate(&config.name, config.width, config.height, config.quality).max(1);
        let inner = NonNull::new(unsafe {
            rd_vt_new(
                config.width as _,
                config.height as _,
                config.name == "hevc_videotoolbox",
                bitrate,
                config.keyframe_interval.unwrap_or(i32::MAX as usize) as _,
            )
        })
        .ok_or_else(|| anyhow!("Hardware VideoToolbox session could not start"))?;
        Ok(Self {
            inner,
            config,
            bitrate,
        })
    }

    fn encode_to_message(&mut self, frame: EncodeInput, ms: i64) -> ResultType<VideoFrame> {
        let buffer = match frame {
            EncodeInput::MacPixelBuffer(buffer) => buffer,
            _ => bail!("Native VideoToolbox requires a CVPixelBuffer"),
        };
        let mut data = std::ptr::null();
        let mut length = 0;
        let mut key = false;
        let status = unsafe {
            rd_vt_encode(
                self.inner.as_ptr(),
                buffer.inner.as_ptr(),
                ms,
                &mut data,
                &mut length,
                &mut key,
            )
        };
        if status != 0 || data.is_null() || length == 0 {
            bail!("Native VideoToolbox encode failed: {status}");
        }
        // The compressed packet is copied; the uncompressed surface never crosses CPU memory.
        let bytes = Bytes::copy_from_slice(unsafe { std::slice::from_raw_parts(data, length) });
        let frames = EncodedVideoFrames {
            frames: vec![EncodedVideoFrame {
                data: bytes,
                pts: ms,
                key,
                ..Default::default()
            }]
            .into(),
            ..Default::default()
        };
        let mut message = VideoFrame::new();
        if self.config.name == "hevc_videotoolbox" {
            message.set_h265s(frames);
        } else {
            message.set_h264s(frames);
        }
        Ok(message)
    }

    fn yuvfmt(&self) -> EncodeYuvFormat {
        EncodeYuvFormat {
            pixfmt: Pixfmt::NV12,
            w: self.config.width,
            h: self.config.height,
            stride: vec![self.config.width, self.config.width],
            u: 0,
            v: 0,
        }
    }
    #[cfg(feature = "vram")]
    fn input_texture(&self) -> bool {
        false
    }
    fn set_quality(&mut self, ratio: f32) -> ResultType<()> {
        let bitrate = HwRamEncoder::bitrate(
            &self.config.name,
            self.config.width,
            self.config.height,
            ratio,
        )
        .max(1);
        let status = unsafe { rd_vt_quality(self.inner.as_ptr(), bitrate) };
        if status != 0 {
            bail!("VideoToolbox bitrate update failed: {status}");
        }
        self.bitrate = bitrate;
        self.config.quality = ratio;
        Ok(())
    }
    fn bitrate(&self) -> u32 {
        self.bitrate
    }
    fn support_changing_quality(&self) -> bool {
        true
    }
    fn latency_free(&self) -> bool {
        true
    }
    fn is_hardware(&self) -> bool {
        true
    }
    fn disable(&self) {
        disable();
    }
}

impl Drop for Encoder {
    fn drop(&mut self) {
        unsafe { rd_vt_free(self.inner.as_ptr()) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_non_videotoolbox_and_444_configuration() {
        let cfg = EncoderCfg::HWRAM(HwRamEncoderConfig {
            name: "hevc_videotoolbox".to_owned(),
            mc_name: None,
            width: 640,
            height: 480,
            quality: 1.0,
            keyframe_interval: Some(60),
        });
        assert!(Encoder::new(cfg.clone(), true).is_err());
        let mut other = cfg;
        if let EncoderCfg::HWRAM(config) = &mut other {
            config.name = "hevc_nvenc".to_owned();
        }
        assert!(Encoder::new(other, false).is_err());
    }

    #[test]
    #[ignore = "Requires a local Mac with a hardware VideoToolbox encoder"]
    fn encodes_nv12_surfaces_and_updates_quality() {
        extern "C" {
            fn CVPixelBufferCreate(
                allocator: *const c_void,
                width: usize,
                height: usize,
                format: u32,
                attributes: *const c_void,
                buffer: *mut *mut c_void,
            ) -> i32;
            fn CVPixelBufferLockBaseAddress(buffer: *mut c_void, flags: u64) -> i32;
            fn CVPixelBufferUnlockBaseAddress(buffer: *mut c_void, flags: u64) -> i32;
            fn CVPixelBufferGetBaseAddressOfPlane(buffer: *mut c_void, plane: usize) -> *mut u8;
            fn CVPixelBufferGetBytesPerRowOfPlane(buffer: *mut c_void, plane: usize) -> usize;
        }
        let mut raw = std::ptr::null_mut();
        unsafe {
            assert_eq!(
                CVPixelBufferCreate(
                    std::ptr::null(),
                    640,
                    480,
                    u32::from_be_bytes(*b"420v"),
                    std::ptr::null(),
                    &mut raw
                ),
                0
            );
            assert_eq!(CVPixelBufferLockBaseAddress(raw, 0), 0);
            for (plane, value, height) in [(0, 64, 480), (1, 128, 240)] {
                let bytes = CVPixelBufferGetBytesPerRowOfPlane(raw, plane) * height;
                std::ptr::write_bytes(CVPixelBufferGetBaseAddressOfPlane(raw, plane), value, bytes);
            }
            assert_eq!(CVPixelBufferUnlockBaseAddress(raw, 0), 0);
        }
        let buffer = PixelBuffer {
            inner: NonNull::new(raw).unwrap(),
            width: 640,
            height: 480,
        };
        for name in ["h264_videotoolbox", "hevc_videotoolbox"] {
            let cfg = EncoderCfg::HWRAM(HwRamEncoderConfig {
                name: name.to_owned(),
                mc_name: None,
                width: 640,
                height: 480,
                quality: 1.0,
                keyframe_interval: Some(60),
            });
            let mut encoder = Encoder::new(cfg, false).unwrap();
            for index in 0..3 {
                let message = encoder
                    .encode_to_message(EncodeInput::MacPixelBuffer(&buffer), index * 17)
                    .unwrap();
                let frames = if name.starts_with("h264") {
                    &message.h264s().frames
                } else {
                    &message.h265s().frames
                };
                assert_eq!(frames.len(), 1);
                assert!(frames[0].data.starts_with(&[0, 0, 0, 1]));
                assert_eq!(frames[0].key, index == 0);
                assert_eq!(frames[0].pts, index * 17);
                encoder.set_quality(0.5).unwrap();
            }
        }
        let (_, _, rgba) = buffer.rgba().unwrap();
        assert_eq!(rgba.len(), 640 * 480 * 4);
    }
}
