#import "SentryFramesTracker.h"

#if SENTRY_HAS_UIKIT

#    import "SentryCompiler.h"
#    import "SentryCurrentDateProvider.h"
#    import "SentryDelayedFrame.h"
#    import "SentryDelayedFramesTracker.h"
#    import "SentryDisplayLinkWrapper.h"
#    import "SentryLog.h"
#    import "SentryProfiler.h"
#    import "SentryProfilingConditionals.h"
#    import "SentryTime.h"
#    import "SentryTracer.h"
#    import <SentryScreenFrames.h>
#    include <stdatomic.h>

#    if SENTRY_TARGET_PROFILING_SUPPORTED
/** A mutable version of @c SentryFrameInfoTimeSeries so we can accumulate results. */
typedef NSMutableArray<NSDictionary<NSString *, NSNumber *> *> SentryMutableFrameInfoTimeSeries;
#    endif // SENTRY_TARGET_PROFILING_SUPPORTED

static CFTimeInterval const SentryFrozenFrameThreshold = 0.7;
static CFTimeInterval const SentryPreviousFrameInitialValue = -1;

@interface
SentryFramesTracker ()

@property (nonatomic, strong, readonly) SentryDisplayLinkWrapper *displayLinkWrapper;
@property (nonatomic, strong, readonly) SentryCurrentDateProvider *dateProvider;
@property (nonatomic, assign) CFTimeInterval previousFrameTimestamp;
@property (nonatomic) uint64_t previousFrameSystemTimestamp;
@property (nonatomic) uint64_t currentFrameRate;
@property (nonatomic, strong) NSHashTable<id<SentryFramesTrackerListener>> *listeners;
#    if SENTRY_TARGET_PROFILING_SUPPORTED
@property (nonatomic, readwrite) SentryMutableFrameInfoTimeSeries *frozenFrameTimestamps;
@property (nonatomic, readwrite) SentryMutableFrameInfoTimeSeries *slowFrameTimestamps;
@property (nonatomic, readwrite) SentryMutableFrameInfoTimeSeries *frameRateTimestamps;
#    endif // SENTRY_TARGET_PROFILING_SUPPORTED

@property (nonatomic, strong) SentryDelayedFramesTracker *delayedFramesTracker;

@end

CFTimeInterval
slowFrameThreshold(uint64_t actualFramesPerSecond)
{
    // Most frames take just a few microseconds longer than the optimal calculated duration.
    // Therefore we subtract one, because otherwise almost all frames would be slow.
    return 1.0 / (actualFramesPerSecond - 1.0);
}

@implementation SentryFramesTracker {
    unsigned int _totalFrames;
    unsigned int _slowFrames;
    unsigned int _frozenFrames;
}

- (instancetype)initWithDisplayLinkWrapper:(SentryDisplayLinkWrapper *)displayLinkWrapper
                              dateProvider:(SentryCurrentDateProvider *)dateProvider
                 keepDelayedFramesDuration:(CFTimeInterval)keepDelayedFramesDuration
{
    if (self = [super init]) {
        _isRunning = NO;
        _displayLinkWrapper = displayLinkWrapper;
        _dateProvider = dateProvider;
        _delayedFramesTracker = [[SentryDelayedFramesTracker alloc]
            initWithKeepDelayedFramesDuration:keepDelayedFramesDuration
                                 dateProvider:dateProvider];

        _listeners = [NSHashTable weakObjectsHashTable];

        _currentFrameRate = 60;
        [self resetFrames];
        SENTRY_LOG_DEBUG(@"Initialized frame tracker %@", self);
    }
    return self;
}

/** Internal for testing */
- (void)setDisplayLinkWrapper:(SentryDisplayLinkWrapper *)displayLinkWrapper
{
    _displayLinkWrapper = displayLinkWrapper;
}

- (void)resetFrames
{
    _totalFrames = 0;
    _frozenFrames = 0;
    _slowFrames = 0;

    self.previousFrameTimestamp = SentryPreviousFrameInitialValue;
#    if SENTRY_TARGET_PROFILING_SUPPORTED
    [self resetProfilingTimestamps];
#    endif // SENTRY_TARGET_PROFILING_SUPPORTED

    [self.delayedFramesTracker resetDelayedFramesTimeStamps];
}

#    if SENTRY_TARGET_PROFILING_SUPPORTED
- (void)resetProfilingTimestamps
{
    self.frozenFrameTimestamps = [SentryMutableFrameInfoTimeSeries array];
    self.slowFrameTimestamps = [SentryMutableFrameInfoTimeSeries array];
    self.frameRateTimestamps = [SentryMutableFrameInfoTimeSeries array];
}
#    endif // SENTRY_TARGET_PROFILING_SUPPORTED

- (void)start
{
    if (_isRunning) {
        return;
    }

    _isRunning = YES;

    [_displayLinkWrapper linkWithTarget:self selector:@selector(displayLinkCallback)];
}

- (void)displayLinkCallback
{
    CFTimeInterval thisFrameTimestamp = self.displayLinkWrapper.timestamp;
    uint64_t thisFrameSystemTimestamp = self.dateProvider.systemTime;

    if (self.previousFrameTimestamp == SentryPreviousFrameInitialValue) {
        self.previousFrameTimestamp = thisFrameTimestamp;
        self.previousFrameSystemTimestamp = thisFrameSystemTimestamp;
        [self reportNewFrame];
        return;
    }

    // Calculate the actual frame rate as pointed out by the Apple docs:
    // https://developer.apple.com/documentation/quartzcore/cadisplaylink?language=objc The actual
    // frame rate can change at any time by setting preferredFramesPerSecond or due to ProMotion
    // display, low power mode, critical thermal state, and accessibility settings. Therefore we
    // need to check the frame rate for every callback.
    // targetTimestamp is only available on iOS 10.0 and tvOS 10.0 and above. We use a fallback of
    // 60 fps.
    _currentFrameRate = 60;
    if (self.displayLinkWrapper.targetTimestamp != self.displayLinkWrapper.timestamp) {
        _currentFrameRate = (uint64_t)round(
            (1 / (self.displayLinkWrapper.targetTimestamp - self.displayLinkWrapper.timestamp)));
    }

#    if SENTRY_TARGET_PROFILING_SUPPORTED
    if ([SentryProfiler isCurrentlyProfiling]) {
        BOOL hasNoFrameRatesYet = self.frameRateTimestamps.count == 0;
        uint64_t previousFrameRate
            = self.frameRateTimestamps.lastObject[@"value"].unsignedLongLongValue;
        BOOL frameRateChanged = previousFrameRate != _currentFrameRate;
        BOOL shouldRecordNewFrameRate = hasNoFrameRatesYet || frameRateChanged;
        if (shouldRecordNewFrameRate) {
            SENTRY_LOG_DEBUG(@"Recording new frame rate at %llu.", thisFrameSystemTimestamp);
            [self recordTimestamp:thisFrameSystemTimestamp
                            value:@(_currentFrameRate)
                            array:self.frameRateTimestamps];
        }
    }
#    endif // SENTRY_TARGET_PROFILING_SUPPORTED

    CFTimeInterval frameDuration = thisFrameTimestamp - self.previousFrameTimestamp;

    if (frameDuration > slowFrameThreshold(_currentFrameRate)
        && frameDuration <= SentryFrozenFrameThreshold) {
        _slowFrames++;
#    if SENTRY_TARGET_PROFILING_SUPPORTED
        SENTRY_LOG_DEBUG(@"Capturing slow frame starting at %llu (frame tracker: %@).",
            thisFrameSystemTimestamp, self);
        [self recordTimestamp:thisFrameSystemTimestamp
                        value:@(thisFrameSystemTimestamp - self.previousFrameSystemTimestamp)
                        array:self.slowFrameTimestamps];
#    endif // SENTRY_TARGET_PROFILING_SUPPORTED
    } else if (frameDuration > SentryFrozenFrameThreshold) {
        _frozenFrames++;
#    if SENTRY_TARGET_PROFILING_SUPPORTED
        SENTRY_LOG_DEBUG(@"Capturing frozen frame starting at %llu.", thisFrameSystemTimestamp);
        [self recordTimestamp:thisFrameSystemTimestamp
                        value:@(thisFrameSystemTimestamp - self.previousFrameSystemTimestamp)
                        array:self.frozenFrameTimestamps];
#    endif // SENTRY_TARGET_PROFILING_SUPPORTED
    }

    if (frameDuration > slowFrameThreshold(_currentFrameRate)) {
        [self.delayedFramesTracker recordDelayedFrame:self.previousFrameSystemTimestamp
                                     expectedDuration:slowFrameThreshold(_currentFrameRate)
                                       actualDuration:frameDuration];
    }

    _totalFrames++;
    self.previousFrameTimestamp = thisFrameTimestamp;
    self.previousFrameSystemTimestamp = thisFrameSystemTimestamp;
    [self reportNewFrame];
}

- (void)reportNewFrame
{
    NSArray *localListeners;
    @synchronized(self.listeners) {
        localListeners = [self.listeners allObjects];
    }

    NSDate *newFrameDate = [self.dateProvider date];

    for (id<SentryFramesTrackerListener> listener in localListeners) {
        [listener framesTrackerHasNewFrame:newFrameDate];
    }
}

#    if SENTRY_TARGET_PROFILING_SUPPORTED
- (void)recordTimestamp:(uint64_t)timestamp value:(NSNumber *)value array:(NSMutableArray *)array
{
    BOOL shouldRecord = [SentryProfiler isCurrentlyProfiling];
#        if defined(TEST) || defined(TESTCI)
    shouldRecord = YES;
#        endif // defined(TEST) || defined(TESTCI)
    if (shouldRecord) {
        [array addObject:@{ @"timestamp" : @(timestamp), @"value" : value }];
    }
}
#    endif // SENTRY_TARGET_PROFILING_SUPPORTED

- (SentryScreenFrames *)currentFrames
{
#    if SENTRY_TARGET_PROFILING_SUPPORTED
    return [[SentryScreenFrames alloc] initWithTotal:_totalFrames
                                              frozen:_frozenFrames
                                                slow:_slowFrames
                                 slowFrameTimestamps:self.slowFrameTimestamps
                               frozenFrameTimestamps:self.frozenFrameTimestamps
                                 frameRateTimestamps:self.frameRateTimestamps];
#    else
    return [[SentryScreenFrames alloc] initWithTotal:_totalFrames
                                              frozen:_frozenFrames
                                                slow:_slowFrames];
#    endif // SENTRY_TARGET_PROFILING_SUPPORTED
}

/**
 * The ThreadSanitizer ignores this method; see ThreadSanitizer.sup.
 *
 * We accept the data race of the two properties _currentFrameRate and previousFrameSystemTimestamp,
 * that are updated on the main thread in the displayLinkCallback. This method only reads these
 * properties. In most scenarios, this method will be called on the main thread, for which no
 * synchronization is needed. When calling this function from a background thread, the frames delay
 * statistics don't need to be that accurate because background spans contribute less to delayed
 * frames. We prefer having not 100% correct frames delay numbers for background spans instead of
 * adding the overhead of synchronization.
 */
- (CFTimeInterval)getFramesDelay:(uint64_t)startSystemTimestamp
              endSystemTimestamp:(uint64_t)endSystemTimestamp
{
    return [self.delayedFramesTracker getFramesDelay:startSystemTimestamp
                                  endSystemTimestamp:endSystemTimestamp
                                           isRunning:_isRunning
                        previousFrameSystemTimestamp:self.previousFrameSystemTimestamp
                                  slowFrameThreshold:slowFrameThreshold(_currentFrameRate)];
}

- (void)addListener:(id<SentryFramesTrackerListener>)listener
{

    @synchronized(self.listeners) {
        [self.listeners addObject:listener];
    }
}

- (void)removeListener:(id<SentryFramesTrackerListener>)listener
{
    @synchronized(self.listeners) {
        [self.listeners removeObject:listener];
    }
}

- (void)stop
{
    _isRunning = NO;
    [self.displayLinkWrapper invalidate];
    [self.delayedFramesTracker resetDelayedFramesTimeStamps];
    @synchronized(self.listeners) {
        [self.listeners removeAllObjects];
    }
}

- (void)dealloc
{
    [self stop];
}

@end

BOOL
sentryShouldAddSlowFrozenFramesData(
    NSInteger totalFrames, NSInteger slowFrames, NSInteger frozenFrames)
{
    BOOL allBiggerThanOrEqualToZero = totalFrames >= 0 && slowFrames >= 0 && frozenFrames >= 0;
    BOOL oneBiggerThanZero = totalFrames > 0 || slowFrames > 0 || frozenFrames > 0;

    return allBiggerThanOrEqualToZero && oneBiggerThanZero;
}

#endif // SENTRY_HAS_UIKIT
