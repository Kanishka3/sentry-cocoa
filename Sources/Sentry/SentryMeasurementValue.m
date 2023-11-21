#import "SentryMeasurementValue.h"

NS_ASSUME_NONNULL_BEGIN

@implementation SentryMeasurementValue

+ (void)load
{
    NSLog(@"%llu %s", clock_gettime_nsec_np(CLOCK_UPTIME_RAW), __PRETTY_FUNCTION__);
}

- (instancetype)initWithValue:(NSNumber *)value
{
    if (self = [super init]) {
        _value = value;
    }
    return self;
}

- (instancetype)initWithValue:(NSNumber *)value unit:(SentryMeasurementUnit *)unit
{
    if (self = [super init]) {
        _value = value;
        _unit = unit;
    }
    return self;
}

- (NSDictionary<NSString *, id> *)serialize
{
    if (self.unit != nil) {
        return @{ @"value" : _value, @"unit" : _unit.unit };
    } else {
        return @{ @"value" : _value };
    }
}

@end

NS_ASSUME_NONNULL_END
