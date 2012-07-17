/****************************************************************************
 * DownloadOperation.m                                                      *
 * Created by Alexander Skobelev                                            *
 *                                                                          *
 ****************************************************************************/

#import "DownloadOperation.h"
#import "Reachability.h"
#import "CommonUtils.h"

#define DFNLOG(FMT$, ARGS$...) fprintf (stderr, "%s\n", [STRF(FMT$, ##ARGS$) UTF8String])
#define ELOG(FMT$, ARGS$...)   fprintf (stderr, "%s\n", [STRF(FMT$, ##ARGS$) UTF8String])

//============================================================================
@interface DownloadOperation ()
{
    UIBackgroundTaskIdentifier _backgroundTaskId;
    BOOL _isCancelled;
    BOOL _isFinished;
    BOOL _isExecuting;
}

@property (strong, nonatomic) NSURLConnection*   connection;
@property (strong, nonatomic) NSMutableURLRequest* currentRequest;

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
@implementation DownloadOperation 

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

#define BUFFER_LIMIT 200000

//----------------------------------------------------------------------------
+ (void) downloadThreadProc
{
    while (1) 
    {
        @autoreleasepool {
            [[NSRunLoop currentRunLoop] run];
        }
    };
}

//----------------------------------------------------------------------------
+ (NSThread*) downloadThread 
{
    static NSThread *_s_thread = nil;
    static dispatch_once_t _s_once;
    
    dispatch_once (&_s_once, ^ {
            _s_thread = 
                [[NSThread alloc] initWithTarget: self
                                        selector: @selector (downloadThreadProc)
                                          object: nil];

            _s_thread.name = @"DownloadOperation Shared Thread";
            [_s_thread start];
        });
    
    return _s_thread;
}

//----------------------------------------------------------------------------
+ (NSOperationQueue*) downloadQueue
{
    static dispatch_once_t _s_once;
    static id _s_queue = nil;
    
    dispatch_once (&_s_once, ^{ 
            _s_queue = [NSOperationQueue new]; 
            [_s_queue setMaxConcurrentOperationCount: 1];
        });

    return _s_queue;
}

//----------------------------------------------------------------------------
+ (NSString*) errorDomain
{
    return STRF(@"%@.%@", app_bundle_identifier(), DOWNLOAD_OPERATION_ERROR_SUBDOMAIN);
}


//----------------------------------------------------------------------------
+ operationWithRequest: (NSURLRequest*) request
          downloadPath: (NSString*) downloadPath
         updateHandler: (void (^)(DownloadOperation* op, size_t downloaded, size_t expected)) updateHandler
     completionHandler: (void (^)(DownloadOperation* op, NSError* err)) completionHandler
{
    return [[self alloc] 
               initWithRequest: request
                 downaloadPath: downloadPath
                 updateHandler: updateHandler
             completionHandler: completionHandler];
}

//----------------------------------------------------------------------------
- (id) initWithRequest: (NSURLRequest*) request
         downaloadPath: (NSString*) downloadPath
         updateHandler: (void (^)(DownloadOperation* op, size_t downloaded, size_t expected)) updateHandler
     completionHandler: (void (^)(DownloadOperation* op, NSError* err)) completionHandler
{
    if (! (self = [super init])) return nil;

    self.request           = request;
    self.currentRequest    = [request mutableCopy];
    self.downloadPath      = downloadPath;
    self.updateHandler     = updateHandler;
    self.completionHandler = completionHandler;

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
    NSString* descr = STRF(@"%@ = {\n  URL = <%@>", [super description], [_request URL]);
    
    descr = ((_downloadPath) ? STRF (@"%@\n  download path = %@\n}", descr, _downloadPath)
             : STR_ADD (descr, @"\n}"));
    
    return descr;
}

//----------------------------------------------------------------------------
- (BOOL) isCancelled { return _isCancelled; }
- (BOOL) isFinished  { return _isFinished; }
- (BOOL) isExecuting { return _isExecuting; }

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
- (BOOL) isConcurrent
{
    return YES;
}

//----------------------------------------------------------------------------
- (void) enqueue
{
    NSOperationQueue* queue = [[self class] downloadQueue];
    [queue addOperation: self];
}

//----------------------------------------------------------------------------
- (BOOL) performSelectorOnDownloadThread: (SEL) sel
                              withObject: (id) obj
{
    NSThread* thread = [[self class] downloadThread];
    if (thread && [NSThread currentThread] != thread)
    {
        [self performSelector: sel
                     onThread: thread
                   withObject: nil
                waitUntilDone: YES];

        return YES;
    }
    return NO;
}

//----------------------------------------------------------------------------
- (BOOL) performSelectorOnDownloadThread: (SEL) sel
{
    return [self performSelectorOnDownloadThread: sel
                                      withObject: nil];
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

    if (self.reachability) {
        [self.reachability stopNotifier];
        self.reachability = nil;
    }
}


//----------------------------------------------------------------------------
- (void) cancel
{
    if (! [self performSelectorOnDownloadThread: _cmd])
    {
        [self stopConnection];
        [self stopBackgroundTask];
        
        self.isExecuting = NO;
        self.isFinished  = YES;
        self.isCancelled = YES;
    }
}

//----------------------------------------------------------------------------
- (void) start
{
    if (! [self performSelectorOnDownloadThread: _cmd])
    {
        if (! (self.isFinished || self.isCancelled))
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
}

//----------------------------------------------------------------------------
- (BOOL) startConnection
{
    self.error = nil;
    self.partialPath = nil;
    self.downloadedLength = 0;
    self.contentLength = 0;

    self.currentRequest = [self.request mutableCopy];

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

    self.connection = [[NSURLConnection alloc] 
                          initWithRequest: self.currentRequest
                                 delegate: self
                         startImmediately: NO];

    if (self.connection) 
    {
        if (! self.reachability) {
            self.reachability = [Reachability reachabilityForLocalWiFi];
        }

        self.networkStatus = [self.reachability currentReachabilityStatus];
        [self.reachability startNotifier];
        
        [self.connection scheduleInRunLoop: [NSRunLoop currentRunLoop]
                                   forMode: NSDefaultRunLoopMode];
        [self.connection start];
        return YES;
    }

    return NO;
}

//----------------------------------------------------------------------------
- (BOOL) flushFileBuffer: (BOOL) force
{
    BOOL ret = NO;
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
    return ret;
}

//----------------------------------------------------------------------------
- (void) stopBackgroundTask
{
    if (_backgroundTaskId != UIBackgroundTaskInvalid) 
    {
        [[UIApplication sharedApplication] endBackgroundTask: _backgroundTaskId];
        _backgroundTaskId = UIBackgroundTaskInvalid;
        DFNLOG(@"STOP BACKGROUND TASK");
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
        DFNLOG(@"START BACKGROUND TASK");
    }
}

//----------------------------------------------------------------------------
- (void) onReachabilityNtf: (NSNotification*) ntf
{
    if (! [self performSelectorOnDownloadThread: _cmd
                                     withObject: ntf])
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
    if (! [self performSelectorOnDownloadThread: _cmd
                                     withObject: ntf])
    {
        if (self.isExecuting) [self startBackgroundTask];
    }
}

//----------------------------------------------------------------------------
- (void) onExitBackgroundNtf: (NSNotification*) ntf
{
    if (! [self performSelectorOnDownloadThread: _cmd
                                     withObject: ntf])
    { 
        [self stopBackgroundTask]; 
    }
}


//----------------------------------------------------------------------------
- (void) onRetryConnectionTimer: (NSTimer*) timer
{
    if (! [self performSelectorOnDownloadThread: _cmd
                                     withObject: timer])
    {
        if (! [self startConnection])
        {
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
    if (self.completionHandler) 
    {
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

    DFNLOG (@"CONNECTION %p GOT RESPONSE %d HEADERS: %@", self.connection, http_status, [(NSHTTPURLResponse*) response allHeaderFields]);
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
            if (self.partialPath) 
            {
                self.downloadedLength = 0;
                unlink ([self.partialPath fileSystemRepresentation]);
            }
        }
    }

    self.contentLength += (self.partialPath ? self.downloadedLength : 0);
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
                ELOG (@"ERROR: Failed to copy partial file to '%@'. %@", self.downloadPath, [err localizedDescription]);
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
    if (! [self performSelectorOnDownloadThread: @selector(onDidReceiveResponse:)
                                     withObject: response])
    {
        [self onDidReceiveResponse: response]; 
    }
}

//----------------------------------------------------------------------------
- (void) connection: (NSURLConnection*) connection 
     didReceiveData: (NSData*) data
{
    if (! [self performSelectorOnDownloadThread: @selector(onDidReceiveData:)
                                     withObject: data])
    {
        [self onDidReceiveData: data]; 
    }
}

//----------------------------------------------------------------------------
- (void) connectionDidFinishLoading: (NSURLConnection*) connection 
{
    if (! [self performSelectorOnDownloadThread: @selector(onFinishWithError:)
                                     withObject: nil])
    { 
        [self onFinishWithError: nil]; 
    }
}

//----------------------------------------------------------------------------
- (void)  connection: (NSURLConnection*) connection 
    didFailWithError: (NSError*) error
{
    if (! [self performSelectorOnDownloadThread: @selector(onFinishWithError:)
                                     withObject: error])
    { 
        [self onFinishWithError: error]; 
    }
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
