#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreGraphics/CoreGraphics.h>

// Each display has one replaceable, retained CVPixelBuffer. Encoded frames are never dropped.
@interface RDCapture : NSObject <SCStreamOutput, SCStreamDelegate>
@property(nonatomic, strong) SCStream *stream;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic) CVPixelBufferRef latest;
@property(nonatomic) BOOL failed;
@end

@implementation RDCapture
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sample
        ofType:(SCStreamOutputType)type API_AVAILABLE(macos(12.3)) {
    if (type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sample)) return;
    NSArray *attachments = (__bridge NSArray *)CMSampleBufferGetSampleAttachmentsArray(sample, false);
    if (attachments.count == 0 ||
        [attachments[0][SCStreamFrameInfoStatus] integerValue] != SCFrameStatusComplete) return;
    CVPixelBufferRef buffer = CMSampleBufferGetImageBuffer(sample);
    if (!buffer) return;
    @synchronized (self) {
        if (_latest) CVPixelBufferRelease(_latest);
        _latest = CVPixelBufferRetain(buffer);
    }
}
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error API_AVAILABLE(macos(12.3)) {
    @synchronized (self) { _failed = YES; }
}
- (void)dealloc {
    if (_latest) CVPixelBufferRelease(_latest);
}
@end

void *rd_sck_start(uint32_t displayID, uint32_t width, uint32_t height) {
    @autoreleasepool {
        if (@available(macOS 12.3, *)) {
            __block SCShareableContent *content;
            dispatch_semaphore_t ready = dispatch_semaphore_create(0);
            [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:YES
                completionHandler:^(SCShareableContent *value, NSError *error) {
                    content = value;
                    dispatch_semaphore_signal(ready);
                }];
            if (dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC))) return NULL;
            SCDisplay *display;
            for (SCDisplay *item in content.displays) {
                if (item.displayID == displayID) { display = item; break; }
            }
            if (!display) return NULL;
            RDCapture *capture = [RDCapture new];
            capture.queue = dispatch_queue_create("RustDesk.ScreenCaptureKit", DISPATCH_QUEUE_SERIAL);
            SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
            SCStreamConfiguration *config = [SCStreamConfiguration new];
            config.width = width;
            config.height = height;
            config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
            config.minimumFrameInterval = CMTimeMake(1, 60);
            // The encoder and static refresh retain surfaces beyond the capture callback.
            config.queueDepth = 8;
            config.showsCursor = NO;
            config.colorSpaceName = kCGColorSpaceSRGB;
            capture.stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:capture];
            NSError *error;
            if (![capture.stream addStreamOutput:capture type:SCStreamOutputTypeScreen
                               sampleHandlerQueue:capture.queue error:&error]) return NULL;
            __block BOOL success = NO;
            dispatch_semaphore_t started = dispatch_semaphore_create(0);
            [capture.stream startCaptureWithCompletionHandler:^(NSError *error) {
                success = error == nil;
                dispatch_semaphore_signal(started);
            }];
            if (dispatch_semaphore_wait(started, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) || !success) {
                [capture.stream removeStreamOutput:capture type:SCStreamOutputTypeScreen error:nil];
                [capture.stream stopCaptureWithCompletionHandler:nil];
                return NULL;
            }
            return (__bridge_retained void *)capture;
        }
        return NULL;
    }
}

int rd_sck_take(void *opaque, CVPixelBufferRef *buffer) {
    RDCapture *capture = (__bridge RDCapture *)opaque;
    @synchronized (capture) {
        if (capture.failed) return -1;
        *buffer = capture.latest;
        capture.latest = NULL;
        return *buffer ? 1 : 0;
    }
}

void rd_sck_free(void *opaque) {
    @autoreleasepool {
        RDCapture *capture = (__bridge_transfer RDCapture *)opaque;
        if (@available(macOS 12.3, *)) {
            [capture.stream removeStreamOutput:capture type:SCStreamOutputTypeScreen error:nil];
            [capture.stream stopCaptureWithCompletionHandler:nil];
            dispatch_sync(capture.queue, ^{});
        }
    }
}

void rd_cv_retain(CVPixelBufferRef buffer) { CVPixelBufferRetain(buffer); }
void rd_cv_release(CVPixelBufferRef buffer) { CVPixelBufferRelease(buffer); }

int rd_cv_rgba(CVPixelBufferRef buffer, uint8_t *bytes, size_t width, size_t height) {
    CGImageRef image = NULL;
    OSStatus status = VTCreateCGImageFromCVPixelBuffer(buffer, NULL, &image);
    if (status || !image) return -1;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(bytes, width, height, 8, width * 4, space,
                                                kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!context) { CGImageRelease(image); return -1; }
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGContextRelease(context);
    CGImageRelease(image);
    return 0;
}

@interface RDEncodedFrame : NSObject
@property(nonatomic, strong) dispatch_semaphore_t ready;
@property(nonatomic, strong) NSData *packet;
@property(nonatomic) OSStatus status;
@property(nonatomic) BOOL key;
@property(nonatomic) int64_t pts;
@end
@implementation RDEncodedFrame
- (instancetype)init {
    self = [super init];
    if (self) _ready = dispatch_semaphore_create(0);
    return self;
}
@end

@interface RDEncoder : NSObject
@property(nonatomic) VTCompressionSessionRef session;
@property(nonatomic, strong) NSArray<RDEncodedFrame *> *frames;
@property(nonatomic, strong) NSData *returnedPacket;
@property(nonatomic) NSUInteger readIndex;
@property(nonatomic) NSUInteger pending;
@property(nonatomic) BOOL hevc;
@end
@implementation RDEncoder
- (void)dealloc {
    if (_session) { VTCompressionSessionInvalidate(_session); CFRelease(_session); }
}
@end

static void rd_encoded(void *context, void *source, OSStatus status,
                       VTEncodeInfoFlags flags, CMSampleBufferRef sample) {
    @autoreleasepool {
        RDEncoder *encoder = (__bridge RDEncoder *)context;
        RDEncodedFrame *frame = (__bridge RDEncodedFrame *)source;
        frame.status = status;
        frame.packet = nil;
        if (!status && sample && CMSampleBufferDataIsReady(sample)) {
            CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
            BOOL key = !attachments || !CFArrayGetCount(attachments) ||
                !CFDictionaryContainsKey(CFArrayGetValueAtIndex(attachments, 0), kCMSampleAttachmentKey_NotSync);
            NSMutableData *packet = [NSMutableData data];
            const uint8_t prefix[] = {0, 0, 0, 1};
            CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
            int lengthSize = 0;
            size_t count = 0, length = 0;
            const uint8_t *bytes = NULL;
            OSStatus result = encoder.hevc
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, 0, &bytes, &length, &count, &lengthSize)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 0, &bytes, &length, &count, &lengthSize);
            if (result || lengthSize != 4) { frame.status = -1; goto done; }
            if (key) {
                for (size_t i = 0; i < count; i++) {
                    result = encoder.hevc
                        ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, i, &bytes, &length, NULL, NULL)
                        : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, i, &bytes, &length, NULL, NULL);
                    if (result) { frame.status = result; goto done; }
                    [packet appendBytes:prefix length:4];
                    [packet appendBytes:bytes length:length];
                }
            }
            CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
            size_t total = block ? CMBlockBufferGetDataLength(block) : 0;
            size_t offset = 0;
            while (offset + 4 <= total) {
                uint32_t bigLength = 0;
                if (CMBlockBufferCopyDataBytes(block, offset, 4, &bigLength)) { frame.status = -1; goto done; }
                size_t nalLength = CFSwapInt32BigToHost(bigLength);
                offset += 4;
                if (!nalLength || nalLength > total - offset) { frame.status = -1; goto done; }
                [packet appendBytes:prefix length:4];
                size_t start = packet.length;
                packet.length += nalLength;
                if (CMBlockBufferCopyDataBytes(block, offset, nalLength, (uint8_t *)packet.mutableBytes + start)) {
                    frame.status = -1; goto done;
                }
                offset += nalLength;
            }
            if (!total || offset != total) { frame.status = -1; goto done; }
            frame.packet = packet;
            frame.pts = CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample),
                                             1000, kCMTimeRoundingMethod_Default).value;
            frame.key = key;
        } else if (!status) {
            frame.status = -1;
        }
    done:
        dispatch_semaphore_signal(frame.ready);
    }
}

void *rd_vt_new(uint32_t width, uint32_t height, bool hevc, uint32_t kbps, uint32_t gop) {
    @autoreleasepool {
        RDEncoder *encoder = [RDEncoder new];
        encoder.hevc = hevc;
        encoder.frames = @[[RDEncodedFrame new], [RDEncodedFrame new],
                           [RDEncodedFrame new], [RDEncodedFrame new]];
        NSDictionary *spec = @{(__bridge NSString *)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: @YES};
        VTCompressionSessionRef session = NULL;
        if (VTCompressionSessionCreate(NULL, width, height,
                hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
                (__bridge CFDictionaryRef)spec, NULL, NULL, rd_encoded,
                (__bridge void *)encoder, &session)) return NULL;
        encoder.session = session;
        NSDictionary *properties = @{
            (__bridge NSString *)kVTCompressionPropertyKey_RealTime: @YES,
            (__bridge NSString *)kVTCompressionPropertyKey_AllowFrameReordering: @NO,
            (__bridge NSString *)kVTCompressionPropertyKey_ExpectedFrameRate: @60,
            (__bridge NSString *)kVTCompressionPropertyKey_AverageBitRate: @((uint64_t)kbps * 1000),
            (__bridge NSString *)kVTCompressionPropertyKey_MaxKeyFrameInterval: @(gop),
            (__bridge NSString *)kVTCompressionPropertyKey_ProfileLevel:
                (__bridge NSString *)(hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        };
        if (VTSessionSetProperties(session, (__bridge CFDictionaryRef)properties)) return NULL;
        if (VTCompressionSessionPrepareToEncodeFrames(session)) return NULL;
        CFTypeRef hardware = NULL;
        OSStatus result = VTSessionCopyProperty(session,
            kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, NULL, &hardware);
        BOOL accelerated = !result && hardware && CFEqual(hardware, kCFBooleanTrue);
        if (hardware) CFRelease(hardware);
        if (!accelerated) return NULL;
        return (__bridge_retained void *)encoder;
    }
}

int rd_vt_encode(void *opaque, CVPixelBufferRef buffer, int64_t ms,
                 const uint8_t **bytes, size_t *length, bool *key, int64_t *pts) {
    @autoreleasepool {
        RDEncoder *encoder = (__bridge RDEncoder *)opaque;
        NSUInteger capacity = encoder.frames.count;
        if (encoder.pending >= capacity) return -1;
        encoder.returnedPacket = nil;
        // A null buffer only drains output; it never resubmits a captured surface.
        if (buffer) {
            RDEncodedFrame *input = encoder.frames[(encoder.readIndex + encoder.pending) % capacity];
            input.packet = nil;
            OSStatus status = VTCompressionSessionEncodeFrame(encoder.session, buffer,
                CMTimeMake(ms, 1000), CMTimeMake(1, 60), NULL, (__bridge void *)input, NULL);
            if (status) return status;
            encoder.pending++;
        }
        if (!encoder.pending) return 1;
        RDEncodedFrame *output = encoder.frames[encoder.readIndex];
        long waitResult = dispatch_semaphore_wait(output.ready, DISPATCH_TIME_NOW);
        if (waitResult && (!buffer || encoder.pending < capacity)) return 1;
        if (waitResult) {
            waitResult = dispatch_semaphore_wait(output.ready, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
        }
        if (waitResult) return -1;
        encoder.pending--;
        encoder.readIndex = (encoder.readIndex + 1) % capacity;
        if (output.status || !output.packet.length) return output.status ?: -1;
        encoder.returnedPacket = output.packet;
        *bytes = encoder.returnedPacket.bytes;
        *length = encoder.returnedPacket.length;
        *key = output.key;
        *pts = output.pts;
        return 0;
    }
}

int rd_vt_quality(void *opaque, uint32_t kbps) {
    RDEncoder *encoder = (__bridge RDEncoder *)opaque;
    return VTSessionSetProperty(encoder.session, kVTCompressionPropertyKey_AverageBitRate,
                               (__bridge CFNumberRef)@((uint64_t)kbps * 1000));
}
void rd_vt_free(void *opaque) {
    RDEncoder *encoder = (__bridge_transfer RDEncoder *)opaque;
    VTCompressionSessionInvalidate(encoder.session);
}
