#import "SentryConcurrentRateLimitsDictionary.h"
#import <Foundation/Foundation.h>

@interface
SentryConcurrentRateLimitsDictionary ()

/* Key is the type and value is valid until date */
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSDate *> *rateLimits;

@end

@implementation SentryConcurrentRateLimitsDictionary

+ (void)load
{
    NSLog(@"%llu %s", clock_gettime_nsec_np(CLOCK_UPTIME_RAW), __PRETTY_FUNCTION__);
}

- (instancetype)init
{
    if (self = [super init]) {
        self.rateLimits = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void)addRateLimit:(SentryDataCategory)category validUntil:(NSDate *)date
{
    @synchronized(self.rateLimits) {
        self.rateLimits[@(category)] = date;
    }
}

- (NSDate *)getRateLimitForCategory:(SentryDataCategory)category
{
    @synchronized(self.rateLimits) {
        return self.rateLimits[@(category)];
    }
}

@end
