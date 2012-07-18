/****************************************************************************
 * URLConnectionOperation.m                                                 *
 * Created by Alexander Skobelev                                            *
 *                                                                          *
 ****************************************************************************/

#import "URLConnectionOperation.h"
#import "Reachability.h"
#import "CommonUtils.h"

#define DFNLOG(FMT$, ARGS$...) fprintf (stderr, "%s\n", [STRF(FMT$, ##ARGS$) UTF8String])

//============================================================================
@interface URLConnectionOperation ()
{
    UIBackgroundTaskIdentifier _backgroundTaskId;
    BOOL _isCancelled;
    BOOL _isFinished;
    BOOL _isExecuting;
}

@property (strong, nonatomic) NSLock* lock;
@property (strong, nonatomic) NSURLConnection*   connection;
@property (strong, nonatomic) NSMutableURLRequest* currentRequest;

@property (readwrite, nonatomic) NSMutableData* responseData;
@property (copy, nonatomic)   NSString*  partialPath;
@property (assign, nonatomic) size_t     contentLength;
@property (assign, nonatomic) size_t     downloadedLength;

@property (strong, nonatomic) NSTimer*      retryTimer;
@property (assign, nonatomic) int           retryCount;
@property (strong, nonatomic) Reachability* reachability;
@property (assign, nonatomic) NetworkStatus networkStatus;

@property (strong, nonatomic) NSMutableData* buffer;

- (BOOL) flushFileBuffer: (BOOL) force;
- (BOOL) startConnection;
- (void) stopConnection;

@end

//============================================================================
@implementation URLConnectionOperation 

@synthesize lock = _lock;

@synthesize error          = _error;
@synthesize connection     = _connection;
@synthesize currentRequest = _currentRequest;
@synthesize request        = _request;

@synthesize partialPath       = _partialPath;
@synthesize downloadPath      = _downloadPath;
@synthesize updateHandler     = _updateHandler;
@synthesize completionHandler = _completionHandler;

@synthesize contentLength    = _contentLength;
@synthesize downloadedLength = _downloadedLength;

@synthesize retryTimer = _retryTimer;
@synthesize retryCount = _retryCount;

@synthesize reachability  = _reachability;
@synthesize networkStatus = _networkStatus;

@synthesize buffer = _buffer;

@synthesize responseData = _responseData;
@synthesize response     = _response;


#define BUFFER_LIMIT 200000

//----------------------------------------------------------------------------
+ (void) treadProc
{
    while (YES) {
        @autoreleasepool { [[NSRunLoop currentRunLoop] run]; }
    };
}

//----------------------------------------------------------------------------
+ (NSThread*) workThread 
{
    static NSThread *_s_thread = nil;
    static dispatch_once_t _s_once;
    
    dispatch_once (&_s_once, ^ {
            _s_thread = 
                [[NSThread alloc] initWithTarget: self
                                        selector: @selector (treadProc)
                                          object: nil];

            _s_thread.name = STRF(@"%@ Shared Thread", NSStringFromClass(self));
            [_s_thread start];
        });
    
    return _s_thread;
}

//----------------------------------------------------------------------------
+ (NSString*) errorDomain
{
    return STRF(@"%@.%@", app_bundle_identifier(), NSStringFromClass(self));
}

//----------------------------------------------------------------------------
+ operationWithRequest: (NSURLRequest*) request
         updateHandler: (void (^)(URLConnectionOperation* op, size_t downloaded, size_t expected)) updateHandler
     completionHandler: (void (^)(URLConnectionOperation* op, NSError* err)) completionHandler
{
    return [[self alloc] 
               initWithRequest: request
                  downloadPath: nil
                 updateHandler: updateHandler
             completionHandler: completionHandler];
}

//----------------------------------------------------------------------------
+ operationWithRequest: (NSURLRequest*) request
          downloadPath: (NSString*) downloadPath
         updateHandler: (void (^)(URLConnectionOperation* op, size_t downloaded, size_t expected)) updateHandler
     completionHandler: (void (^)(URLConnectionOperation* op, NSError* err)) completionHandler
{
    return [[self alloc] 
               initWithRequest: request
                  downloadPath: downloadPath
                 updateHandler: updateHandler
             completionHandler: completionHandler];
}

//----------------------------------------------------------------------------
- (id) initWithRequest: (NSURLRequest*) request
          downloadPath: (NSString*) downloadPath
         updateHandler: (void (^)(URLConnectionOperation* op, size_t downloaded, size_t expected)) updateHandler
     completionHandler: (void (^)(URLConnectionOperation* op, NSError* err)) completionHandler
{
    if (! (self = [super init])) return nil;

    self.request           = request;
    self.currentRequest    = [request mutableCopy];
    self.downloadPath      = downloadPath;
    self.updateHandler     = updateHandler;
    self.completionHandler = completionHandler;

    self.lock = [NSLock new];
    self.lock.name = STRF(@"%@ %p Lock", NSStringFromClass([self class]), self);

    self.buffer = [NSMutableData dataWithCapacity: (BUFFER_LIMIT | 0xFFFF) + 1];

    _backgroundTaskId = UIBackgroundTaskInvalid;

    ADD_OBSERVER (kReachabilityChangedNotification,             self, onReachabilityNtf:);
    ADD_OBSERVER (UIApplicationDidEnterBackgroundNotification,  self, onEnterBackgroundNtf:);
    ADD_OBSERVER (UIApplicationWillEnterForegroundNotification, self, onExitBackgroundNtf:);

    return self;
}

//----------------------------------------------------------------------------
- (void) dealloc
{
    [self stopConnection];
    [self stopBackgroundTask];
    
    [self markExecuting: NO];

    REMOVE_OBSERVER (kReachabilityChangedNotification,             self);
    REMOVE_OBSERVER (UIApplicationDidEnterBackgroundNotification,  self);
    REMOVE_OBSERVER (UIApplicationWillEnterForegroundNotification, self);
}

//----------------------------------------------------------------------------
- (NSString*) description
{
    NSString* descr = nil;
    if (_downloadPath)
    {
        descr = STRF(@"%@ = {\n  URL = <%@>\n  download path = %@\n}", 
                     [super description], [_request URL], _downloadPath);
    }
    else
    {
        descr = STRF(@"%@ = { URL = <%@> }", [super description], [_request URL]);
    }
    return descr;
}

//----------------------------------------------------------------------------
- (BOOL) isConcurrent { return YES; }
- (BOOL) isCancelled  { return _isCancelled; }
- (BOOL) isFinished   { return _isFinished; }
- (BOOL) isExecuting  { return _isExecuting; }

//----------------------------------------------------------------------------
- (void) setIsCancelled: (BOOL) val { if (val != _isCancelled) WITH_KVO_CHANGE (self, isCancelled) { _isCancelled = val; } }
- (void) setIsFinished:  (BOOL) val { if (val != _isFinished)  WITH_KVO_CHANGE (self, isFinished)  { _isFinished  = val; } }
- (void) setIsExecuting: (BOOL) val { if (val != _isExecuting) WITH_KVO_CHANGE (self, isExecuting) { _isExecuting = val; } }

//----------------------------------------------------------------------------
- (void) markExecuting: (BOOL) flag
{
    self.isExecuting = flag;
    self.isFinished = ! flag;
}

//----------------------------------------------------------------------------
- (void) cancel
{
    WITH_LOCK (self.lock) 
    { 
        [self stopConnection];
        [self stopBackgroundTask];
        
        self.isExecuting = NO;
        self.isFinished  = YES;
        self.isCancelled = YES;
    }
}

//----------------------------------------------------------------------------
- (void) startConnectionLocked
{
    WITH_LOCK (self.lock)
    {
        if ([self startConnection])
        {
            self.isExecuting = YES;
        }
        else {
            self.isFinished = YES;
        }
    }
}

//----------------------------------------------------------------------------
- (void) start
{
    WITH_LOCK (self.lock)
    {
        if (! (self.isFinished || self.isCancelled))
        {
            [self performSelector: @selector (startConnectionLocked)
                         onThread: [[self class] workThread]
                       withObject: nil
                    waitUntilDone: NO
                            modes: NSARRAY (NSRunLoopCommonModes)];
        }
    }
}

//----------------------------------------------------------------------------
- (BOOL) startConnection
{
    self.error = nil;
    self.partialPath = nil;
    self.downloadedLength = 0;
    self.contentLength = 0;

    self.currentRequest = [self.request mutableCopy];

    if (self.downloadPath)
    {
        unlink ([self.downloadPath fileSystemRepresentation]);
        self.partialPath = STR_ADDEXT (self.downloadPath, @"partial");


        NSFileManager* fm = [NSFileManager defaultManager];
    
        if ([fm fileExistsAtPath: self.partialPath])
        {
            NSError* err;
            NSDictionary* attrs = [fm attributesOfItemAtPath: self.partialPath
                                                       error: &err];
            if (attrs) 
            {
                self.downloadedLength = attrs.fileSize;
            
                if (self.downloadedLength)
                {
                    id val = STRF(@"bytes=%d-", self.downloadedLength);

                    [self.currentRequest setValue: val 
                               forHTTPHeaderField: @"Range"];
                }
            }
            else {
                unlink ([self.partialPath fileSystemRepresentation]);
            }
        }
    }

    self.connection = [[NSURLConnection alloc] 
                          initWithRequest: self.currentRequest
                                 delegate: self
                         startImmediately: NO];

    if (self.connection) 
    {
        self.reachability = [Reachability reachabilityForLocalWiFi];
        self.networkStatus = [self.reachability currentReachabilityStatus];

        // Should be started and stopped on the same thread as it uses CFRunLoopGetCurrent()
        // Do not wait until done as it can lead to deadlock.
        [self.reachability performSelector: @selector(startNotifier)
                                  onThread: [[self class] workThread]
                                withObject: nil
                             waitUntilDone: NO];
        
        [self.connection scheduleInRunLoop: [NSRunLoop currentRunLoop]
                                   forMode: NSDefaultRunLoopMode];
        [self.connection start];
        return YES;
    }

    return NO;
}

//----------------------------------------------------------------------------
- (void) stopConnection
{
    [self flushFileBuffer: YES];

    if (self.connection) {
        [self.connection cancel];
        self.connection = nil;
    }

    if (self.retryTimer) {
        [self.retryTimer invalidate];
        self.retryTimer = nil;
    }

    if (self.reachability) 
    {
        // Should be started and stopped on the same thread as it uses CFRunLoopGetCurrent()
        // Do not wait until done as it can lead to deadlock.
        [self.reachability performSelector: @selector(stopNotifier)
                                  onThread: [[self class] workThread]
                                withObject: nil
                             waitUntilDone: NO];

        self.reachability = nil;
    }
}


//----------------------------------------------------------------------------
- (BOOL) flushFileBuffer: (BOOL) force
{
    BOOL ret = NO;
    if (self.partialPath)
    {
        if (self.buffer.length > (force ? 0 : BUFFER_LIMIT))
        {
            FILE* file = fopen (STR_FSREP (self.partialPath), "a");
            if (file) 
            {
                if (self.buffer.length == fwrite (self.buffer.bytes, 1, self.buffer.length, file))
                {
                    DFNLOG(@"Writing %d bytes into file '%@'", self.buffer.length, self.partialPath);
                    ret = YES;
                }
                else 
                {
                    DFNLOG(@"ERROR while writing data in file '%@'", self.partialPath);
                    ret = NO;
                }
                fclose (file);
            }
            [self.buffer setLength: 0];
        }
    }
    return ret;
}

//----------------------------------------------------------------------------
- (void) resetResponseData
{
    self.responseData = (self.contentLength > 0
                         ? [NSMutableData dataWithCapacity: self.contentLength] 
                         : [NSMutableData data]);
}

//----------------------------------------------------------------------------
- (void) stopBackgroundTask
{
    if (_backgroundTaskId != UIBackgroundTaskInvalid) 
    {
        [[UIApplication sharedApplication] endBackgroundTask: _backgroundTaskId];
        _backgroundTaskId = UIBackgroundTaskInvalid;
        DFNLOG (@"STOP BACKGROUND TASK");
    }
}

//----------------------------------------------------------------------------
- (void) startBackgroundTask
{
    if (_backgroundTaskId == UIBackgroundTaskInvalid) 
    {
        _backgroundTaskId = 
            [[UIApplication sharedApplication]
                beginBackgroundTaskWithExpirationHandler: ^{[self stopBackgroundTask];}];
        DFNLOG (@"START BACKGROUND TASK");
    }
}

//----------------------------------------------------------------------------
- (void) onReachabilityNtf: (NSNotification*) ntf
{
    WITH_LOCK (self.lock)
    {
        Reachability* reachability = [ntf object];

        if (ReachableViaWiFi == [reachability currentReachabilityStatus])
        {
            if (self.networkStatus != ReachableViaWiFi)
            {
                [self stopConnection];
                if (! [self startConnection])
                {
                    [self markExecuting: NO];
                }
            }
        }
    }
}

//----------------------------------------------------------------------------
- (void) onEnterBackgroundNtf: (NSNotification*) ntf
{
    WITH_LOCK (self.lock) {
        if (self.isExecuting) [self startBackgroundTask];
    }
}

//----------------------------------------------------------------------------
- (void) onExitBackgroundNtf: (NSNotification*) ntf
{
    WITH_LOCK (self.lock) { [self stopBackgroundTask]; }
}


//----------------------------------------------------------------------------
- (void) onRetryConnectionTimer: (NSTimer*) timer
{
    WITH_LOCK (self.lock) {
        if (! [self startConnection]) {
            [self markExecuting: NO];
        }
    }
}

//----------------------------------------------------------------------------
- (void) performUpdateHandler
{
    if (self.updateHandler) {
        dispatch_async (dispatch_get_main_queue(), 
                        ^{ 
                            self.updateHandler (self, self.downloadedLength, self.contentLength);
                        });
    }
}

//----------------------------------------------------------------------------
- (void) performCompletionHandler
{
    if (self.completionHandler) {
        dispatch_async (dispatch_get_main_queue(), 
                        ^{ 
                            self.completionHandler (self, self.error);
                        });
    }
}

//----------------------------------------------------------------------------
- (void) complete
{
    [self stopBackgroundTask];
    [self markExecuting: NO];
    [self performCompletionHandler];
}

//----------------------------------------------------------------------------
- (void) onDidReceiveResponse: (NSURLResponse*) response
{
    int http_status = [(NSHTTPURLResponse*)response statusCode];
    self.response = response;

    DFNLOG (@"CONNECTION %p GOT RESPONSE %d HEADERS: %@", self.connection, http_status, [(NSHTTPURLResponse*)response allHeaderFields]);
    DFNLOG (@"-- INITIAL REQUEST WAS: %@ %@", self.request, [self.request allHTTPHeaderFields]);


    if (http_status >= 300)
    {
        self.error = 
            [NSError errorWithDomain: [[self class] errorDomain]
                                code: DOWNLOAD_OPERATION_ERROR_CODE_HTTP_ERROR
                            userInfo: NSDICT (NSLocalizedDescriptionKey, STRLF (@"Server returned error: %d", http_status))];

        [self stopConnection];
        [self complete];
    
        return;
    }

    self.retryCount = 0;
    self.contentLength = response.expectedContentLength;

    if (http_status != 206)
    {
        if (self.downloadedLength)
        {
            self.downloadedLength = 0;

            if (self.partialPath) {
                unlink ([self.partialPath fileSystemRepresentation]);
            }
            else {
                self.responseData = nil;
            }
        }
    }
    self.contentLength += self.downloadedLength;

    if (! self.partialPath) {
        if (! self.responseData) [self resetResponseData];
    }

    DFNLOG (@"DOWNLOADED LENGTH: %d, EXPECTED LENGTH: %d, CONTENT LENGTH: %d", (int) self.downloadedLength, (int) response.expectedContentLength, (int) self.contentLength);
}


//----------------------------------------------------------------------------
- (void) onDidReceiveData: (NSData*) data
{
    if (data.length)
    {
        if (self.partialPath) 
        {
            if (self.buffer) {
                [self.buffer appendData: data];
            }
                
            [self flushFileBuffer: NO];
        }
        else {
            [self.responseData appendData: data];
        }

        self.downloadedLength += data.length;
        //DFNLOG(@"CONNECTION %p GOT DATA OF LENGTH: %d, DOWNLOADED LENGTH %d, CONTENT LENGTH: %d", connection, data.length, self.downloadedLength, self.contentLength);
        [self performUpdateHandler];
    }
}

//----------------------------------------------------------------------------
- (void) onFinishWithError: (NSError*) err
{
    DFNLOG (@"Connection %p FINISHED: %@\nERROR: %@\n", self.connection, self.request.URL, err);

    [self stopConnection];
    self.error = err;

    if (err)
    {
        static NSTimeInterval _s_interval[] = { 1.0, 3.0, 5.0 };
                
        if (self.retryCount < NELEMS(_s_interval))
        {
            self.retryTimer = 
                [NSTimer scheduledTimerWithTimeInterval: _s_interval [self.retryCount++]
                                                 target: self
                                               selector: @selector(onRetryConnectionTimer:)
                                               userInfo: nil
                                                repeats: NO];
        }                    
    }
    else 
    {
        if (self.downloadPath && self.partialPath)
        {
            unlink (STR_FSREP (self.downloadPath));
                    
            NSFileManager* fm = [NSFileManager defaultManager];

            if (! [fm moveItemAtPath: self.partialPath
                              toPath: self.downloadPath
                               error: &err])
            {
                DFNLOG (@"ERROR: Failed to copy partial file to '%@'. %@", self.downloadPath, [err localizedDescription]);
                self.error = err;
            }
        }
    }

    if (! self.retryTimer) 
    {
        [self complete];
    }
}

//----------------------------------------------------------------------------
- (void) connection: (NSURLConnection*) connection
 didReceiveResponse: (NSURLResponse*) response
{
    WITH_LOCK (self.lock) { [self onDidReceiveResponse: response]; }
}

//----------------------------------------------------------------------------
- (void) connection: (NSURLConnection*) connection 
     didReceiveData: (NSData*) data
{
    WITH_LOCK (self.lock) { [self onDidReceiveData: data]; }
}

//----------------------------------------------------------------------------
- (void) connectionDidFinishLoading: (NSURLConnection*) connection 
{
    WITH_LOCK (self.lock) { [self onFinishWithError: nil]; }
}

//----------------------------------------------------------------------------
- (void)  connection: (NSURLConnection*) connection 
    didFailWithError: (NSError*) error
{
    WITH_LOCK (self.lock) { [self onFinishWithError: error]; }
}

//----------------------------------------------------------------------------
- (NSURLRequest*) connection: (NSURLConnection*) connection 
             willSendRequest: (NSURLRequest*) request 
            redirectResponse: (NSURLResponse*) redirectResponse
{
    if (request.URL) 
    {
        NSURLRequest* old_request = self.currentRequest;
        NSMutableURLRequest* new_request = nil;
        
        NSDictionary* fields = [old_request allHTTPHeaderFields];
        if (fields) 
        {
            new_request = [NSMutableURLRequest 
                              requestWithURL: request.URL
                                 cachePolicy: [old_request cachePolicy]
                             timeoutInterval: [old_request timeoutInterval]];

            [fields enumerateKeysAndObjectsUsingBlock:
                ^(id key, id obj, BOOL *stop) 
                {
                    [new_request setValue: obj
                       forHTTPHeaderField: key];
                }];
        }
        else {
            new_request = (id) request;
        }

        self.currentRequest = new_request;
        return new_request;
    } 
    return nil;
}

@end
/* EOF */
