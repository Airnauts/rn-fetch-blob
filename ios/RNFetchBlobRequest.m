//
//  RNFetchBlobRequest.m
//  RNFetchBlob
//
//  Created by Artur Chrusciel on 15.01.18.
//  Copyright © 2018 wkh237.github.io. All rights reserved.
//

#import "RNFetchBlobRequest.h"

#import "RNFetchBlobFS.h"
#import "RNFetchBlobConst.h"
#import "RNFetchBlobReqBuilder.h"
#import "RNFetchBlobNetwork.h"

#import "IOS7Polyfill.h"
#import <CommonCrypto/CommonDigest.h>


typedef NS_ENUM(NSUInteger, ResponseFormat) {
    UTF8,
    BASE64,
    AUTO
};

@interface RNFetchBlobRequest ()
{
    BOOL respFile;
    BOOL isNewPart;
    BOOL isIncrement;
    NSMutableData * partBuffer;
    NSString * destPath;
    NSOutputStream * writeStream;
    long bodyLength;
    NSInteger respStatus;
    NSMutableArray * redirects;
    ResponseFormat responseFormat;
    BOOL followRedirect;
    BOOL isBackgroundDownloadTask;
}

@end

@implementation RNFetchBlobRequest

@synthesize taskId;
@synthesize expectedBytes;
@synthesize receivedBytes;
@synthesize respData;
@synthesize callback;
@synthesize bridge;
@synthesize options;
@synthesize error;

- (NSString *)md5:(NSString *)input {
    const char* str = [input UTF8String];
    unsigned char result[CC_MD5_DIGEST_LENGTH];
    CC_MD5(str, (CC_LONG)strlen(str), result);
    
    NSMutableString *ret = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH*2];
    for (int i = 0; i<CC_MD5_DIGEST_LENGTH; i++) {
        [ret appendFormat:@"%02x",result[i]];
    }
    return ret;
}

// send HTTP request
- (NSUInteger) sendRequest:(__weak NSDictionary  * _Nullable )options
       contentLength:(long) contentLength
              bridge:(RCTBridge * _Nullable)bridgeRef
              taskId:(NSString * _Nullable)taskId
         withRequest:(__weak NSURLRequest * _Nullable)req
  taskOperationQueue:(NSOperationQueue * _Nonnull)operationQueue
            callback:(_Nullable RCTResponseSenderBlock) callback
{
    self.taskId = taskId;
    self.respData = [[NSMutableData alloc] initWithLength:0];
    self.callback = callback;
    self.bridge = bridgeRef;
    self.expectedBytes = 0;
    self.receivedBytes = 0;
    self.options = options;
    
    isBackgroundDownloadTask = [options valueForKey:@"IOSBackgroundDownloadTask"] == nil ? NO : [[options valueForKey:@"IOSBackgroundDownloadTask"] boolValue];
    // when followRedirect not set in options, defaults to TRUE
    followRedirect = [options valueForKey:@"followRedirect"] == nil ? YES : [[options valueForKey:@"followRedirect"] boolValue];
    isIncrement = [[options valueForKey:@"increment"] boolValue];
    redirects = [[NSMutableArray alloc] init];
    
    if (req.URL) {
        [redirects addObject:req.URL.absoluteString];
    }

    // set response format
    NSString * rnfbResp = [req.allHTTPHeaderFields valueForKey:@"RNFB-Response"];
    
    if ([[rnfbResp lowercaseString] isEqualToString:@"base64"]) {
        responseFormat = BASE64;
    } else if ([[rnfbResp lowercaseString] isEqualToString:@"utf8"]) {
        responseFormat = UTF8;
    } else {
        responseFormat = AUTO;
    }
    
    NSString * path = [self.options valueForKey:CONFIG_FILE_PATH];
    NSString * key = [self.options valueForKey:CONFIG_KEY];
    NSURLSession * session;

    bodyLength = contentLength;
    
    // the session trust any SSL certification

    session = [self prepareSessionForTaskType:isBackgroundDownloadTask delegateQueue: operationQueue];

    if (path || [self.options valueForKey:CONFIG_USE_TEMP]) {
        respFile = YES;
        
        NSString* cacheKey = taskId;
        if (key) {
            cacheKey = [self md5:key];
            
            if (!cacheKey) {
                cacheKey = taskId;
            }
            
            destPath = [RNFetchBlobFS getTempPath:cacheKey withExtension:[self.options valueForKey:CONFIG_FILE_EXT]];
            
            if ([[NSFileManager defaultManager] fileExistsAtPath:destPath]) {
                callback(@[[NSNull null], RESP_TYPE_PATH, destPath]);
                
                return -1;
            }
        }
        
        if (path) {
            destPath = path;
        } else {
            destPath = [RNFetchBlobFS getTempPath:cacheKey withExtension:[self.options valueForKey:CONFIG_FILE_EXT]];
        }
    } else {
        respData = [[NSMutableData alloc] init];
        respFile = NO;
    }

    if (isBackgroundDownloadTask) {
        self.task = [session downloadTaskWithRequest:req];
    } else {
        self.task = [session dataTaskWithRequest:req];
    }

    [self.task resume];

    // network status indicator
    if ([[options objectForKey:CONFIG_INDICATOR] boolValue]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:YES];
        });
    }

    return self.task.taskIdentifier;
}

- (NSURLSession*)prepareSessionForTaskType:(BOOL)isBackgroundDownloadTask delegateQueue:(NSOperationQueue*)operationQueue {
    NSURLSession *session;

    if (isBackgroundDownloadTask) {
        session = [[RNFetchBlobNetwork sharedInstance] backgroundURLSession];

        float timeout = [options valueForKey:@"timeout"] == nil ? -1 : [[options valueForKey:@"timeout"] floatValue];

        if (timeout > 0) {
            session.configuration.timeoutIntervalForRequest = timeout/1000;
        }

    } else {

        NSURLSessionConfiguration *defaultConfigObject;
        defaultConfigObject = [NSURLSessionConfiguration defaultSessionConfiguration];

        // request timeout, -1 if not set in options
        float timeout = [options valueForKey:@"timeout"] == nil ? -1 : [[options valueForKey:@"timeout"] floatValue];

        if (timeout > 0) {
            defaultConfigObject.timeoutIntervalForRequest = timeout/1000;
        }

        defaultConfigObject.HTTPMaximumConnectionsPerHost = 10;

        session = [NSURLSession sessionWithConfiguration:defaultConfigObject delegate:self delegateQueue:operationQueue];
    }

    return session;
}

////////////////////////////////////////
//
//  NSURLSession delegates
//
////////////////////////////////////////


#pragma mark NSURLSession delegate methods


#pragma mark - Received Response
// set expected content length on response received
- (void) URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler
{
    expectedBytes = [response expectedContentLength];

    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse*)response;
    NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
    NSString * respType = @"";
    respStatus = statusCode;
    
    if ([response respondsToSelector:@selector(allHeaderFields)])
    {
        NSDictionary *headers = [httpResponse allHeaderFields];
        NSString * respCType = [[RNFetchBlobReqBuilder getHeaderIgnoreCases:@"Content-Type" fromHeaders:headers] lowercaseString];
        
        if (self.isServerPush) {
            if (partBuffer) {
                [self.bridge.eventDispatcher
                 sendDeviceEventWithName:EVENT_SERVER_PUSH
                 body:@{
                        @"taskId": taskId,
                        @"chunk": [partBuffer base64EncodedStringWithOptions:0],
                        }
                 ];
            }
            
            partBuffer = [[NSMutableData alloc] init];
            completionHandler(NSURLSessionResponseAllow);

            return;
        } else {
            self.isServerPush = [[respCType lowercaseString] RNFBContainsString:@"multipart/x-mixed-replace;"];
        }
        
        if(respCType)
        {
            NSArray * extraBlobCTypes = [options objectForKey:CONFIG_EXTRA_BLOB_CTYPE];
            
            if ([respCType RNFBContainsString:@"text/"]) {
                respType = @"text";
            } else if ([respCType RNFBContainsString:@"application/json"]) {
                respType = @"json";
            } else if(extraBlobCTypes) { // If extra blob content type is not empty, check if response type matches
                for (NSString * substr in extraBlobCTypes) {
                    if ([respCType RNFBContainsString:[substr lowercaseString]]) {
                        respType = @"blob";
                        respFile = YES;
                        destPath = [RNFetchBlobFS getTempPath:taskId withExtension:nil];
                        break;
                    }
                }
            } else {
                respType = @"blob";
                
                // for XMLHttpRequest, switch response data handling strategy automatically
                if ([options valueForKey:@"auto"]) {
                    respFile = YES;
                    destPath = [RNFetchBlobFS getTempPath:taskId withExtension:@""];
                }
            }
        } else {
            respType = @"text";
        }
        
#pragma mark - handling cookies
        // # 153 get cookies
        if (response.URL) {
            NSHTTPCookieStorage * cookieStore = [NSHTTPCookieStorage sharedHTTPCookieStorage];
            NSArray<NSHTTPCookie *> * cookies = [NSHTTPCookie cookiesWithResponseHeaderFields: headers forURL:response.URL];
            if (cookies.count) {
                [cookieStore setCookies:cookies forURL:response.URL mainDocumentURL:nil];
            }
        }
        
        [self.bridge.eventDispatcher
         sendDeviceEventWithName: EVENT_STATE_CHANGE
         body:@{
                @"taskId": taskId,
                @"state": @"2",
                @"headers": headers,
                @"redirects": redirects,
                @"respType" : respType,
                @"timeout" : @NO,
                @"status": [NSNumber numberWithInteger:statusCode]
                }
         ];
    } else {
        NSLog(@"oops");
    }
    
    if (respFile)
    {
        @try{
            NSFileManager * fm = [NSFileManager defaultManager];
            NSString * folder = [destPath stringByDeletingLastPathComponent];
            
            if (![fm fileExistsAtPath:folder]) {
                [fm createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:NULL error:nil];
            }
            
            // if not set overwrite in options, defaults to TRUE
            BOOL overwrite = [options valueForKey:@"overwrite"] == nil ? YES : [[options valueForKey:@"overwrite"] boolValue];
            BOOL appendToExistingFile = [destPath RNFBContainsString:@"?append=true"];
            
            appendToExistingFile = !overwrite;
            
            // For solving #141 append response data if the file already exists
            // base on PR#139 @kejinliang
            if (appendToExistingFile) {
                destPath = [destPath stringByReplacingOccurrencesOfString:@"?append=true" withString:@""];
            }
            
            if (![fm fileExistsAtPath:destPath]) {
                [fm createFileAtPath:destPath contents:[[NSData alloc] init] attributes:nil];
            }
            
            writeStream = [[NSOutputStream alloc] initToFileAtPath:destPath append:appendToExistingFile];
            [writeStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
            [writeStream open];
        }

        @catch(NSException * ex)
        {
            NSLog(@"write file error");
        }
    }
    
    completionHandler(NSURLSessionResponseAllow);
}

// download progress handler
- (void) URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data
{
    // For #143 handling multipart/x-mixed-replace response
    if (self.isServerPush)
    {
        [partBuffer appendData:data];
        
        return ;
    }
    
    NSNumber * received = [NSNumber numberWithLong:[data length]];
    receivedBytes += [received longValue];
    NSString * chunkString = @"";
    
    if (isIncrement) {
        chunkString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }
    
    if (respFile) {
        [writeStream write:[data bytes] maxLength:[data length]];
    } else {
        [respData appendData:data];
    }
    
    if (expectedBytes == 0) {
        return;
    }
    
    NSNumber * now =[NSNumber numberWithFloat:((float)receivedBytes/(float)expectedBytes)];
    
    if ([self.progressConfig shouldReport:now]) {
        [self.bridge.eventDispatcher
         sendDeviceEventWithName:EVENT_PROGRESS
         body:@{
                @"taskId": taskId,
                @"written": [NSString stringWithFormat:@"%lld", (long long) receivedBytes],
                @"total": [NSString stringWithFormat:@"%lld", (long long) expectedBytes],
                @"chunk": chunkString
                }
         ];
    }
}

#pragma mark - Download Task -

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {

    dispatch_async(dispatch_get_main_queue(), ^{
        [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
    });

    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse*)[downloadTask response];
    NSInteger statusCode = [httpResponse statusCode];

    if (statusCode >= 300 || statusCode < DOWNLOAD_STATUS_OK) {

        NSInteger errorStatusCode = statusCode ?: DOWNLOAD_STATUS_ERROR;

        [self.bridge.eventDispatcher
         sendDeviceEventWithName: EVENT_STATE_CHANGE
         body:@{
                @"taskId": taskId,
                @"state": @"2",
                @"redirects": redirects,
                @"timeout" : @NO,
                @"status": [NSNumber numberWithInteger: errorStatusCode]
                }
         ];

        callback(@[
                   [[NSError alloc] initWithDomain: @"rn.fetch.error" code: -1 userInfo: nil],
                   RESP_TYPE_PATH,
                   destPath ?: [NSNull null]
                   ]);

    } else {

        NSError *saveFileError;

        if (destPath) {

            NSFileManager * fm = [NSFileManager defaultManager];
            NSString * folder = [destPath stringByDeletingLastPathComponent];

            if (![fm fileExistsAtPath:folder]) {
                [fm createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:NULL error:nil];
            }

            if ([fm fileExistsAtPath:destPath]) {
                [fm removeItemAtPath:destPath error: &saveFileError];
            }

            NSURL *destinationURL = [NSURL fileURLWithPath:destPath];
            [fm moveItemAtURL:location toURL:destinationURL error: &saveFileError];

        } else {
            saveFileError = [[NSError alloc] initWithDomain: @"rn.fetch.error" code: -1 userInfo: nil];
        }

        NSInteger errorStatusCode = saveFileError == nil ? DOWNLOAD_STATUS_OK : DOWNLOAD_STATUS_ERROR;

        [self.bridge.eventDispatcher
         sendDeviceEventWithName: EVENT_STATE_CHANGE
         body:@{
                @"taskId": taskId,
                @"state": @"2",
                @"redirects": redirects,
                @"timeout" : @NO,
                @"status": [NSNumber numberWithInteger: errorStatusCode]
                }
         ];

        callback(@[
                    saveFileError ?: [NSNull null],
                    RESP_TYPE_PATH,
                    destPath ?: [NSNull null]
                   ]);

    }

    respData = nil;
    receivedBytes = 0;
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {

    if (totalBytesExpectedToWrite == 0) {
        return;
    }

    NSNumber * now =[NSNumber numberWithFloat:((float)totalBytesWritten/(float)totalBytesExpectedToWrite)];

    if ([self.progressConfig shouldReport:now]) {
        [self.bridge.eventDispatcher
         sendDeviceEventWithName:EVENT_PROGRESS
         body:@{
                @"taskId": taskId,
                @"written": [NSString stringWithFormat:@"%lld", (long long) totalBytesWritten],
                @"total": [NSString stringWithFormat:@"%lld", (long long) totalBytesExpectedToWrite],
                }
         ];
    }

}

#pragma mark - General Tasks Tracking -

- (void) URLSession:(NSURLSession *)session didBecomeInvalidWithError:(nullable NSError *)error
{
    if ([session isEqual:session]) {
        session = nil;
    }
}


- (void) URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{

    if ([task isKindOfClass:[NSURLSessionDownloadTask class]] && error == nil) {
        return;
    }

    self.error = error;
    NSString * errMsg;
    NSString * respStr;
    NSString * rnfbRespType;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
    });
    
    if (error) {
        if (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled) {
            errMsg = @"task cancelled";
        } else {
            errMsg = [error localizedDescription];
        }
    }
    
    if (respFile) {
        [writeStream close];
        rnfbRespType = RESP_TYPE_PATH;
        respStr = destPath;
    } else { // base64 response
        // #73 fix unicode data encoding issue :
        // when response type is BASE64, we should first try to encode the response data to UTF8 format
        // if it turns out not to be `nil` that means the response data contains valid UTF8 string,
        // in order to properly encode the UTF8 string, use URL encoding before BASE64 encoding.
        NSString * utf8 = [[NSString alloc] initWithData:respData encoding:NSUTF8StringEncoding];
        
        if (responseFormat == BASE64) {
            rnfbRespType = RESP_TYPE_BASE64;
            respStr = [respData base64EncodedStringWithOptions:0];
        } else if (responseFormat == UTF8) {
            rnfbRespType = RESP_TYPE_UTF8;
            respStr = utf8;
        } else {
            if (utf8) {
                rnfbRespType = RESP_TYPE_UTF8;
                respStr = utf8;
            } else {
                rnfbRespType = RESP_TYPE_BASE64;
                respStr = [respData base64EncodedStringWithOptions:0];
            }
        }
    }

    if ([task isKindOfClass:[NSURLSessionDownloadTask class]] && error != nil) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse*)[task response];
        NSInteger statusCode = [httpResponse statusCode];

        if (httpResponse == nil) {
            statusCode = DOWNLOAD_STATUS_ERROR;
        }

        [self.bridge.eventDispatcher
         sendDeviceEventWithName: EVENT_STATE_CHANGE
         body:@{
                @"taskId": taskId,
                @"state": @"2",
                @"redirects": redirects,
                @"timeout" : @NO,
                @"status": [NSNumber numberWithInteger: statusCode]
                }
         ];
    }
    
    callback(@[
               errMsg ?: [NSNull null],
               rnfbRespType ?: @"",
               respStr ?: [NSNull null]
               ]);
    
    respData = nil;
    receivedBytes = 0;

    if (isBackgroundDownloadTask == NO) {
        [session finishTasksAndInvalidate];
    }
    
}

// upload progress handler
- (void) URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didSendBodyData:(int64_t)bytesSent totalBytesSent:(int64_t)totalBytesWritten totalBytesExpectedToSend:(int64_t)totalBytesExpectedToWrite
{
    if (totalBytesExpectedToWrite == 0) {
        return;
    }
    
    NSNumber * now = [NSNumber numberWithFloat:((float)totalBytesWritten/(float)totalBytesExpectedToWrite)];

    if ([self.uploadProgressConfig shouldReport:now]) {
        [self.bridge.eventDispatcher
         sendDeviceEventWithName:EVENT_PROGRESS_UPLOAD
         body:@{
                @"taskId": taskId,
                @"written": [NSString stringWithFormat:@"%ld", (long) totalBytesWritten],
                @"total": [NSString stringWithFormat:@"%ld", (long) totalBytesExpectedToWrite]
                }
         ];
    }
}


- (void) URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential * _Nullable credantial))completionHandler
{
    if ([[options valueForKey:CONFIG_TRUSTY] boolValue]) {
        completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust]);
    } else {
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust]);
    }
}


- (void) URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session
{

    NSLog(@"sess done in background");
}

- (void) URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler
{
    
    if (followRedirect) {
        if (request.URL) {
            [redirects addObject:[request.URL absoluteString]];
        }
        
        completionHandler(request);
    } else {
        completionHandler(nil);
    }
}


@end
