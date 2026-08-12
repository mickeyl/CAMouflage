#import "CMFProxies.h"
#import <objc/runtime.h>
#import <objc/message.h>

#if TARGET_OS_SIMULATOR

static void *kCMFInputDeviceKey = &kCMFInputDeviceKey;

// AVFoundation capture classes mark -init as unavailable and their designated
// initializers touch the (non-functional) capture backend. Instances here are
// alloc'd and initialized at the NSObject level only: ivars stay zeroed, every
// accessor an app may call is overridden, and CMFImmortalize prevents the
// superclass dealloc from ever running.
static id cmf_nsobject_init(id self) {
    struct objc_super sup = { self, [NSObject class] };
    return ((id (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, @selector(init));
}

id CMFNSObjectInit(id object) {
    return cmf_nsobject_init(object);
}

void CMFImmortalize(id object) {
    static NSMutableArray *immortals;
    static dispatch_once_t once;
    static dispatch_queue_t queue;
    dispatch_once(&once, ^{
        immortals = [NSMutableArray array];
        queue = dispatch_queue_create("camouflage.immortals", DISPATCH_QUEUE_SERIAL);
    });
    if (!object) return;
    dispatch_async(queue, ^{
        [immortals addObject:object];
    });
}

#pragma mark - CMFCaptureDevice

@implementation CMFCaptureDevice {
    NSString *_shimUniqueID;
    NSString *_shimName;
    AVCaptureDevicePosition _shimPosition;
}

+ (instancetype)deviceWithUniqueID:(NSString *)uniqueID
                              name:(NSString *)name
                          position:(AVCaptureDevicePosition)position {
    CMFCaptureDevice *device = cmf_nsobject_init([self alloc]);
    if (device) {
        device->_shimUniqueID = [uniqueID copy];
        device->_shimName = [name copy];
        device->_shimPosition = position;
        CMFImmortalize(device);
    }
    return device;
}

- (NSString *)shimUniqueID { return _shimUniqueID; }
- (NSString *)uniqueID { return _shimUniqueID; }
- (NSString *)modelID { return @"CAMouflage Virtual Camera"; }
- (NSString *)localizedName { return _shimName; }
- (NSString *)manufacturer { return @"Vanille Media"; }
- (AVCaptureDevicePosition)position { return _shimPosition; }
- (AVCaptureDeviceType)deviceType { return AVCaptureDeviceTypeBuiltInWideAngleCamera; }

- (BOOL)hasMediaType:(AVMediaType)mediaType {
    return [mediaType isEqualToString:AVMediaTypeVideo] || [mediaType isEqualToString:AVMediaTypeMuxed];
}

- (BOOL)isConnected { return YES; }
- (BOOL)isSuspended { return NO; }
- (BOOL)isVirtualDevice { return NO; }
- (NSArray *)formats { return @[]; }
- (AVCaptureDeviceFormat *)activeFormat { return nil; }
- (NSArray *)constituentDevices { return @[]; }

- (BOOL)supportsAVCaptureSessionPreset:(AVCaptureSessionPreset)preset { return YES; }

- (BOOL)lockForConfiguration:(NSError **)outError { return YES; }
- (void)unlockForConfiguration {}

- (BOOL)hasTorch { return NO; }
- (BOOL)isTorchAvailable { return NO; }
- (AVCaptureTorchMode)torchMode { return AVCaptureTorchModeOff; }
- (void)setTorchMode:(AVCaptureTorchMode)torchMode {}
- (BOOL)isTorchModeSupported:(AVCaptureTorchMode)torchMode { return NO; }
- (BOOL)hasFlash { return NO; }
- (BOOL)isFlashAvailable { return NO; }

- (BOOL)isFocusModeSupported:(AVCaptureFocusMode)focusMode { return focusMode == AVCaptureFocusModeLocked; }
- (AVCaptureFocusMode)focusMode { return AVCaptureFocusModeLocked; }
- (void)setFocusMode:(AVCaptureFocusMode)focusMode {}
- (BOOL)isFocusPointOfInterestSupported { return NO; }
- (BOOL)isAdjustingFocus { return NO; }

- (BOOL)isExposureModeSupported:(AVCaptureExposureMode)exposureMode { return exposureMode == AVCaptureExposureModeLocked; }
- (AVCaptureExposureMode)exposureMode { return AVCaptureExposureModeLocked; }
- (void)setExposureMode:(AVCaptureExposureMode)exposureMode {}
- (BOOL)isExposurePointOfInterestSupported { return NO; }
- (BOOL)isAdjustingExposure { return NO; }

- (BOOL)isWhiteBalanceModeSupported:(AVCaptureWhiteBalanceMode)whiteBalanceMode { return whiteBalanceMode == AVCaptureWhiteBalanceModeLocked; }
- (AVCaptureWhiteBalanceMode)whiteBalanceMode { return AVCaptureWhiteBalanceModeLocked; }
- (void)setWhiteBalanceMode:(AVCaptureWhiteBalanceMode)whiteBalanceMode {}
- (BOOL)isAdjustingWhiteBalance { return NO; }

- (CGFloat)videoZoomFactor { return 1.0; }
- (void)setVideoZoomFactor:(CGFloat)videoZoomFactor {}
- (CGFloat)minAvailableVideoZoomFactor { return 1.0; }
- (CGFloat)maxAvailableVideoZoomFactor { return 1.0; }
- (void)rampToVideoZoomFactor:(CGFloat)factor withRate:(float)rate {}
- (void)cancelVideoZoomRamp {}
- (BOOL)isRampingVideoZoom { return NO; }

- (BOOL)isLowLightBoostSupported { return NO; }
- (BOOL)isLowLightBoostEnabled { return NO; }
- (BOOL)isSubjectAreaChangeMonitoringEnabled { return NO; }
- (void)setSubjectAreaChangeMonitoringEnabled:(BOOL)enabled {}

- (NSString *)description {
    return [NSString stringWithFormat:@"<CMFCaptureDevice %@ (%@)>", _shimUniqueID, _shimName];
}

@end

#pragma mark - CMFDiscoverySession

@implementation CMFDiscoverySession {
    NSArray<AVCaptureDevice *> *_shimDevices;
}

+ (instancetype)sessionWithDevices:(NSArray<AVCaptureDevice *> *)devices {
    CMFDiscoverySession *session = cmf_nsobject_init([self alloc]);
    if (session) {
        session->_shimDevices = [devices copy];
        CMFImmortalize(session);
    }
    return session;
}

- (NSArray<AVCaptureDevice *> *)devices { return _shimDevices; }
- (NSArray *)supportedMultiCamDeviceSets { return @[]; }

@end

#pragma mark - CMFCaptureConnection

@implementation CMFCaptureConnection {
    AVCaptureVideoOrientation _shimOrientation;
    CGFloat _shimRotationAngle;
    BOOL _shimMirrored;
    BOOL _shimEnabled;
}

+ (instancetype)connectionShim {
    CMFCaptureConnection *connection = cmf_nsobject_init([self alloc]);
    if (connection) {
        connection->_shimOrientation = AVCaptureVideoOrientationPortrait;
        connection->_shimRotationAngle = 90.0;
        connection->_shimMirrored = NO;
        connection->_shimEnabled = YES;
        CMFImmortalize(connection);
    }
    return connection;
}

- (NSArray *)inputPorts { return @[]; }
- (BOOL)isEnabled { return _shimEnabled; }
- (void)setEnabled:(BOOL)enabled { _shimEnabled = enabled; }
- (BOOL)isActive { return YES; }

- (BOOL)isVideoOrientationSupported { return YES; }
- (AVCaptureVideoOrientation)videoOrientation { return _shimOrientation; }
- (void)setVideoOrientation:(AVCaptureVideoOrientation)videoOrientation { _shimOrientation = videoOrientation; }

- (BOOL)isVideoRotationAngleSupported:(CGFloat)videoRotationAngle { return YES; }
- (CGFloat)videoRotationAngle { return _shimRotationAngle; }
- (void)setVideoRotationAngle:(CGFloat)videoRotationAngle { _shimRotationAngle = videoRotationAngle; }

- (BOOL)isVideoMirroringSupported { return YES; }
- (BOOL)isVideoMirrored { return _shimMirrored; }
- (void)setVideoMirrored:(BOOL)videoMirrored { _shimMirrored = videoMirrored; }
- (BOOL)automaticallyAdjustsVideoMirroring { return NO; }
- (void)setAutomaticallyAdjustsVideoMirroring:(BOOL)automatically {}

- (BOOL)isVideoStabilizationSupported { return NO; }

@end

#pragma mark - AVCaptureDeviceInput shim marker

BOOL CMFDeviceInputIsShimmed(AVCaptureDeviceInput *input) {
    return objc_getAssociatedObject(input, kCMFInputDeviceKey) != nil;
}

void CMFDeviceInputMarkShimmed(AVCaptureDeviceInput *input, AVCaptureDevice *device) {
    objc_setAssociatedObject(input, kCMFInputDeviceKey, device, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CMFImmortalize(input);
}

AVCaptureDevice *CMFDeviceInputShimDevice(AVCaptureDeviceInput *input) {
    return objc_getAssociatedObject(input, kCMFInputDeviceKey);
}

#endif
