/****************************************************************************
 * DownloadOperation.h                                                      *
 * Created by Alexander Skobelev                                            *
 *                                                                          *
 ****************************************************************************/
#import <Foundation/Foundation.h>

#define DOWNLOAD_OPERATION_ERROR_SUBDOMAIN @""

//============================================================================
@interface DownloadOperation : NSOperation

@property (assign, atomic) BOOL isCancelled;
@property (assign, atomic) BOOL isExecuting;
@property (assign, atomic) BOOL isFinished;
@property (assign, atomic) BOOL isReady;

@property (strong, nonatomic) NSURLRequest* request;
@property (copy, nonatomic)   NSString* downloadPath;

@property (strong, nonatomic) void (^updateHandler)     (DownloadOperation* op, size_t downloaded, size_t expected);
@property (strong, nonatomic) void (^completionHandler) (DownloadOperation* op, NSError* err);

@property (strong, nonatomic) NSError* error;

+ operationForURL: (NSURL*) url
             path: (NSString*) downloadPath
    updateHandler: (void (^)(DownloadOperation* op, size_t downloaded, size_t expected)) updateHandler
completionHandelr: (void (^)(DownloadOperation* op, NSError* err)) completionHandler;

@end

/* EOF */
