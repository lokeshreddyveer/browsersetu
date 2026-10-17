// Objective-C surface over the Chromium Embedded Framework (Blink). Swift talks only to this header.
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, BSNavDecision) {
    BSNavAllow = 0,
    BSNavExternal = 1,
    BSNavDeny = 2,
};

/// NSApplication subclass required by CEF (tracks -sendEvent: re-entrancy). Set as NSPrincipalClass.
@interface BSApplication : NSApplication
@end

@protocol BSCefBrowserDelegate <NSObject>
- (void)cefTitleChanged:(NSString *)title;
- (void)cefAddressChanged:(NSString *)url;
- (void)cefLoadingChanged:(BOOL)loading canGoBack:(BOOL)back canGoForward:(BOOL)forward;
- (void)cefProgress:(double)progress;
- (void)cefLoadFinished;
- (void)cefLoadFailedURL:(NSString *)url description:(NSString *)text;
- (void)cefProcessCrashed;
/// Called synchronously on the main thread before a navigation starts.
- (BSNavDecision)cefDecideNavigation:(NSString *)url mainFrame:(BOOL)mainFrame;
- (void)cefOpenNewTab:(NSString *)url userGesture:(BOOL)gesture;
- (void)cefRequestPermissionOrigin:(NSString *)origin camera:(BOOL)camera microphone:(BOOL)microphone
                             reply:(void (^)(BOOL granted))reply;
/// type: 0 alert, 1 confirm, 2 prompt.
- (void)cefRequestDialogType:(NSInteger)type origin:(NSString *)origin message:(NSString *)message
                 defaultText:(NSString *)defaultText reply:(void (^)(BOOL ok, NSString *text))reply;
- (void)cefRequestClose;
@end

@protocol BSCefDownloadDelegate <NSObject>
/// Returns the destination path, or nil to refuse the download.
- (nullable NSString *)cefBeginDownloadId:(uint32_t)downloadId suggestedName:(NSString *)name url:(NSString *)url;
- (void)cefDownloadId:(uint32_t)downloadId progress:(double)fraction;
- (void)cefDownloadFinishedId:(uint32_t)downloadId url:(NSString *)url;
- (void)cefDownloadFailedId:(uint32_t)downloadId;
@end

@interface BSCefRuntime : NSObject
/// Loads the framework and starts CEF. Call once, on the main thread, before creating browsers.
+ (BOOL)initializeWithRootCachePath:(NSString *)root mockKeychain:(BOOL)mockKeychain;
+ (BOOL)isReady;
+ (void)shutdown;
@property (class, nonatomic, weak, nullable) id<BSCefDownloadDelegate> downloadDelegate;
/// Hosts whose requests (and subdomains) are cancelled. An empty list disables blocking.
+ (void)setBlockedHosts:(NSArray<NSString *> *)hosts;
+ (void)cancelDownload:(uint32_t)downloadId;
+ (void)collectCookiesForCachePath:(nullable NSString *)cachePath
                        completion:(void (^)(NSArray<NSDictionary<NSString *, NSString *> *> *cookies))completion;
+ (void)clearDataForCachePath:(nullable NSString *)cachePath completion:(void (^)(void))completion;
/// Drops the in-memory private context so the next private browser starts empty.
+ (void)endPrivateSession;
/// Releases a profile's persistent context (call before deleting its files).
+ (void)releaseContextForCachePath:(NSString *)cachePath;
@end

@interface BSCefBrowser : NSObject
/// `cachePath == nil` creates a private (in-memory) browser.
- (instancetype)initWithCachePath:(nullable NSString *)cachePath delegate:(id<BSCefBrowserDelegate>)delegate;
@property (nonatomic, readonly) NSView *view;
@property (nonatomic, readonly, nullable) NSString *currentURL;
@property (nonatomic) double zoomFactor;
- (void)loadURL:(NSString *)url;
- (void)reload;
- (void)stop;
- (void)goBack;
- (void)goForward;
- (void)focus;
- (void)loadErrorHTML:(NSString *)html baseURL:(nullable NSString *)baseURL;
- (void)close;
@end

NS_ASSUME_NONNULL_END
