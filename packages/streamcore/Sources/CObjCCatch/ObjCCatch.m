#import "ObjCCatch.h"
#import <VideoToolbox/VideoToolbox.h>

NSString *_Nullable playfx_catch(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception.reason ?: exception.name;
    }
}

BOOL playfx_vt_process(id processor, id parameters, NSError **error) {
    if (@available(macOS 26.0, iOS 26.0, *)) {
        return [(VTFrameProcessor *)processor processWithParameters:(id<VTFrameProcessorParameters>)parameters error:error];
    }
    return NO;
}
