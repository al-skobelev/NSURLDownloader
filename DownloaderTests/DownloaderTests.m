//
//  DownloaderTests.m
//  DownloaderTests
//
//  Created by Alexander Skobelev on 05/07/2012.
//  Copyright (c) 2012 IZITEQ. All rights reserved.
//

#import "DownloaderTests.h"
#import "URLConnectionOperation.h"
#import "CommonUtils.h"

@implementation DownloaderTests

- (void)setUp
{
    [super setUp];
    
    // Set-up code here.
}

- (void)tearDown
{
    // Tear-down code here.
    
    [super tearDown];
}

- (void) performBlock: (void (^)()) block
{
    if (block) block();
}

- (void) testURLConnectionOperationCreating
{
    NSConditionLock* lock = [[NSConditionLock alloc] initWithCondition: 0];

    id fm = [NSFileManager defaultManager];

    NSString* cwd = [fm currentDirectoryPath];
    NSString* filepath = STR_ADDPATH (cwd, @"notexisted.bin");
    NSURL* url = [NSURL fileURLWithPath: filepath];
    NSURLRequest* request = [NSURLRequest requestWithURL: url];
    NSString* dlpath = STR_ADDEXT (filepath, @"downloaded");

    NSLog(@"%@", cwd);
    
    URLConnectionOperation* op =
        [URLConnectionOperation
            operationWithRequest: request
                    downloadPath: dlpath
                   updateHandler: 

                ^(URLConnectionOperation* op, size_t downloaded, size_t expected)
                {
                    NSLog(@"%@: %lu / %lu", op, downloaded, expected);
                }
               completionHandler: 
                ^(URLConnectionOperation* op, NSError* err)
                {
                    [lock lock];

                    if (err) {
                        NSLog(@"%@ FAILED WITH ERROR: %@", op, [err localizedDescription]);
                    }
                    else {
                        NSLog(@"%@ SUCCESSFULLY FINISHED", op);
                    }

                    [lock unlockWithCondition: 1];
                }];

    [op start];

    while (! [lock tryLockWhenCondition: 1])
    {
        [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 1]];
    }
    [lock unlock];
    
    STAssertTrue ((-1100 == op.error.code) && [op.error.domain isEqualToString:NSURLErrorDomain], @"");
}

@end
