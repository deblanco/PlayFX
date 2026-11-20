#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns the reason of an Objective-C exception it throws, or nil when it throws none.
/// Swift can't catch Objective-C exceptions: one thrown inside a framework call (VideoToolbox's frame
/// processor has thrown "insertObject: object cannot be nil") would otherwise end the whole app.
NSString *_Nullable playfx_catch(NS_NOESCAPE void (^block)(void));

/// -[VTFrameProcessor processWithParameters:error:]: VideoToolbox's synchronous call, which returns once the
/// outputs are written. Swift doesn't see it (it offers asynchronous forms that return before the work is done,
/// and the Metal command-buffer one, which leaks a Metal shared event per call). NO with `error` set when the
/// processor fails; NO with no error before macOS 26. Objective-C exceptions pass through: call it in playfx_catch.
BOOL playfx_vt_process(id processor, id parameters, NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
