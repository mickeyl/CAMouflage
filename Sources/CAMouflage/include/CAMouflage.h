#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns YES when a CAMouflage provider (mock app or helper) is reachable.
/// Waits briefly for the initial device list, so it is safe to call at
/// start-up. On device builds this is a no-op returning NO.
FOUNDATION_EXPORT BOOL CAMouflageIsProviderConnected(void);

NS_ASSUME_NONNULL_END
