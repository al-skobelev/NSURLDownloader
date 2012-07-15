/****************************************************************************
 * DownloadOperation.m                                                      *
 * Created by Alexander Skobelev                                            *
 *                                                                          *
 ****************************************************************************/

#import "DownloadOperation.h"

#define DFNLOG(FMT$, ARGS$...) fprintf (stderr, "%s\n", [STRF(FMT$, ##ARGS$) UTF8String])

//============================================================================
@interface DownloadOperation ()
{
    BOOL _backgroundTaskId;
}

@property (strong, nonatomic) NSURLConnection*   connection;
@property (copy,   nonatomic) NSMutableURLRequest* currentRequest;

@property (copy, nonatomic)   NString*  partialPath;
@property (assign, nonatomic) size_t    contentLength;
@property (assign, nonatomic) size_t    downloadedLength;

@property (strong, nonatomic) NSTimer*      retryTimer;
@property (assign, nonatomic) int           retryCount;
@property (strong, nonatomic) Reachability* reachability;
@property (assign, nonatomic) NetworkStatus networkStatus;

@property (strong, nonatomic) NSMutableData* buffer;

- (void) flushFileBuffer: (BOOL) force;
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

@synthesize isCancelled = _isCancelled;
@synthesize isExecuting = _isExecuting;
@synthesize isFinished  = _isFinished;
@synthesize isReady     = _isReady;

@synthesize contentLength    = _contentLength;
@synthesize downloadedLength = _downloadedLength;

@synthesize retryTimer = _retryTimer;
@synthesize retryCount = _retryCount;

@synthesize reachability  = _reachability;
@synthesize networkStatus = _networkStatus;

@synthesize buffer = _buffer;

#define BUFFER_LIMIT 200000

//----------------------------------------------------------------------------
+ (NSString*) errorDomain
{
    STATIC (_s_domain, STRF(@"%@.%@", app_bundle_identifier(), DOWNLOAD_OPERATION_ERROR_SUBDOMAIN));
    return _s_domain;
}

// //----------------------------------------------------------------------------
// + (NSError*) errorWithCode: (int) code
//       localizedDescription: (NSString*) descr
// {
//     id info = (descr.length 
//                ? NSDICT (NSLocalizedDescriptionKey , descr)
//                : nil);
    
//     NSError* err = [NSError errorWithDomain: [self errorDomain]
//                                        code: code
//                                    userInfo: info];
//     return err;
// }

//----------------------------------------------------------------------------
+ (id) initForRequest: (NSURLRequest*) request
                 path: (NSString*) downloadPath
        updateHandler: (void (^)(DownloadOperation* op, size_t downloaded, size_t expected)) updateHandler
    completionHandelr: (void (^)(DownloadOperation* op, NSError* err)) completionHandler
{
    if (! (self = [super inint])) return nil;

    self.request   = request;
    self.currentRequest           = request;
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
    [self cancel];

    REMOVE_OBSERVER (kReachabilityChangedNotification,             self);
    REMOVE_OBSERVER (UIApplicationDidEnterBackgroundNotification,  self);
    REMOVE_OBSERVER (UIApplicationWillEnterForegroundNotification, self);
}

//----------------------------------------------------------------------------
- (BOOL) isConcurrent
{
    return YES;
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
}

//----------------------------------------------------------------------------
- (void) cancel
{
    [self stopConnection];

    self.isExecuting = NO;
    self.isFinished  = YES;
    self.isCancelled = YES;
}

//----------------------------------------------------------------------------
- (void) start
{
    if ([self startConnection])
    {
        self.isExecuting = YES;
        self.isFinished  = NO;
        self.isCancelled = NO;
    }
    else
    {
        self.isExecuting = NO;
        self.isFinished  = YES;
        self.isCancelled = NO;
    }
}

//----------------------------------------------------------------------------
- (BOOL) startConnection
{
    self.partialPath = nil;
    self.downloadedLength = 0;
    self.contentLength = 0;

    self.currentRequest = self.request;

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
                [self.currentRequest setValue: val forHTTPHeaderField: @"Range"];
            }
        }
        else {
            unlink ([self.partialPath fileSystemRepresentation]);
        }
    }

    self.connection = [NSURLConnection connectionWithRequest: self.currentRequest
                                                    delegate: delegate];
    if (self.connection) 
    {
        self.reachability = [Reachability reachabilityForLocalWiFi];
        self.networkStatus = [self.reachability currentReachabilityStatus];
        [self.reachability startNotifier];
    }
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
    Reachability* reachability = [ntf object];

    if (ReachableViaWiFi == [reachability currentReachabilityStatus])
    {
        if (self.networkStatus != ReachableViaWiFi)
        {
            [self stopConnection];
            if (! [self startConnection])
            {
                self.isExecuting = NO;
                self.isFinished = YES;
            }
        }
    }
}

//----------------------------------------------------------------------------
- (void) onEnterBackgroundNtf: (NSNotification*) ntf
{
    if (self.isExecuting) {
        [self startBackgroundTask];
    }
}

//----------------------------------------------------------------------------
- (void) onExitBackgroundNtf: (NSNotification*) ntf
{
    [self stopBackgroundTask];
}


//----------------------------------------------------------------------------
- (void) onRetryConnectionTimer: (NSTimer*) timer
{
    if (! [self startConnection])
    {
        self.isExecuting = NO;
        self.isFinished = YES;
    }
}


//----------------------------------------------------------------------------
- (void) connection: (NSURLConnection*) connection
 didReceiveResponse: (NSURLResponse*) response
{
    int http_status = [(NSHTTPURLResponse*)response statusCode];

    if (http_status >= 300)
    {
        self.error = 
            [NSError errorWithDomain: [self errorDomain]
                                code: DOWNLOAD_OPERATION_ERROR_CODE_HTTP_ERROR
                            userInfo: NSDICT (NSLocalizedDescriptionKey, STRLF (@"Server returned error: %d", http_status))];

        self.isExecuting = NO;
        self.isFinished = YES;

        if (self.completionHandler) self.completionHandler (self, err);
    }


    DFNLOG(@"CONNECTION %p GOT RESPONSE %d HEADERS: %@", connection, http_status, [(NSHTTPURLResponse*)response allHeaderFields]);
    DFNLOG(@"-- INITIAL REQUEST WAS: %@ (%@)", self.request, [self.request allHTTPHeaderFields]);

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
- (void) connection: (NSURLConnection*) connection 
     didReceiveData: (NSData*) data
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
    
        if (self.updateHandler) self.updateHandler (self, self.downloadedLength, self.contentLength);
    }
}

//----------------------------------------------------------------------------
- (void) connection: (NSURLConnection*) connection 
 didFinishWithError: (NSError*) err
{

    DFNLOG (@"Connection %p FINISHED: %@\nERROR: %@\n", connection, self.request.URL, err);

    [self stopConnection];
    self.error = err;

    if (err)
    {
        static NSTimeInterval _s_interval[] = { 1.0, 2.0, 3.0 };
                
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
            }
        }
    }

    if (! self.retryTimer) 
    {
        self.isExecuting = NO;
        self.isFinished = YES;

        if (self.completionHandler) self.completionHandler (self, self.error);
    }
}

//----------------------------------------------------------------------------
- (void) connectionDidFinishLoading: (NSURLConnection*) connection 
{
    [self connection: connection didFinishWithError: nil];
}

//----------------------------------------------------------------------------
- (void)  connection: (NSURLConnection*) connection 
    didFailWithError: (NSError*) error
{
    [self connection: connection didFinishWithError: error];
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
