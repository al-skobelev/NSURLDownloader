/****************************************************************************
 * URLConnectionOperation.h                                                 *
 * Created by Alexander Skobelev                                            *
 *                                                                          *
 ****************************************************************************/
#import <Foundation/Foundation.h>

enum {
    DOWNLOAD_OPERATION_ERROR_CODE_NONE,
    DOWNLOAD_OPERATION_ERROR_CODE_HTTP_ERROR,
};

//============================================================================
@interface URLConnectionOperation : NSOperation

@property (strong, nonatomic) NSURLRequest*  request;
@property (copy, nonatomic)   NSString*      downloadPath;
@property (copy, nonatomic)   NSURLResponse* response;

@property (readonly, nonatomic) NSMutableData* responseData;

@property (strong, nonatomic) void (^updateHandler)     (URLConnectionOperation* op, size_t downloaded, size_t expected);
@property (strong, nonatomic) void (^completionHandler) (URLConnectionOperation* op, NSError* err);

@property (strong, nonatomic) NSError* error;

+ (NSString*) errorDomain;

+ operationWithRequest: (NSURLRequest*) request
         updateHandler: (void (^)(URLConnectionOperation* op, size_t downloaded, size_t expected)) updateHandler
     completionHandler: (void (^)(URLConnectionOperation* op, NSError* err)) completionHandler;

+ operationWithRequest: (NSURLRequest*) request
          downloadPath: (NSString*) downloadPath
         updateHandler: (void (^)(URLConnectionOperation* op, size_t downloaded, size_t expected)) updateHandler
     completionHandler: (void (^)(URLConnectionOperation* op, NSError* err)) completionHandler;

@end

/* EOF */
