#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns the reason of an Objective-C exception it throws, or nil when it throws none.
/// Swift can't catch Objective-C exceptions: one thrown inside a framework call (VideoToolbox's frame
/// processor has thrown "insertObject: object cannot be nil") would otherwise end the whole app.
NSString *_Nullable playfx_catch(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
