/**************************************************************************** 
 * AppDelegate.h                                                            * 
 * Created by Alexander Skobelev                                            * 
 *                                                                          * 
 ****************************************************************************/
#import <UIKit/UIKit.h>

#define APPD ((AppDelegate*)[UIApplication sharedApplication].delegate)
@class URLConnectionOperation;
//============================================================================
@interface AppDelegate : UIResponder <UIApplicationDelegate>

@property (strong, nonatomic) UIWindow*          window;
@property (readonly)          NSURL*             fileURL;
@property (readonly)          NSString*          downloadPath;

@property (strong, nonatomic) URLConnectionOperation* downloadOperation;
@property (strong, nonatomic) NSOperationQueue*       downloadQueue;

- (BOOL) startDownload: (NSString*) file
     completionHandler: (void (^)(NSError* err)) completionHandler
         updateHandler: (void (^)(size_t downloaded, size_t expected)) updateHandler;

- (void) stopDownload;
- (void) resetDownload;

@end

/* EOF */
