#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns YES when a CAMouflage provider (mock app or helper) is reachable.
/// Waits briefly for the initial device list, so it is safe to call at
/// start-up. On device builds this is a no-op returning NO.
FOUNDATION_EXPORT BOOL CAMouflageIsProviderConnected(void);

/// Temporarily replaces the provider's menu-bar selection for this simulator
/// process. The JSON object has this shape:
///
///     {
///       "name": "QR login",
///       "devices": [{
///         "id": "login-camera",
///         "name": "Login QR",
///         "position": "back",
///         "source": {
///           "kind": "machineCode",
///           "symbology": "qr",
///           "payload": "https://example.test/login"
///         }
///       }]
///     }
///
/// Sources may be `testPattern`, `machineCode`, an `image` with `dataBase64`,
/// or a `movie` with a host-side `path`. The configuration is never persisted,
/// is resent after a provider restart, and is discarded when this app exits or
/// calls `CAMouflageClearMockConfiguration`.
///
/// Returns NO when the data is not a JSON object or no provider is reachable.
/// Always returns NO on device builds.
FOUNDATION_EXPORT BOOL CAMouflageSetMockConfiguration(NSData *configurationJSON);

/// Hands control back to the menu-bar app's selected source.
FOUNDATION_EXPORT void CAMouflageClearMockConfiguration(void);

NS_ASSUME_NONNULL_END
