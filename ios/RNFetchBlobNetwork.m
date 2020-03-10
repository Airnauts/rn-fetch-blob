//
//  RNFetchBlobNetwork.m
//  RNFetchBlob
//
//  Created by wkh237 on 2016/6/6.
//  Copyright © 2016 wkh237. All rights reserved.
//


#import <Foundation/Foundation.h>
#import "RNFetchBlobNetwork.h"

#import "RNFetchBlob.h"
#import "RNFetchBlobConst.h"
#import "RNFetchBlobProgress.h"

#if __has_include(<React/RCTAssert.h>)
#import <React/RCTRootView.h>
#import <React/RCTLog.h>
#import <React/RCTEventDispatcher.h>
#import <React/RCTBridge.h>
#else
#import "RCTRootView.h"
#import "RCTLog.h"
#import "RCTEventDispatcher.h"
#import "RCTBridge.h"
#endif

////////////////////////////////////////
//
//  HTTP request handler
//
////////////////////////////////////////

NSMapTable * expirationTable;
NSMutableDictionary * sessionDelegatesTable;

__attribute__((constructor))
static void initialize_tables() {
    if (expirationTable == nil) {
        expirationTable = [[NSMapTable alloc] init];
    }

    if (sessionDelegatesTable == nil) {
        sessionDelegatesTable = [NSMutableDictionary new];
    }
}

@interface RNFetchBlobNetwork () {
    NSURLSession *backgroundSession;
    void (^backgroundCompletionHandler)(void);
}

@end

@implementation RNFetchBlobNetwork

NSString *const kBackgroundSessionIdentifier = @"download.background.session";

- (id)init {
    self = [super init];
    if (self) {
        self.requestsTable = [NSMapTable mapTableWithKeyOptions:NSMapTableStrongMemory valueOptions:NSMapTableWeakMemory];

        self.taskQueue = [[NSOperationQueue alloc] init];
        self.taskQueue.qualityOfService = NSQualityOfServiceUtility;
        self.taskQueue.maxConcurrentOperationCount = 10;
        self.rebindProgressDict = [NSMutableDictionary dictionary];
        self.rebindUploadProgressDict = [NSMutableDictionary dictionary];
    }
    
    return self;
}

+ (RNFetchBlobNetwork* _Nullable)sharedInstance {
    static id _sharedInstance = nil;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        _sharedInstance = [[self alloc] init];
    });
    
    return _sharedInstance;
}

- (void)setBackgroundCompletionHandler:(void (^)(void))completionHandler {
    backgroundCompletionHandler = completionHandler;
}

- (NSURLSession *)backgroundURLSession {
    if (!backgroundSession) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{

            NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration
                                                        backgroundSessionConfigurationWithIdentifier: kBackgroundSessionIdentifier];
            configuration.HTTPMaximumConnectionsPerHost = 10;
            configuration.sessionSendsLaunchEvents = YES;

            backgroundSession = [NSURLSession sessionWithConfiguration:configuration delegate: self delegateQueue: nil];
        });
    }

    return backgroundSession;
}

- (void) sendRequest:(__weak NSDictionary  * _Nullable )options
       contentLength:(long) contentLength
              bridge:(RCTBridge * _Nullable)bridgeRef
              taskId:(NSString * _Nullable)taskId
         withRequest:(__weak NSURLRequest * _Nullable)req
            callback:(_Nullable RCTResponseSenderBlock) callback
{
    RNFetchBlobRequest *request = [[RNFetchBlobRequest alloc] init];
    NSUInteger sessionTaskIdentifier = [request sendRequest:options
           contentLength:contentLength
                  bridge:bridgeRef
                  taskId:taskId
             withRequest:req
      taskOperationQueue:self.taskQueue
                callback:callback];

    @synchronized (sessionDelegatesTable) {
        [sessionDelegatesTable setObject:request forKey:[NSNumber numberWithUnsignedInteger: sessionTaskIdentifier]];
    }
    
    @synchronized([RNFetchBlobNetwork class]) {
        [self.requestsTable setObject:request forKey:taskId];
        [self checkProgressConfig];
    }
}

- (void) checkProgressConfig {
    //reconfig progress
    [self.rebindProgressDict enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, RNFetchBlobProgress * _Nonnull config, BOOL * _Nonnull stop) {
        [self enableProgressReport:key config:config];
    }];
    [self.rebindProgressDict removeAllObjects];
    
    //reconfig uploadProgress
    [self.rebindUploadProgressDict enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, RNFetchBlobProgress * _Nonnull config, BOOL * _Nonnull stop) {
        [self enableUploadProgress:key config:config];
    }];
    [self.rebindUploadProgressDict removeAllObjects];
}

- (void) enableProgressReport:(NSString *) taskId config:(RNFetchBlobProgress *)config
{
    if (config) {
        @synchronized ([RNFetchBlobNetwork class]) {
            if (![self.requestsTable objectForKey:taskId]) {
                [self.rebindProgressDict setValue:config forKey:taskId];
            } else {
                [self.requestsTable objectForKey:taskId].progressConfig = config;
            }
        }
    }
}

- (void) enableUploadProgress:(NSString *) taskId config:(RNFetchBlobProgress *)config
{
    if (config) {
        @synchronized ([RNFetchBlobNetwork class]) {
            if (![self.requestsTable objectForKey:taskId]) {
                [self.rebindUploadProgressDict setValue:config forKey:taskId];
            } else {
                [self.requestsTable objectForKey:taskId].uploadProgressConfig = config;
            }
        }
    }
}

- (void)cancelBackgroundDownloadTasks {
    [backgroundSession getTasksWithCompletionHandler:^(NSArray<NSURLSessionDataTask *> * _Nonnull dataTasks,
                                                                               NSArray<NSURLSessionUploadTask *> * _Nonnull uploadTasks,
                                                                               NSArray<NSURLSessionDownloadTask *> * _Nonnull downloadTasks) {
        for (NSURLSessionDownloadTask* downloadTask in downloadTasks) {
            [downloadTask cancel];
        }
    }];
}

- (void) cancelRequest:(NSString *)taskId
{
    NSURLSessionDataTask * task;
    
    @synchronized ([RNFetchBlobNetwork class]) {
        task = [self.requestsTable objectForKey:taskId].task;
    }

    if (task && task.state == NSURLSessionTaskStateRunning) {
        [task cancel];
    }
}

// removing case from headers
+ (NSMutableDictionary *) normalizeHeaders:(NSDictionary *)headers
{
    NSMutableDictionary * mheaders = [[NSMutableDictionary alloc]init];
    for (NSString * key in headers) {
        [mheaders setValue:[headers valueForKey:key] forKey:[key lowercaseString]];
    }
    
    return mheaders;
}

// #115 Invoke fetch.expire event on those expired requests so that the expired event can be handled
+ (void) emitExpiredTasks
{
    @synchronized ([RNFetchBlobNetwork class]) {
        NSEnumerator * emu =  [expirationTable keyEnumerator];
        NSString * key;
        
        while ((key = [emu nextObject]))
        {
            RCTBridge * bridge = [RNFetchBlob getRCTBridge];
            id args = @{ @"taskId": key };
            [bridge.eventDispatcher sendDeviceEventWithName:EVENT_EXPIRE body:args];
        }
        
        // clear expired task entries
        [expirationTable removeAllObjects];
        expirationTable = [[NSMapTable alloc] init];
    }
}

#pragma mark - URLSession Delegate Methods -

#pragma mark - Received Response
// set expected content length on response received
- (void) URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {

    @synchronized (sessionDelegatesTable) {
        RNFetchBlobRequest* delegate = [sessionDelegatesTable objectForKey: [NSNumber numberWithUnsignedInteger:dataTask.taskIdentifier]];
        if (delegate) {
            [delegate URLSession:session
                        dataTask:dataTask
              didReceiveResponse:response
               completionHandler:completionHandler];
        }
    }

}

// download progress handler
- (void) URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data
{

    @synchronized (sessionDelegatesTable) {
        RNFetchBlobRequest* delegate = [sessionDelegatesTable objectForKey: [NSNumber numberWithUnsignedInteger:dataTask.taskIdentifier]];
        if (delegate) {
            [delegate URLSession:session
                        dataTask:dataTask
                  didReceiveData:data];
        }
    }

}

#pragma mark - Download Task -

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {

    @synchronized (sessionDelegatesTable) {
        RNFetchBlobRequest* delegate = [sessionDelegatesTable objectForKey: [NSNumber numberWithUnsignedInteger:downloadTask.taskIdentifier]];
        if (delegate) {

            [delegate URLSession:session
                    downloadTask:downloadTask
       didFinishDownloadingToURL:location];

            [sessionDelegatesTable removeObjectForKey: [NSNumber numberWithUnsignedInteger:downloadTask.taskIdentifier]];
        }
    }

}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {

    @synchronized (sessionDelegatesTable) {
        RNFetchBlobRequest* delegate = [sessionDelegatesTable objectForKey: [NSNumber numberWithUnsignedInteger:downloadTask.taskIdentifier]];
        if (delegate) {
            
            [delegate URLSession:session
                    downloadTask:downloadTask
                    didWriteData:bytesWritten
               totalBytesWritten:totalBytesWritten
       totalBytesExpectedToWrite:totalBytesExpectedToWrite];
        }
    }

}

#pragma mark - General Tasks Tracking -

- (void) URLSession:(NSURLSession *)session didBecomeInvalidWithError:(nullable NSError *)error
{
    if ([session isEqual:backgroundSession]) {
        session = nil;
    }
}


- (void) URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{

    @synchronized (sessionDelegatesTable) {
        RNFetchBlobRequest* delegate = [sessionDelegatesTable objectForKey: [NSNumber numberWithUnsignedInteger:task.taskIdentifier]];

        if (delegate) {
            [delegate URLSession:session task:task didCompleteWithError:error];
        }

        @synchronized (sessionDelegatesTable) {
            [sessionDelegatesTable removeObjectForKey: [NSNumber numberWithUnsignedInteger: task.taskIdentifier]];
        }
    }

}

// upload progress handler
- (void) URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didSendBodyData:(int64_t)bytesSent totalBytesSent:(int64_t)totalBytesWritten totalBytesExpectedToSend:(int64_t)totalBytesExpectedToWrite
{

    @synchronized (sessionDelegatesTable) {
        RNFetchBlobRequest* delegate = [sessionDelegatesTable objectForKey: [NSNumber numberWithUnsignedInteger:task.taskIdentifier]];

        if (delegate) {
            [delegate URLSession:session
                            task:task
                 didSendBodyData:bytesSent
                  totalBytesSent:totalBytesWritten
        totalBytesExpectedToSend:totalBytesExpectedToWrite];
        }
    }
}


- (void) URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential * _Nullable credantial))completionHandler
{

    @synchronized (sessionDelegatesTable) {

         for (id key in sessionDelegatesTable) {
             RNFetchBlobRequest *delegate = [sessionDelegatesTable objectForKey:key];
             if (delegate && [delegate respondsToSelector:@selector(URLSession:didReceiveChallenge:completionHandler:)]) {
                 [delegate URLSession:session didReceiveChallenge:challenge completionHandler:completionHandler];
             }
         }

    }
}


- (void) URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session
{
    if (backgroundCompletionHandler) {
        backgroundCompletionHandler();
    }
    NSLog(@"sess done in background");
}

- (void) URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler
{

    @synchronized (sessionDelegatesTable) {
        RNFetchBlobRequest* delegate = [sessionDelegatesTable objectForKey: [NSNumber numberWithUnsignedInteger:task.taskIdentifier]];
        if (delegate) {
            [delegate URLSession:session
                            task:task
      willPerformHTTPRedirection:response
                      newRequest:request
               completionHandler:completionHandler];
        }
    }
}

@end
