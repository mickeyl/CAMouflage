#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

#if TARGET_OS_SIMULATOR

/// Virtual capture device backed by the provider's device list. Instances are
/// created outside the normal init chain and kept alive forever — AVFoundation
/// dealloc paths must never run on their zeroed superclass ivars.
@interface CMFCaptureDevice : AVCaptureDevice
@property(nonatomic, readonly) NSString *shimUniqueID;
+ (instancetype)deviceWithUniqueID:(NSString *)uniqueID
                              name:(NSString *)name
                          position:(AVCaptureDevicePosition)position;
@end

@interface CMFDiscoverySession : AVCaptureDeviceDiscoverySession
+ (instancetype)sessionWithDevices:(NSArray<AVCaptureDevice *> *)devices;
@end

@interface CMFCaptureConnection : AVCaptureConnection
+ (instancetype)connectionShim;
@end

BOOL CMFDeviceInputIsShimmed(AVCaptureDeviceInput *input);
void CMFDeviceInputMarkShimmed(AVCaptureDeviceInput *input, AVCaptureDevice *device);
AVCaptureDevice *CMFDeviceInputShimDevice(AVCaptureDeviceInput *input);

/// Keeps proxy objects (and shimmed real objects) alive for the process
/// lifetime so partially-initialized AVFoundation instances never dealloc.
void CMFImmortalize(id object);

/// Initializes an alloc'd object at the NSObject level, bypassing unavailable
/// or backend-touching designated initializers.
id CMFNSObjectInit(id object);

#endif
