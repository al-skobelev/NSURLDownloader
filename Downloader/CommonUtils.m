#import "CommonUtils.h"
#include <mach/mach_time.h>
#include <CommonCrypto/CommonDigest.h>

//----------------------------------------------------------------------------
id info_for_key (NSString* key)
{
    return info_for_key_in_bundle (key, [NSBundle mainBundle]);
}

//----------------------------------------------------------------------------
id info_for_key_in_bundle (NSString* key, NSBundle* bundle)
{
    id val = [[bundle localizedInfoDictionary] 
                 objectForKey: key];

    if (! val) {
        val = [[bundle infoDictionary] 
                 objectForKey: key];
    }

    return val;
}


//----------------------------------------------------------------------------
NSString* app_name()
{
    STATIC_RETAIN (_s_name, info_for_key (@"CFBundleName"));
    return _s_name;
}

//----------------------------------------------------------------------------
NSString* app_bundle_identifier ()
{
    STATIC_RETAIN (_s_name, info_for_key (@"CFBundleIdentifier"));
    return _s_name;
}

//----------------------------------------------------------------------------
NSString* user_app_support_path()
{
    STATIC_RETAIN (_s_path, 
                   [(NSSearchPathForDirectoriesInDomains (NSApplicationSupportDirectory,
                                                          NSUserDomainMask,
                                                          YES)) 
                       objectAtIndex: 0]);
    return _s_path;
}

//----------------------------------------------------------------------------
NSString* user_documents_path()
{
    STATIC_RETAIN (_s_path, 
                   [(NSSearchPathForDirectoriesInDomains (NSDocumentDirectory,
                                                          NSUserDomainMask,
                                                          YES)) 
                       objectAtIndex: 0]);
    return _s_path;
}

//----------------------------------------------------------------------------
uint64_t host_time_to_us (uint64_t htime)
{
    static double _s_base = 0;
    if (! _s_base) {
        mach_timebase_info_data_t tinfo;
        mach_timebase_info (&tinfo);

        _s_base = ((double) tinfo.numer) / (1e3 * tinfo.denom);
    }
    htime *= _s_base;
    return htime;
}

//----------------------------------------------------------------------------
uint64_t host_time_us ()
{
	uint64_t ht = mach_absolute_time();
    ht = host_time_to_us (ht);
    return ht;
}

//----------------------------------------------------------------------------
NSString* md5_for_path (NSString* path)
{
    CC_MD5_CTX ctx;
    NSMutableString* md5str = nil;

    //uint64_t tm1 = host_time_us();

    CC_MD5_Init (&ctx);

    const size_t BUF_SIZE = 0x10000;
    char buf [BUF_SIZE];
    FILE* file = fopen ([path fileSystemRepresentation], "r");
    if (file)
    {
        size_t nbytes;
        while (0 < (nbytes = fread (buf, 1, BUF_SIZE, file)))
        {
            CC_MD5_Update (&ctx, buf, nbytes);
        }
        fclose (file);
        
        unsigned char md5 [CC_MD5_DIGEST_LENGTH];
        CC_MD5_Final (md5, &ctx);
        
        md5str = [NSMutableString stringWithCapacity: (2 * CC_MD5_DIGEST_LENGTH)];
        for (int i = 0; i < CC_MD5_DIGEST_LENGTH; ++i)
        {
            [md5str appendFormat: @"%02x", md5[i]];
        }
    }

    //uint64_t tm2 = host_time_us();
    //DFNLOG(@"%s -- %lf", __FUNCTION__, (double)(tm2 - tm1) / 1e6);

QUIT:
    if (file) fclose (file);
    return md5str;
}

//----------------------------------------------------------------------------
NSMutableDictionary* makedict (id firstKey, ...)
{
    id dict = [NSMutableDictionary dictionary];
    if (firstKey)
    {
        va_list vl;
        va_start (vl, firstKey);

        id val;
        id key = firstKey;
        
        while(key && (val = va_arg(vl, id)))
        {
            [dict setObject: val forKey: key];
            key = va_arg(vl, id);
        }

        va_end (vl);
    }
    return dict;
}
