include!(concat!(env!("OUT_DIR"), "/protos/mod.rs"));

#[cfg(test)]
mod tests {
    use super::message::*;
    use protobuf::Message;

    #[test]
    fn legacy_touch_wire_format_is_unchanged() {
        let fixture = [0x0a, 0x04, 0x0a, 0x02, 0x08, 0x64];
        let event = PointerDeviceEvent::parse_from_bytes(&fixture).unwrap();
        assert_eq!(event.touch_event().scale_update().scale, 100);
        assert_eq!(event.write_to_bytes().unwrap(), fixture);
    }

    #[test]
    fn native_gesture_uses_a_separate_wire_variant() {
        let mut event = PointerDeviceEvent::new();
        event.set_native_gesture(NativeGesture {
            phase: 2,
            x: -400,
            magnification: 0.25,
            ..Default::default()
        });
        let received =
            PointerDeviceEvent::parse_from_bytes(&event.write_to_bytes().unwrap()).unwrap();
        assert!(!received.has_touch_event());
        assert_eq!(received.native_gesture().x, -400);
        assert_eq!(received.native_gesture().magnification, 0.25);
    }
}
