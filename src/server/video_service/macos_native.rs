use super::{CapturerInfo, VideoSource};
use base::config::keys::OPTION_MACOS_NATIVE_VIDEO;
use hbb_common::{
    config::{option2bool, Config},
    log, ResultType,
};
use scrap::{
    codec::{Encoder, EncoderApi, EncoderCfg},
    macos_native, Display,
};

pub(super) fn try_enable(
    c: &mut CapturerInfo,
    encoder: &mut Encoder,
    cfg: &EncoderCfg,
    source: VideoSource,
) {
    if !source.is_monitor()
        || !macos_native::available()
        || !option2bool(
            OPTION_MACOS_NATIVE_VIDEO,
            &Config::get_option(OPTION_MACOS_NATIVE_VIDEO),
        )
        || !matches!(cfg, EncoderCfg::HWRAM(config) if
            matches!(config.name.as_str(), "h264_videotoolbox" | "hevc_videotoolbox"))
    {
        return;
    }
    let result = (|| -> ResultType<_> {
        let mut displays = Display::all()?;
        if c.current >= displays.len() {
            hbb_common::bail!("Display no longer available");
        }
        let display = displays.remove(c.current);
        if display.width() != c.width || display.height() != c.height {
            hbb_common::bail!("Display dimensions changed");
        }
        let display_id = display.name().parse()?;
        let native_encoder = macos_native::Encoder::new(cfg.clone(), false)?;
        let native_capture = macos_native::Capturer::new(display_id, c.width, c.height)?;
        Ok((native_capture, native_encoder))
    })();
    match result {
        Ok((capture, native_encoder)) => {
            c.capturer = Box::new(capture);
            encoder.codec = Box::new(native_encoder);
            log::info!("Native video: ScreenCaptureKit NV12 -> CVPixelBuffer -> hardware VideoToolbox, {}x{}, capture limit 60 FPS", c.width, c.height);
        }
        Err(error) => {
            macos_native::disable();
            log::warn!("Native video unavailable; keeping legacy capture/encoder: {error:?}");
        }
    }
}
