#import "CMFFrameStream.h"
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#if TARGET_OS_SIMULATOR

static const char *kCMFFrameSocketPath = "/tmp/camouflage-frames.sock";

// Fixed 32-byte little-endian frame header. The pixel-format tag is the seam
// for a future zero-copy upgrade; today it is always 'jpeg'.
typedef struct __attribute__((packed)) {
    uint32_t magic;         // 'CMF1' (little-endian: '1FMC' in byte order C M F 1)
    uint32_t payloadLength;
    uint32_t sessionId;
    uint16_t width;
    uint16_t height;
    uint32_t pixelFormat;   // 'jpeg'
    uint16_t rotation;      // degrees, clockwise
    uint8_t  mirrored;
    uint8_t  reserved;
    uint64_t ptsMicros;
} CMFFrameHeader;

_Static_assert(sizeof(CMFFrameHeader) == 32, "frame header must be 32 bytes");

static const uint32_t kCMFMagic = 'C' | ('M' << 8) | ('F' << 16) | ('1' << 24);

static CMFFrameHandler gFrameHandler;
static NSMutableDictionary<NSNumber *, dispatch_queue_t> *gStreamQueues;
static NSMutableDictionary<NSNumber *, NSNumber *> *gStreamFds;
static dispatch_queue_t gControlQueue;
static NSMutableDictionary<NSString *, id> *gPixelBufferPools;
static dispatch_queue_t gPixelBufferPoolQueue;

static dispatch_queue_t cmf_frame_control_queue(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gControlQueue = dispatch_queue_create("camouflage.frames.control", DISPATCH_QUEUE_SERIAL);
        gStreamQueues = [NSMutableDictionary dictionary];
        gStreamFds = [NSMutableDictionary dictionary];
    });
    return gControlQueue;
}

#pragma mark - JPEG → CMSampleBuffer

static CVPixelBufferPoolRef cmf_pixel_buffer_pool(size_t width, size_t height) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gPixelBufferPools = [NSMutableDictionary dictionary];
        gPixelBufferPoolQueue = dispatch_queue_create("camouflage.pixel-buffer-pools", DISPATCH_QUEUE_SERIAL);
    });

    NSString *key = [NSString stringWithFormat:@"%zux%zu", width, height];
    __block CVPixelBufferPoolRef pool = NULL;
    dispatch_sync(gPixelBufferPoolQueue, ^{
        pool = (__bridge CVPixelBufferPoolRef)gPixelBufferPools[key];
        if (pool) return;

        NSDictionary *poolAttributes = @{
            (id)kCVPixelBufferPoolMinimumBufferCountKey: @3,
        };
        // IOSurface-backed allocation is deliberately omitted. Some simulator
        // runtimes reject BGRA IOSurfaces before falling back, logging -6680 for
        // every frame. The hosted display layer accepts these pooled CPU buffers.
        NSDictionary *pixelAttributes = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(width),
            (id)kCVPixelBufferHeightKey: @(height),
            (id)kCVPixelBufferBytesPerRowAlignmentKey: @64,
            (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
            (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        };
        CVPixelBufferPoolRef newPool = NULL;
        CVReturn result = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                                  (__bridge CFDictionaryRef)poolAttributes,
                                                  (__bridge CFDictionaryRef)pixelAttributes,
                                                  &newPool);
        if (result == kCVReturnSuccess && newPool) {
            gPixelBufferPools[key] = (__bridge id)newPool;
            pool = newPool;
            CFRelease(newPool);
        }
    });
    return pool;
}

static CVPixelBufferRef cmf_pixel_buffer_from_jpeg(NSData *jpeg, size_t *outWidth, size_t *outHeight) {
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)jpeg, NULL);
    if (!source) {
        return NULL;
    }
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (!image) {
        return NULL;
    }

    size_t width = CGImageGetWidth(image);
    size_t height = CGImageGetHeight(image);

    CVPixelBufferRef pixelBuffer = NULL;
    CVPixelBufferPoolRef pool = cmf_pixel_buffer_pool(width, height);
    CVReturn result = pool
        ? CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        : kCVReturnInvalidArgument;
    if (result != kCVReturnSuccess || !pixelBuffer) {
        CGImageRelease(image);
        return NULL;
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pixelBuffer),
                                                 width, height, 8,
                                                 CVPixelBufferGetBytesPerRow(pixelBuffer),
                                                 colorSpace,
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    if (context) {
        CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
        CGContextRelease(context);
    }
    CGColorSpaceRelease(colorSpace);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    CGImageRelease(image);

    if (outWidth) *outWidth = width;
    if (outHeight) *outHeight = height;
    return pixelBuffer;
}

static void cmf_deliver_jpeg(uint32_t sessionId, NSData *jpeg, uint64_t ptsMicros) {
    CMFFrameHandler handler = gFrameHandler;
    if (!handler) {
        return;
    }
    size_t width = 0, height = 0;
    CVPixelBufferRef pixelBuffer = cmf_pixel_buffer_from_jpeg(jpeg, &width, &height);
    if (!pixelBuffer) {
        NSLog(@"CAMouflage: dropping undecodable frame (%lu bytes)", (unsigned long)jpeg.length);
        return;
    }

    CMVideoFormatDescriptionRef format = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &format) != noErr) {
        CVPixelBufferRelease(pixelBuffer);
        return;
    }

    CMSampleTimingInfo timing = {
        .duration = kCMTimeInvalid,
        .presentationTimeStamp = CMTimeMake((int64_t)ptsMicros, 1000000),
        .decodeTimeStamp = kCMTimeInvalid,
    };
    CMSampleBufferRef sampleBuffer = NULL;
    OSStatus status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixelBuffer,
                                                               format, &timing, &sampleBuffer);
    CFRelease(format);
    CVPixelBufferRelease(pixelBuffer);
    if (status != noErr || !sampleBuffer) {
        return;
    }

    // Without a synchronized timebase the display layer would hold frames
    // forever; mark them for immediate display instead.
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
    }

    handler(sessionId, sampleBuffer);
    CFRelease(sampleBuffer);
}

#pragma mark - Socket

static BOOL cmf_frame_write_all(int fd, const void *bytes, size_t length) {
    const uint8_t *ptr = (const uint8_t *)bytes;
    size_t remaining = length;
    while (remaining > 0) {
        ssize_t written = write(fd, ptr, remaining);
        if (written <= 0) {
            return NO;
        }
        ptr += (size_t)written;
        remaining -= (size_t)written;
    }
    return YES;
}

static void cmf_frame_read_loop(uint32_t sessionId, int fd) {
    NSMutableData *buffer = [NSMutableData data];
    while (1) {
        uint8_t tmp[65536];
        ssize_t n = read(fd, tmp, sizeof(tmp));
        if (n <= 0) {
            break;
        }
        [buffer appendBytes:tmp length:(NSUInteger)n];

        while (buffer.length >= sizeof(CMFFrameHeader)) {
            CMFFrameHeader header;
            memcpy(&header, buffer.bytes, sizeof(header));
            if (header.magic != kCMFMagic) {
                NSLog(@"CAMouflage: frame stream desynchronized (bad magic), closing");
                close(fd);
                return;
            }
            NSUInteger total = sizeof(header) + header.payloadLength;
            if (buffer.length < total) {
                break;
            }
            NSData *payload = [buffer subdataWithRange:NSMakeRange(sizeof(header), header.payloadLength)];
            [buffer replaceBytesInRange:NSMakeRange(0, total) withBytes:NULL length:0];
            cmf_deliver_jpeg(header.sessionId, payload, header.ptsMicros);
        }
    }
    NSLog(@"CAMouflage: frame stream for session %u ended", sessionId);
}

void CMFFrameStreamSetHandler(CMFFrameHandler handler) {
    gFrameHandler = [handler copy];
}

void CMFFrameStreamStart(uint32_t sessionId) {
    dispatch_async(cmf_frame_control_queue(), ^{
        NSNumber *key = @(sessionId);
        if (gStreamQueues[key]) {
            return;
        }

        struct sockaddr_un addr;
        memset(&addr, 0, sizeof(addr));
        addr.sun_family = AF_UNIX;
        strncpy(addr.sun_path, kCMFFrameSocketPath, sizeof(addr.sun_path) - 1);

        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) {
            return;
        }
#ifdef SO_NOSIGPIPE
        int suppressSIGPIPE = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &suppressSIGPIPE, sizeof(suppressSIGPIPE));
#endif
        if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
            NSLog(@"CAMouflage: frame socket connect failed for session %u", sessionId);
            close(fd);
            return;
        }

        NSDictionary *hello = @{@"sessionId": @(sessionId)};
        NSData *helloData = [NSJSONSerialization dataWithJSONObject:hello options:0 error:NULL];
        if (!helloData || !cmf_frame_write_all(fd, helloData.bytes, helloData.length) ||
            !cmf_frame_write_all(fd, "\n", 1)) {
            close(fd);
            return;
        }

        gStreamFds[key] = @(fd);
        dispatch_queue_t queue = dispatch_queue_create("camouflage.frames.read", DISPATCH_QUEUE_SERIAL);
        gStreamQueues[key] = queue;
        dispatch_async(queue, ^{
            cmf_frame_read_loop(sessionId, fd);
            dispatch_async(cmf_frame_control_queue(), ^{
                if ([gStreamFds[key] intValue] == fd) {
                    [gStreamFds removeObjectForKey:key];
                    [gStreamQueues removeObjectForKey:key];
                }
            });
        });
        NSLog(@"CAMouflage: frame stream started for session %u", sessionId);
    });
}

void CMFFrameStreamStop(uint32_t sessionId) {
    dispatch_async(cmf_frame_control_queue(), ^{
        NSNumber *key = @(sessionId);
        NSNumber *fdNumber = gStreamFds[key];
        if (fdNumber) {
            // Closing unblocks the read loop; cleanup happens there.
            close(fdNumber.intValue);
            [gStreamFds removeObjectForKey:key];
            [gStreamQueues removeObjectForKey:key];
        }
    });
}

#else

void CMFFrameStreamSetHandler(CMFFrameHandler handler) {}
void CMFFrameStreamStart(uint32_t sessionId) {}
void CMFFrameStreamStop(uint32_t sessionId) {}

#endif
