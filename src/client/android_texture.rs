use super::{InvokeUiSession, LoginConfigHandler, Session};
use base::message_proto::{video_frame, Chroma, SwitchDisplay, VideoFrame};
use crossbeam_queue::ArrayQueue;
use hbb_common::{anyhow::anyhow, log, ResultType};
use jni::{
    objects::{GlobalRef, JClass, JObject, JString, JValue},
    sys::{jboolean, jint},
    JNIEnv, JavaVM,
};
use scrap::{ImageFormat, ImageRgb};
use std::{
    collections::HashMap,
    ffi::c_void,
    sync::{
        atomic::{AtomicI32, AtomicUsize, Ordering},
        Arc, Mutex, RwLock, Weak,
    },
};

lazy_static::lazy_static! {
    static ref TARGETS: Mutex<HashMap<String, Arc<Target>>> = Default::default();
}

struct Target {
    connection: usize,
    vm: JavaVM,
    object: GlobalRef,
    display: AtomicI32,
    geometry: Mutex<HashMap<usize, (i32, i32)>>,
    rendered: AtomicUsize,
    queues: Mutex<HashMap<usize, Weak<RwLock<ArrayQueue<VideoFrame>>>>>,
}

impl Target {
    fn queue(
        &self,
        data: &[u8],
        width: i32,
        height: i32,
        hevc: bool,
        key: bool,
        pts: i64,
    ) -> ResultType<()> {
        let mut env = self.vm.attach_current_thread_as_daemon()?;
        env.with_local_frame(8, |env| -> ResultType<()> {
            // The Java call copies only the compressed access unit before this borrowed buffer expires.
            let buffer =
                unsafe { env.new_direct_byte_buffer(data.as_ptr() as *mut u8, data.len())? };
            let result = env.call_method(
                self.object.as_obj(),
                "queueFrame",
                "(Ljava/nio/ByteBuffer;IIZZJ)I",
                &[
                    JValue::Object(&JObject::from(buffer)),
                    JValue::Int(width),
                    JValue::Int(height),
                    JValue::Bool(hevc.into()),
                    JValue::Bool(key.into()),
                    JValue::Long(pts.saturating_mul(1000)),
                ],
            );
            match result {
                Ok(value) => {
                    if value.i()? >= 0 {
                        Ok(())
                    } else {
                        Err(anyhow!("Android hardware decoder rejected a frame"))
                    }
                }
                Err(error) => {
                    if env.exception_check()? {
                        env.exception_clear()?;
                    }
                    Err(error.into())
                }
            }
        })
    }

    fn reset(&self) {
        if let Ok(mut env) = self.vm.attach_current_thread_as_daemon() {
            if let Err(error) = env.call_method(self.object.as_obj(), "reset", "()V", &[]) {
                let _ = env.exception_clear();
                log::warn!("Failed to reset Android texture decoder: {error}");
            }
        }
    }
}

fn target(connection: usize) -> Option<Arc<Target>> {
    TARGETS
        .lock()
        .ok()?
        .values()
        .find(|t| t.connection == connection)
        .cloned()
}

#[no_mangle]
pub extern "system" fn Java_ffi_FFI_registerAndroidTexture(
    mut env: JNIEnv,
    _class: JClass,
    session: JString,
    decoder: JObject,
) -> jboolean {
    let register = (|| -> ResultType<()> {
        let id: String = env.get_string(&session)?.into();
        if decoder.is_null() {
            TARGETS
                .lock()
                .map_err(|_| anyhow!("Texture registry poisoned"))?
                .remove(&id);
            return Ok(());
        }
        let uuid = id.parse()?;
        let session = crate::flutter::sessions::get_session_by_session_id(&uuid)
            .ok_or_else(|| anyhow!("Texture session is unavailable"))?;
        let connection = Arc::as_ptr(&session.lc) as usize;
        let object = env.new_global_ref(decoder)?;
        let vm = env.get_java_vm()?;
        TARGETS
            .lock()
            .map_err(|_| anyhow!("Texture registry poisoned"))?
            .insert(
                id,
                Arc::new(Target {
                    connection,
                    vm,
                    object,
                    display: AtomicI32::new(-1),
                    geometry: Default::default(),
                    rendered: AtomicUsize::new(0),
                    queues: Default::default(),
                }),
            );
        Ok(())
    })();
    if let Err(error) = register {
        log::warn!("Cannot register Android texture decoder: {error}");
        let _ = env.exception_clear();
        return 0;
    }
    1
}

#[no_mangle]
pub extern "system" fn Java_ffi_FFI_onAndroidTextureFrame(
    mut env: JNIEnv,
    _class: JClass,
    session: JString,
) {
    let Ok(id) = env.get_string(&session) else {
        return;
    };
    let id: String = id.into();
    if let Ok(targets) = TARGETS.lock() {
        if let Some(target) = targets.get(&id) {
            target.rendered.fetch_add(1, Ordering::Relaxed);
        }
    }
}

pub fn switch_display(lc: &Arc<RwLock<LoginConfigHandler>>, display: &SwitchDisplay) {
    if let Some(target) = target(Arc::as_ptr(lc) as usize) {
        target.display.store(display.display, Ordering::Relaxed);
        if let Ok(mut geometry) = target.geometry.lock() {
            geometry.insert(display.display as usize, (display.width, display.height));
        }
    }
}

#[no_mangle]
pub extern "system" fn Java_ffi_FFI_androidVideoQueueSize(
    mut env: JNIEnv,
    _class: JClass,
    session: JString,
) -> jint {
    let Ok(id) = env.get_string(&session) else {
        return -1;
    };
    let id: String = id.into();
    let current = TARGETS.lock().unwrap().get(&id).cloned();
    let Some(current) = current else { return -1 };
    let display = current.display.load(Ordering::Relaxed) as usize;
    let queue = current
        .queues
        .lock()
        .unwrap()
        .get(&display)
        .and_then(Weak::upgrade);
    let Some(queue) = queue else { return -1 };
    let len = queue.read().unwrap().len();
    len as jint
}

#[no_mangle]
pub extern "system" fn Java_ffi_FFI_onAndroidTextureError(
    mut env: JNIEnv,
    _class: JClass,
    session: JString,
) {
    let Ok(id) = env.get_string(&session) else {
        return;
    };
    let id: String = id.into();
    let display = TARGETS
        .lock()
        .unwrap()
        .get(&id)
        .map(|target| target.display.load(Ordering::Relaxed));
    if let (Some(display), Ok(uuid)) = (display, id.parse()) {
        if let Some(session) = crate::flutter::sessions::get_session_by_session_id(&uuid) {
            // A static desktop may send no further packets after an asynchronous codec failure.
            session.refresh_video(display);
        }
    }
}

pub struct Decoder {
    connection: usize,
    display: usize,
    target: Option<Arc<Target>>,
    active: bool,
    disabled: bool,
    awaiting_keyframe: bool,
    rgb: ImageRgb,
    queue: Weak<RwLock<ArrayQueue<VideoFrame>>>,
}

impl Decoder {
    pub fn new(
        lc: &Arc<RwLock<LoginConfigHandler>>,
        display: usize,
        queue: Weak<RwLock<ArrayQueue<VideoFrame>>>,
    ) -> Self {
        Self {
            connection: Arc::as_ptr(lc) as usize,
            display,
            target: None,
            active: false,
            disabled: false,
            awaiting_keyframe: false,
            rgb: ImageRgb::new(ImageFormat::ARGB, 1),
            queue,
        }
    }

    pub fn handle<F, T>(
        &mut self,
        frame: &VideoFrame,
        session: &Session<T>,
        callback: &mut F,
        fps: &Arc<RwLock<Option<usize>>>,
        chroma: &Arc<RwLock<Option<Chroma>>>,
    ) -> bool
    where
        F: FnMut(usize, &mut ImageRgb, *mut c_void, bool),
        T: InvokeUiSession,
    {
        let (frames, hevc) = match frame.union.as_ref() {
            Some(video_frame::Union::H264s(frames)) => (frames, false),
            Some(video_frame::Union::H265s(frames)) => (frames, true),
            _ => {
                self.reset();
                return false;
            }
        };
        let key = frames.frames.iter().any(|frame| frame.key);
        let current = target(self.connection);
        let recording = session.lc.read().unwrap().record_state;
        if recording {
            self.disabled = true;
        }
        if self.disabled || recording || current.is_none() {
            if self.active {
                self.reset();
                self.awaiting_keyframe = true;
                session.refresh_video(self.display as _);
            }
            if self.awaiting_keyframe && !key {
                return true;
            }
            self.awaiting_keyframe = false;
            return false;
        }
        let Some(current) = current else { return false };
        if current.display.load(Ordering::Relaxed) == -1 {
            if let Some(info) = &session.lc.read().unwrap().peer_info {
                let _ = current.display.compare_exchange(
                    -1,
                    info.current_display,
                    Ordering::Relaxed,
                    Ordering::Relaxed,
                );
            }
        }
        if current.display.load(Ordering::Relaxed) != self.display as i32 {
            return false;
        }
        if !self
            .target
            .as_ref()
            .is_some_and(|old| Arc::ptr_eq(old, &current))
        {
            current
                .queues
                .lock()
                .unwrap()
                .insert(self.display, self.queue.clone());
            self.target = Some(current.clone());
            self.active = false;
            self.awaiting_keyframe = true;
            session.refresh_video(self.display as _);
        }
        let rendered = current.rendered.swap(0, Ordering::Relaxed);
        for _ in 0..rendered {
            callback(self.display, &mut self.rgb, std::ptr::null_mut(), false);
        }
        if self.awaiting_keyframe && !key {
            return true;
        }
        let size = current
            .geometry
            .lock()
            .ok()
            .and_then(|g| g.get(&self.display).copied())
            .or_else(|| {
                session
                    .lc
                    .read()
                    .ok()?
                    .peer_info
                    .as_ref()?
                    .displays
                    .get(self.display)
                    .map(|display| (display.width, display.height))
            });
        let Some((width, height)) = size else {
            return false;
        };
        if width <= 0 || height <= 0 {
            return false;
        }
        self.awaiting_keyframe = false;
        for encoded in frames.frames.iter() {
            if let Err(error) =
                current.queue(&encoded.data, width, height, hevc, encoded.key, encoded.pts)
            {
                log::warn!(
                    "Android texture decoding failed; requesting software key frame: {error}"
                );
                self.reset();
                self.disabled = true;
                self.awaiting_keyframe = true;
                session.refresh_video(self.display as _);
                return true;
            }
        }
        self.active = true;
        // Async rendering has no synchronous decode-capacity estimate. Network QoS and the
        // bounded native input queue control load; pending output is not a decode failure.
        *fps.write().unwrap() = None;
        *chroma.write().unwrap() = Some(Chroma::I420);
        true
    }

    pub fn reset(&mut self) {
        if self.target.is_none() {
            return;
        }
        if self.active {
            if let Some(target) = &self.target {
                if target.display.load(Ordering::Relaxed) == self.display as i32 {
                    target.reset();
                }
            }
        }
        self.active = false;
        self.awaiting_keyframe = true;
    }
}
