#import "SentryFrame.h"
#import "NSMutableDictionary+Sentry.h"

NS_ASSUME_NONNULL_BEGIN

@implementation SentryFrame

+ (void)load
{
    NSLog(@"%llu %s", clock_gettime_nsec_np(CLOCK_UPTIME_RAW), __PRETTY_FUNCTION__);
}

- (instancetype)init
{
    if (self = [super init]) {
        self.function = @"<redacted>";
    }
    return self;
}

- (NSDictionary<NSString *, id> *)serialize
{
    NSMutableDictionary *serializedData = [NSMutableDictionary new];

    [serializedData setValue:self.symbolAddress forKey:@"symbol_addr"];
    [serializedData setValue:self.fileName forKey:@"filename"];
    [serializedData setValue:self.function forKey:@"function"];
    [serializedData setValue:self.module forKey:@"module"];
    [serializedData setValue:self.lineNumber forKey:@"lineno"];
    [serializedData setValue:self.columnNumber forKey:@"colno"];
    [serializedData setValue:self.package forKey:@"package"];
    [serializedData setValue:self.imageAddress forKey:@"image_addr"];
    [serializedData setValue:self.instructionAddress forKey:@"instruction_addr"];
    [serializedData setValue:self.platform forKey:@"platform"];
    [serializedData setBoolValue:self.inApp forKey:@"in_app"];
    [serializedData setBoolValue:self.stackStart forKey:@"stack_start"];

    return serializedData;
}

@end

NS_ASSUME_NONNULL_END
