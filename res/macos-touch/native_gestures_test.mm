#import <AppKit/AppKit.h>
#include <cassert>
#include "../../src/platform/macos/native_gestures.mm"

int main() {
    @autoreleasepool {
        const uint32_t phases[] = {1, 2, 4, 8};
        const NSEventPhase expected[] = {NSEventPhaseBegan, NSEventPhaseChanged,
                                        NSEventPhaseEnded, NSEventPhaseCancelled};
        for (int i = 0; i < 4; i++) {
            CGEventRef event = CreateNativeGesture(false, phases[i], -400, 200, 0.25, 0, 0);
            assert(event);
            assert(CGEventGetIntegerValueField(event, kCGEventSourceUserData) == 100);
            NSEvent *native = [NSEvent eventWithCGEvent:event];
            assert(native.type == NSEventTypeMagnify);
            assert(native.phase == expected[i]);
            assert(std::abs(native.magnification - 0.25) < 0.0001);
            CFRelease(event);
        }
        CGEventRef scroll = CreateNativeGesture(true, 2, 10, 20, 0, 6, -12);
        assert(scroll);
        NSEvent *native = [NSEvent eventWithCGEvent:scroll];
        assert(native.type == NSEventTypeScrollWheel);
        assert(native.hasPreciseScrollingDeltas);
        assert(native.phase == NSEventPhaseChanged);
        assert(native.scrollingDeltaX == 6 && native.scrollingDeltaY == -12);
        CFRelease(scroll);
        double totalX = 0, totalY = 0;
        for (int i = 0; i < 4; i++) {
            scroll = CreateNativeGesture(true, i == 0 ? 1 : 2, 0, 0, 0, 0.25, -0.5);
            native = [NSEvent eventWithCGEvent:scroll];
            totalX += native.scrollingDeltaX;
            totalY += native.scrollingDeltaY;
            CFRelease(scroll);
        }
        assert(totalX == 1 && totalY == -2);
        scroll = CreateNativeGesture(true, 4, 0, 0, 0, 0, 0);
        CFRelease(scroll);
        assert(!CreateNativeGesture(false, 0, 0, 0, 0, 0, 0));
        assert(!CreateNativeGesture(false, 1, NAN, 0, 0, 0, 0));
        assert(!CreateNativeGesture(false, 1, 0, 0, -1, 0, 0));
        assert(!CreateNativeGesture(true, 2, 0, 0, 0, INFINITY, 0));
        puts("PASS: native pinch, scroll, phases and input validation");
    }
}
