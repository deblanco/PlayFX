#import "ObjCCatch.h"

NSString *_Nullable playfx_catch(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception.reason ?: exception.name;
    }
}
