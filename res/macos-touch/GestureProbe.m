#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>

extern bool PostNativeGesture(bool scroll, uint32_t phase, double x, double y,
                              double magnification, double dx, double dy);

@class GestureContent;
static void BeginGestureProbe(NSWindow *window, GestureContent *content);

@interface GestureContent : NSView
@property double zoom;
@property NSUInteger receivedMagnifications;
@end

@implementation GestureContent
- (BOOL)acceptsFirstResponder { return YES; }
- (void)runProbe:(NSButton *)sender { sender.enabled = NO; BeginGestureProbe(self.window, self); }
- (void)drawRect:(NSRect)rect {
    [NSColor.darkGrayColor setFill]; NSRectFill(self.bounds);
    [NSColor.systemTealColor setFill];
    NSRectFill(NSMakeRect(50, 50, 100 * self.zoom, 70 * self.zoom));
    NSString *text = [NSString stringWithFormat:@"Масштаб: %.2f — событий pinch: %lu", self.zoom, (unsigned long)self.receivedMagnifications];
    [text drawAtPoint:NSMakePoint(30, 330) withAttributes:@{NSForegroundColorAttributeName:NSColor.whiteColor}];
}
- (void)magnifyWithEvent:(NSEvent *)event {
    self.zoom *= 1 + event.magnification;
    self.receivedMagnifications++;
    self.needsDisplay = YES;
    printf("CONTENT magnification=%.4f phase=%lu zoom=%.4f\n", event.magnification, (unsigned long)event.phase, self.zoom);
    fflush(stdout);
}
@end

@interface GestureWindow : NSWindow
@end
@implementation GestureWindow
- (void)sendEvent:(NSEvent *)event {
    if (event.type == NSEventTypeMagnify) { printf("WINDOW magnify hit=%s first=%s\n", NSStringFromClass([self.contentView hitTest:event.locationInWindow].class).UTF8String, NSStringFromClass(self.firstResponder.class).UTF8String); fflush(stdout); }
    [super sendEvent:event];
}
@end

@interface TouchApp : NSApplication
@end
@implementation TouchApp
- (void)sendEvent:(NSEvent *)event {
    if (event.type == NSEventTypeMagnify) {
        printf("QUEUE magnify phase=%lu window=%ld resolved=%s key=%ld location=%s\n", (unsigned long)event.phase, (long)event.windowNumber, NSStringFromClass(event.window.class).UTF8String, (long)self.keyWindow.windowNumber, NSStringFromPoint(event.locationInWindow).UTF8String);
        fflush(stdout);
    }
    [super sendEvent:event];
}
@end

static void BeginGestureProbe(NSWindow *window, GestureContent *content) {
        content.zoom = 1;
        content.receivedMagnifications = 0;
        CGEventRef snapshot = CGEventCreate(NULL);
        CGPoint previousPointer = CGEventGetLocation(snapshot);
        CFRelease(snapshot);
        CGPoint target = CGPointMake(NSMidX(window.frame), NSScreen.screens.firstObject.frame.size.height - NSMidY(window.frame));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
            [NSRunningApplication.currentApplication activateWithOptions:NSApplicationActivateAllWindows|NSApplicationActivateIgnoringOtherApps];
            [window makeKeyAndOrderFront:nil];
            [window makeMainWindow];
            [window makeFirstResponder:content];
            CGWarpMouseCursorPosition(target);
            CGEventRef moved = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, target, kCGMouseButtonLeft);
            CGEventPost(kCGHIDEventTap, moved);
            CFRelease(moved);
        });
        for (int frame = 0; frame <= 11; frame++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((1 + frame * 0.08) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (!PostNativeGesture(false, frame == 0 ? 1 : (frame == 11 ? 4 : 2),
                    target.x, target.y, frame == 0 || frame == 11 ? 0 : 0.08, 0, 0)) {
                    fprintf(stderr, "Posting native pinch failed.\n");
                }
            });
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            CGEventRef current = CGEventCreate(NULL);
            CGPoint pointer = CGEventGetLocation(current);
            CFRelease(current);
            if (hypot(pointer.x-target.x, pointer.y-target.y) < 3) CGWarpMouseCursorPosition(previousPointer);
            BOOL passed = content.receivedMagnifications > 0 && content.zoom > 1.1;
            printf("RESULT %s contentEvents=%lu zoom=%.4f\n", passed ? "PASS" : "FAIL", (unsigned long)content.receivedMagnifications, content.zoom);
            fflush(stdout);
            [NSApp terminate:nil];
        });
}

int main(void) {
    @autoreleasepool {
        if (!AXIsProcessTrusted()) { fprintf(stderr, "Accessibility permission is required.\n"); return 2; }
        [TouchApp sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSApp finishLaunching];
        NSWindow *window = [[GestureWindow alloc] initWithContentRect:NSMakeRect(300, 300, 600, 400)
            styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
        window.title = @"RustDesk — проверка pinch через Универсальный доступ";
        window.acceptsMouseMovedEvents = YES;
        GestureContent *content = [[GestureContent alloc] initWithFrame:NSMakeRect(0, 0, 600, 400)];
        content.zoom = 1;
        NSButton *button = [NSButton buttonWithTitle:@"Проверить pinch" target:content action:@selector(runProbe:)];
        button.frame = NSMakeRect(30, 365, 200, 28);
        [content addSubview:button];
        window.contentView = content;
        [window makeKeyAndOrderFront:nil];
        [window makeFirstResponder:content];
        [NSApp activateIgnoringOtherApps:YES];
        printf("READY: click the test button to start.\n"); fflush(stdout);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 180 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
        [NSApp run];
    }
    return 0;
}
