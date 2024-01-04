#import "SentryFramesTrackingIntegration.h"

#if SENTRY_HAS_UIKIT

#    import "PrivateSentrySDKOnly.h"
#    import "SentryDependencyContainer.h"
#    import "SentryLog.h"

#    import "SentryFramesTracker.h"

NS_ASSUME_NONNULL_BEGIN

@interface
SentryFramesTrackingIntegration ()

@property (nonatomic, strong) SentryFramesTracker *tracker;

@end

@implementation SentryFramesTrackingIntegration

+ (void)load
{
    NSLog(@"%llu %s", clock_gettime_nsec_np(CLOCK_UPTIME_RAW), __PRETTY_FUNCTION__);
}

- (BOOL)installWithOptions:(SentryOptions *)options
{
    if (!PrivateSentrySDKOnly.framesTrackingMeasurementHybridSDKMode
        && ![super installWithOptions:options]) {
        return NO;
    }

    self.tracker = SentryDependencyContainer.sharedInstance.framesTracker;
    [self.tracker start];

    return YES;
}

- (SentryIntegrationOption)integrationOptions
{
    return kIntegrationOptionEnableAutoPerformanceTracing | kIntegrationOptionIsTracingEnabled;
}

- (void)uninstall
{
    [self stop];
}

- (void)stop
{
    if (nil != self.tracker) {
        [self.tracker stop];
    }
}

@end

NS_ASSUME_NONNULL_END

#endif // SENTRY_HAS_UIKIT
