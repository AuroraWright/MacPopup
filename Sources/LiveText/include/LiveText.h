#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One recognized piece of text. `box` is normalized to the image (0–1) with the origin at the top left.
@interface MPLiveTextItem : NSObject
@property (nonatomic, readonly, copy) NSString *text;
@property (nonatomic, readonly) CGRect box;
/// The words of a line (for Japanese, usually single characters). Empty for words themselves.
@property (nonatomic, readonly, copy) NSArray<MPLiveTextItem *> *words;
@end

/// Text recognition with Apple's Live Text (VisionKit's image analyzer), the same engine as Live Text
/// in Preview and Photos. It isn't public API for this use, so availability is checked at runtime.
@interface MPLiveText : NSObject
+ (BOOL)isAvailable;
/// Calls `completion` on the main queue with the recognized lines in reading order.
+ (void)recognizeImage:(CGImageRef)image
               locales:(NSArray<NSString *> *)locales
            completion:(void (^)(NSArray<MPLiveTextItem *> *_Nullable lines, NSError *_Nullable error))completion;
@end

NS_ASSUME_NONNULL_END
