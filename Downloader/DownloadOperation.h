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

@property (strong, nonatomic) NSURLRequest* request;
@property (copy, nonatomic)   NSString* downloadPath;
@property (copy, nonatomic)   NSURLResponse* response;

// nil, if downloadPAth has been set
@property (readonly, nonatomic) NSMutableData* responseData;

@property (strong, nonatomic) void (^updateHandler)     (DownloadOperation* op, size_t downloaded, size_t expected);
@property (strong, nonatomic) void (^completionHandler) (DownloadOperation* op, NSError* err);

@property (strong, nonatomic) NSError* error;


+ (NSOperationQueue*) queue;

+ operationWithRequest: (NSURLRequest*) request
         updateHandler: (void (^)(DownloadOperation* op, size_t downloaded, size_t expected)) updateHandler
     completionHandler: (void (^)(DownloadOperation* op, NSError* err)) completionHandler;

+ operationWithRequest: (NSURLRequest*) request
          downloadPath: (NSString*) downloadPath
         updateHandler: (void (^)(DownloadOperation* op, size_t downloaded, size_t expected)) updateHandler
     completionHandler: (void (^)(DownloadOperation* op, NSError* err)) completionHandler;

- (void) enqueue;

@end

/* EOF */
