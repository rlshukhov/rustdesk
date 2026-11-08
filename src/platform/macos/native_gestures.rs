use base::message_proto::NativeGesture;
use std::cell::RefCell;

thread_local! {
    static ACTIVE: RefCell<Option<(i32, NativeGesture)>> = RefCell::new(None);
}

extern "C" {
    fn PostNativeGesture(
        scroll: bool,
        phase: u32,
        x: f64,
        y: f64,
        magnification: f64,
        dx: f64,
        dy: f64,
    ) -> bool;
}

pub fn post(event: &NativeGesture, conn: i32) {
    if event.phase == 1 {
        if let Some(owner) = ACTIVE.with(|active| active.borrow().as_ref().map(|(owner, _)| *owner))
        {
            cancel(owner);
        }
    } else if !ACTIVE.with(|active| {
        active
            .borrow()
            .as_ref()
            .is_some_and(|(owner, _)| *owner == conn)
    }) {
        return;
    }
    if !unsafe {
        PostNativeGesture(
            event.scroll,
            event.phase,
            event.x as f64,
            event.y as f64,
            event.magnification,
            event.delta_x,
            event.delta_y,
        )
    } {
        hbb_common::log::trace!("Native gesture was rejected or Accessibility is unavailable");
    } else {
        ACTIVE.with(|active| {
            *active.borrow_mut() = if matches!(event.phase, 1 | 2) {
                Some((conn, event.clone()))
            } else {
                None
            };
        });
    }
}

pub fn cancel(conn: i32) {
    let event = ACTIVE.with(|active| {
        let mut active = active.borrow_mut();
        if active.as_ref().is_some_and(|(owner, _)| *owner == conn) {
            active.take().map(|(_, event)| event)
        } else {
            None
        }
    });
    if let Some(mut event) = event {
        event.phase = 8;
        event.magnification = 0.0;
        event.delta_x = 0.0;
        event.delta_y = 0.0;
        if !unsafe {
            PostNativeGesture(
                event.scroll,
                event.phase,
                event.x as f64,
                event.y as f64,
                event.magnification,
                event.delta_x,
                event.delta_y,
            )
        } {
            hbb_common::log::trace!(
                "Native gesture cancellation failed; Accessibility may be unavailable"
            );
        }
    }
}
