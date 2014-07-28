//
//  Created by Stefan Reitshamer on 9/16/12.
//
//

#import "AWSQueryRequest.h"
#import "AWSQueryResponse.h"
#import "HTTPConnectionFactory.h"
#import "HTTPConnection.h"
#import "InputStream.h"
#import "HTTP.h"
#import "AWSQueryError.h"


#define INITIAL_RETRY_SLEEP (0.5)
#define RETRY_SLEEP_GROWTH_FACTOR (1.5)
#define MAX_RETRY_SLEEP (5.0)


@interface AWSQueryRequest ()
- (AWSQueryResponse *)executeOnce:(NSError **)error;
@end


@implementation AWSQueryRequest
- (id)initWithMethod:(NSString *)theMethod url:(NSURL *)theURL retryOnTransientError:(BOOL)theRetryOnTransientError {
    if (self = [super init]) {
        method = [theMethod retain];
        url = [theURL retain];
        retryOnTransientError = theRetryOnTransientError;
    }
    return self;
}
- (void)dealloc {
    [method release];
    [url release];
    [super dealloc];
}

- (NSString *)errorDomain {
    return @"AWSQueryRequestErrorDomain";
}
- (AWSQueryResponse *)execute:(NSError **)error {
    NSAutoreleasePool *pool = nil;
    NSTimeInterval sleepTime = INITIAL_RETRY_SLEEP;
    AWSQueryResponse *theResponse = nil;
    NSError *myError = nil;
    for (;;) {
        [pool drain];
        pool = [[NSAutoreleasePool alloc] init];
        BOOL transientError = NO;
        BOOL needSleep = NO;
        myError = nil;
        theResponse = [self executeOnce:&myError];
        if (theResponse != nil) {
            break;
        }
        if ([myError isErrorWithDomain:[self errorDomain] code:ERROR_NOT_FOUND]) {
            break;
        } else if ([[[myError userInfo] objectForKey:@"HTTPStatusCode"] intValue] == HTTP_INTERNAL_SERVER_ERROR) {
            transientError = YES;
        } else if ([myError isConnectionResetError]) {
            transientError = YES;
        } else if (retryOnTransientError && [myError isErrorWithDomain:[self errorDomain] code:HTTP_SERVICE_NOT_AVAILABLE]) {
            // Sometimes SQS returns a 503 error, and we're supposed to retry in that case.
            transientError = YES;
            needSleep = YES;
        } else if (retryOnTransientError && [myError isTransientError]) {
            transientError = YES;
            needSleep = YES;
        } else {
            HSLogError(@"%@ %@: %@", method, url, myError);
            break;
        }
        
        if (transientError) {
            HSLogDetail(@"retrying %@ %@: %@", method, url, myError);
        }
        if (needSleep) {
            [NSThread sleepForTimeInterval:sleepTime];
            sleepTime *= RETRY_SLEEP_GROWTH_FACTOR;
            if (sleepTime > MAX_RETRY_SLEEP) {
                sleepTime = MAX_RETRY_SLEEP;
            }
        }
    }
    [theResponse retain];
    [myError retain];
    [pool drain];
    [theResponse autorelease];
    [myError autorelease];
    if (error != NULL) { *error = myError; }
    return theResponse;
}


#pragma mark internal
- (AWSQueryResponse *)executeOnce:(NSError **)error {
    id <HTTPConnection> conn = [[[HTTPConnectionFactory theFactory] newHTTPConnectionToURL:url method:method dataTransferDelegate:nil] autorelease];
    if (conn == nil) {
        return nil;
    }
    [conn setRequestHostHeader];
    HSLogDebug(@"%@ %@", method, url);
    NSData *responseData = [conn executeRequest:error];
    if (responseData == nil) {
        return nil;
    }
    int code = [conn responseCode];
    if (code >= 200 && code <= 299) {
        HSLogDebug(@"HTTP %d; returning response length=%lu", code, (unsigned long)[responseData length]);
        AWSQueryResponse *response = [[[AWSQueryResponse alloc] initWithCode:code headers:[conn responseHeaders] body:responseData] autorelease];
        return response;
    }
    
    if (code == HTTP_NOT_FOUND) {
        SETNSERROR([self errorDomain], ERROR_NOT_FOUND, @"%@ not found", url);
        HSLogDebug(@"returning not-found error");
        return nil;
    }
    if (code == HTTP_METHOD_NOT_ALLOWED) {
        HSLogError(@"%@ 405 error", url);
        SETNSERROR([self errorDomain], ERROR_RRS_NOT_FOUND, @"%@ 405 error", url);
    }
    AWSQueryError *queryError = [[[AWSQueryError alloc] initWithDomain:[self errorDomain] httpStatusCode:code responseBody:responseData] autorelease];
    NSError *myError = [queryError nsError];
    HSLogDebug(@"%@ %@ error: %@", method, conn, myError);
    if (error != NULL) {
        *error = myError;
    }
    return nil;
}
@end
