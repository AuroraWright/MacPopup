#import "LiveText.h"
#import <TargetConditionals.h>
#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#else
#import <dlfcn.h>
#endif

// VisionKitCore's analyzer, as used by owocr's Apple Live Text engine.
@interface NSObject (MPVisionKitCore)
#if TARGET_OS_OSX
- (instancetype)initWithImage:(NSImage *)image requestType:(NSInteger)requestType;
#else
// iOS has no NSImage: the request takes the CGImage (orientation 0, up).
- (instancetype)initWithCGImage:(CGImageRef)image orientation:(NSInteger)orientation requestType:(NSUInteger)requestType;
#endif
- (void)setLocales:(NSArray<NSString *> *)locales;
- (void)processRequest:(id)request
       progressHandler:(void (^)(double progress))progressHandler
     completionHandler:(void (^)(id analysis, NSError *error))completionHandler;
- (NSArray *)allLines;
- (NSArray *)children;
- (NSString *)string;
- (id)quad;
- (CGRect)boundingBox;
@end

static const NSInteger MPAnalysisTypeText = 1;

@implementation MPLiveTextItem

- (instancetype)initWithText:(NSString *)text box:(CGRect)box words:(NSArray<MPLiveTextItem *> *)words {
    if ((self = [super init])) {
        _text = [text copy];
        _box = box;
        _words = [words copy];
    }
    return self;
}

@end

@implementation MPLiveText

+ (BOOL)isAvailable {
#if !TARGET_OS_OSX
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/VisionKitCore.framework/VisionKitCore", RTLD_NOW);
    });
#endif
    return NSClassFromString(@"VKCImageAnalyzer") != nil && NSClassFromString(@"VKCImageAnalyzerRequest") != nil;
}

+ (id)analyzer {
    static id analyzer;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        analyzer = [[NSClassFromString(@"VKCImageAnalyzer") alloc] init];
    });
    return analyzer;
}

+ (MPLiveTextItem *)itemFromObject:(id)object includeWords:(BOOL)includeWords {
    NSMutableArray<MPLiveTextItem *> *words = [NSMutableArray array];
    if (includeWords && [object respondsToSelector:@selector(children)]) {
        for (id child in [object children]) {
            [words addObject:[self itemFromObject:child includeWords:NO]];
        }
    }
    CGRect box = [object respondsToSelector:@selector(quad)] ? [[object quad] boundingBox] : CGRectZero;
    return [[MPLiveTextItem alloc] initWithText:[object string] ?: @"" box:box words:words];
}

+ (void)recognizeImage:(CGImageRef)image
               locales:(NSArray<NSString *> *)locales
            completion:(void (^)(NSArray<MPLiveTextItem *> *, NSError *))completion {
    if (![self isAvailable]) {
#if TARGET_OS_OSX
        NSString *message = @"Live Text isn't available on this Mac.";
#else
        NSString *message = @"Live Text isn't available on this device.";
#endif
        completion(nil, [NSError errorWithDomain:@"MacPopup" code:1 userInfo:@{NSLocalizedDescriptionKey: message}]);
        return;
    }
#if TARGET_OS_OSX
    NSImage *nsImage = [[NSImage alloc] initWithCGImage:image size:NSMakeSize(CGImageGetWidth(image), CGImageGetHeight(image))];
    id request = [[NSClassFromString(@"VKCImageAnalyzerRequest") alloc] initWithImage:nsImage requestType:MPAnalysisTypeText];
#else
    id request = [[NSClassFromString(@"VKCImageAnalyzerRequest") alloc] initWithCGImage:image orientation:0 requestType:MPAnalysisTypeText];
#endif
    [request setLocales:locales];
    [[self analyzer] processRequest:request
                    progressHandler:^(double progress) {}
                  completionHandler:^(id analysis, NSError *error) {
                      NSMutableArray<MPLiveTextItem *> *lines = nil;
                      if (analysis) {
                          lines = [NSMutableArray array];
                          for (id line in [analysis allLines]) {
                              [lines addObject:[self itemFromObject:line includeWords:YES]];
                          }
                      }
                      dispatch_async(dispatch_get_main_queue(), ^{
                          completion(lines, lines ? nil : error);
                      });
                  }];
}

@end
