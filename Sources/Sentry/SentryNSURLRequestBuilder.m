#import "SentryNSURLRequestBuilder.h"
#import "SentryDsn.h"
#import "SentryNSURLRequest.h"
#import "SentrySerialization.h"
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@implementation SentryNSURLRequestBuilder

+ (void)load
{
    NSLog(@"%llu %s", clock_gettime_nsec_np(CLOCK_UPTIME_RAW), __PRETTY_FUNCTION__);
}

- (NSURLRequest *)createEnvelopeRequest:(SentryEnvelope *)envelope
                                    dsn:(SentryDsn *)dsn
                       didFailWithError:(NSError *_Nullable *_Nullable)error
{
    return [[SentryNSURLRequest alloc]
        initEnvelopeRequestWithDsn:dsn
                           andData:[SentrySerialization dataWithEnvelope:envelope error:error]
                  didFailWithError:error];
}

@end

NS_ASSUME_NONNULL_END
