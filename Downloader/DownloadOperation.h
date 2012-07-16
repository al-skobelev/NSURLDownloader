/****************************************************************************
 * DownloadOperation.h                                                      *
 * Created by Alexander Skobelev                                            *
 *                                                                          *
 ****************************************************************************/
#import <Foundation/Foundation.h>

#define DOWNLOAD_OPERATION_ERROR_SUBDOMAIN @"DownloadOperation"

enum {
    DOWNLOAD_OPERATION_ERROR_CODE_NONE,
    DOWNLOAD_OPERATION_ERROR_CODE_HTTP_ERROR,
};

//============================================================================
@interface DownloadOperation : NSOperation

@property (readonly) BOOL isConcurrent;
@property (readonly) BOOL isCancelled;
@property (readonly) BOOL isExecuting;
@property (readonly) BOOL isFinished;


@property (strong, nonatomic) NSURLRequest* request;
@property (copy, nonatomic)   NSString* downloadPath;

@property (strong, nonatomic) void (^updateHandler)     (DownloadOperation* op, size_t downloaded, size_t expected);
@property (strong, nonatomic) void (^completionHandler) (DownloadOperation* op, NSError* err);

@property (strong, nonatomic) NSError* error;


+ (NSOperationQueue*) downloadQueue;

+ operationWithRequest: (NSURLRequest*) request
          downloadPath: (NSString*) downloadPath
         updateHandler: (void (^)(DownloadOperation* op, size_t downloaded, size_t expected)) updateHandler
     completionHandler: (void (^)(DownloadOperation* op, NSError* err)) completionHandler;

- (void) enqueue;

@end

/* EOF */
