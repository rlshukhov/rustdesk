#import <ApplicationServices/ApplicationServices.h>
#include <cmath>

static CGEventRef CreateNativeGesture(bool scroll, uint32_t phase, double x, double y,
                                     double magnification, double dx, double dy) {
    if ((phase != 1 && phase != 2 && phase != 4 && phase != 8) ||
        !std::isfinite(x) || !std::isfinite(y) || std::abs(x) > 1000000 || std::abs(y) > 1000000 ||
        !std::isfinite(magnification) || magnification <= -1 || magnification > 10 ||
        !std::isfinite(dx) || !std::isfinite(dy) || std::abs(dx) > 10000 || std::abs(dy) > 10000) {
        return nullptr;
    }
    CGEventRef event;
    if (scroll) {
        event = CGEventCreateScrollWheelEvent(nullptr, kCGScrollEventUnitPixel, 2, 0, 0);
        if (!event) return nullptr;
        static thread_local double remainderX = 0, remainderY = 0;
        if (phase == 1) { remainderX = 0; remainderY = 0; }
        // AppKit's precise scroll deltas are integer pixels; retain subpixel Retina movement.
        const long pixelsX = std::lround(dx + remainderX);
        const long pixelsY = std::lround(dy + remainderY);
        remainderX += dx - pixelsX;
        remainderY += dy - pixelsY;
        if (phase == 4 || phase == 8) { remainderX = 0; remainderY = 0; }
        CGEventSetDoubleValueField(event, kCGScrollWheelEventFixedPtDeltaAxis1, dy);
        CGEventSetDoubleValueField(event, kCGScrollWheelEventFixedPtDeltaAxis2, dx);
        CGEventSetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis1, pixelsY);
        CGEventSetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis2, pixelsX);
        CGEventSetIntegerValueField(event, kCGScrollWheelEventScrollPhase, phase);
    } else {
        event = CGEventCreate(nullptr);
        if (!event) return nullptr;
        // shortcut: undocumented magnify fields, revalidate when supporting a new macOS release.
        CGEventSetType(event, static_cast<CGEventType>(29));
        CGEventSetIntegerValueField(event, static_cast<CGEventField>(110), 8);
        CGEventSetIntegerValueField(event, static_cast<CGEventField>(132), phase);
        CGEventSetDoubleValueField(event, static_cast<CGEventField>(113), magnification);
    }
    CGEventSetLocation(event, CGPointMake(x, y));
    return event;
}

extern "C" bool PostNativeGesture(bool scroll, uint32_t phase, double x, double y,
                                  double magnification, double dx, double dy) {
    if (!AXIsProcessTrusted()) return false;
    CGEventRef event = CreateNativeGesture(scroll, phase, x, y, magnification, dx, dy);
    if (!event) return false;
    if (phase == 1) {
        CGEventRef moved = CGEventCreateMouseEvent(nullptr, kCGEventMouseMoved,
                                                  CGPointMake(x, y), kCGMouseButtonLeft);
        if (!moved) { CFRelease(event); return false; }
        CGEventPost(kCGHIDEventTap, moved);
        CFRelease(moved);
    }
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
    return true;
}
