#import "BSCef.h"

#include <crt_externs.h>
#include <algorithm>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_command_line.h"
#include "include/cef_cookie.h"
#include "include/cef_request_context.h"
#include "include/cef_request_context_handler.h"
#include "include/cef_resource_request_handler.h"
#include "include/wrapper/cef_library_loader.h"

// MARK: - NSApplication

@implementation BSApplication {
    BOOL _handlingSendEvent;
}
- (BOOL)isHandlingSendEvent { return _handlingSendEvent; }
- (void)setHandlingSendEvent:(BOOL)handlingSendEvent { _handlingSendEvent = handlingSendEvent; }
- (void)sendEvent:(NSEvent *)event {
    CefScopedSendingEvent scoped;
    [super sendEvent:event];
}
@end

// MARK: - Shared state

namespace {

bool g_ready = false;
bool g_started = false;
bool g_in_pump = false;
CefScopedLibraryLoader* g_loader = nullptr;
NSTimer* g_heartbeat = nil;

std::mutex g_blocked_mutex;
std::shared_ptr<const std::vector<std::string>> g_blocked;

std::map<std::string, CefRefPtr<CefRequestContext>> g_contexts;
CefRefPtr<CefRequestContext> g_private_context;
std::vector<CefRefPtr<CefBrowser>> g_browsers;
std::map<uint32_t, CefRefPtr<CefDownloadItemCallback>> g_download_callbacks;
__weak id<BSCefDownloadDelegate> g_download_delegate = nil;

std::string ToStd(NSString* s) { return s ? std::string(s.UTF8String) : std::string(); }
NSString* ToNS(const CefString& s) { return [NSString stringWithUTF8String:s.ToString().c_str()]; }

bool IsBlockedHost(const std::string& host_in) {
    std::shared_ptr<const std::vector<std::string>> list;
    {
        std::lock_guard<std::mutex> lock(g_blocked_mutex);
        list = g_blocked;
    }
    if (!list || list->empty()) return false;
    std::string host = host_in;
    std::transform(host.begin(), host.end(), host.begin(), ::tolower);
    for (const auto& h : *list) {
        if (host == h) return true;
        if (host.size() > h.size() && host.compare(host.size() - h.size(), h.size(), h) == 0 &&
            host[host.size() - h.size() - 1] == '.') {
            return true;
        }
    }
    return false;
}

void Pump() {
    if (g_in_pump) return;
    g_in_pump = true;
    CefDoMessageLoopWork();
    g_in_pump = false;
}

void SchedulePump(int64_t delay_ms) {
    int64_t delay = std::max<int64_t>(0, std::min<int64_t>(delay_ms, 33));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        Pump();
    });
}

// Blocks tracker hosts. Runs on the IO thread, so it only reads the immutable host snapshot.
class BSResourceHandler : public CefResourceRequestHandler {
public:
    ReturnValue OnBeforeResourceLoad(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefRequest> request,
                                     CefRefPtr<CefCallback>) override {
        CefURLParts parts;
        if (CefParseURL(request->GetURL(), parts)) {
            if (IsBlockedHost(CefString(&parts.host).ToString())) return RV_CANCEL;
        }
        return RV_CONTINUE;
    }
    IMPLEMENT_REFCOUNTING(BSResourceHandler);
};

class BSContextHandler : public CefRequestContextHandler {
public:
    CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>,
                                                                   CefRefPtr<CefRequest>, bool, bool,
                                                                   const CefString&, bool&) override {
        return handler_;
    }
private:
    CefRefPtr<BSResourceHandler> handler_ = new BSResourceHandler();
    IMPLEMENT_REFCOUNTING(BSContextHandler);
};

CefRefPtr<CefRequestContext> ContextForPath(NSString* path) {
    if (path == nil) {
        if (!g_private_context) {
            CefRequestContextSettings s;  // empty cache_path = in-memory
            g_private_context = CefRequestContext::CreateContext(s, new BSContextHandler());
        }
        return g_private_context;
    }
    std::string key = ToStd(path);
    auto it = g_contexts.find(key);
    if (it != g_contexts.end()) return it->second;
    CefRequestContextSettings s;
    CefString(&s.cache_path) = key;
    s.persist_session_cookies = false;
    CefRefPtr<CefRequestContext> ctx = CefRequestContext::CreateContext(s, new BSContextHandler());
    g_contexts[key] = ctx;
    return ctx;
}

// MARK: - App

class BSApp : public CefApp, public CefBrowserProcessHandler {
public:
    explicit BSApp(bool mock_keychain) : mock_keychain_(mock_keychain) {}
    void OnBeforeCommandLineProcessing(const CefString&, CefRefPtr<CefCommandLine> cl) override {
        // Test builds avoid the Keychain prompt for cookie encryption; release builds use the real Keychain.
        if (mock_keychain_) cl->AppendSwitch("use-mock-keychain");
    }
    CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
    void OnContextInitialized() override { g_ready = true; }
    void OnScheduleMessagePumpWork(int64_t delay_ms) override { SchedulePump(delay_ms); }
private:
    bool mock_keychain_;
    IMPLEMENT_REFCOUNTING(BSApp);
};

CefRefPtr<BSApp> g_app;

// MARK: - Cookies

class BSCookieCollector : public CefCookieVisitor {
public:
    explicit BSCookieCollector(void (^done)(NSArray*)) : done_([done copy]) {}
    bool Visit(const CefCookie& c, int count, int total, bool& deleteCookie) override {
        deleteCookie = false;
        [items_ addObject:@{@"name": ToNS(CefString(&c.name)), @"value": ToNS(CefString(&c.value)),
                            @"domain": ToNS(CefString(&c.domain))}];
        if (count + 1 >= total) Finish();
        return true;
    }
    void Finish() {
        if (finished_) return;
        finished_ = true;
        auto done = done_;
        NSArray* items = [items_ copy];
        dispatch_async(dispatch_get_main_queue(), ^{ done(items); });
    }
private:
    NSMutableArray* items_ = [NSMutableArray array];
    void (^done_)(NSArray*);
    bool finished_ = false;
    IMPLEMENT_REFCOUNTING(BSCookieCollector);
};

class BSDeleteCallback : public CefDeleteCookiesCallback {
public:
    explicit BSDeleteCallback(void (^done)(void)) : done_([done copy]) {}
    void OnComplete(int) override { auto d = done_; dispatch_async(dispatch_get_main_queue(), ^{ d(); }); }
private:
    void (^done_)(void);
    IMPLEMENT_REFCOUNTING(BSDeleteCallback);
};

}  // namespace

// MARK: - Client (per browser)

@class BSCefBrowser;

namespace {

class BSClient : public CefClient,
                 public CefLifeSpanHandler,
                 public CefDisplayHandler,
                 public CefLoadHandler,
                 public CefRequestHandler,
                 public CefDownloadHandler,
                 public CefJSDialogHandler,
                 public CefPermissionHandler {
public:
    explicit BSClient(id<BSCefBrowserDelegate> delegate) : delegate_(delegate) {}

    void set_error_display_url(NSString* url) { error_display_url_ = url; pending_internal_ = true; }
    CefRefPtr<CefBrowser> browser() { return browser_; }

    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
    CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
    CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
    CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
    CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
    CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }

    // Life span
    void OnAfterCreated(CefRefPtr<CefBrowser> b) override { browser_ = b; g_browsers.push_back(b); }
    void OnBeforeClose(CefRefPtr<CefBrowser> b) override {
        g_browsers.erase(std::remove_if(g_browsers.begin(), g_browsers.end(),
                                        [&](const CefRefPtr<CefBrowser>& x) { return x->IsSame(b); }),
                         g_browsers.end());
        browser_ = nullptr;
    }
    bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int, const CefString& target_url,
                       const CefString&, WindowOpenDisposition, bool user_gesture, const CefPopupFeatures&,
                       CefWindowInfo&, CefRefPtr<CefClient>&, CefBrowserSettings&,
                       CefRefPtr<CefDictionaryValue>&, bool*) override {
        [delegate_ cefOpenNewTab:ToNS(target_url) userGesture:user_gesture];
        return true;  // never create a native popup window
    }

    // Display
    void OnTitleChange(CefRefPtr<CefBrowser>, const CefString& title) override {
        [delegate_ cefTitleChanged:ToNS(title)];
    }
    void OnAddressChange(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, const CefString& url) override {
        if (!frame->IsMain()) return;
        NSString* u = ToNS(url);
        if ([u hasPrefix:@"data:"] && error_display_url_ != nil) {
            u = error_display_url_;  // show the failed address, not the internal error page
        } else if (![u hasPrefix:@"data:"]) {
            error_display_url_ = nil;
        }
        [delegate_ cefAddressChanged:u];
    }
    void OnLoadingProgressChange(CefRefPtr<CefBrowser>, double progress) override {
        [delegate_ cefProgress:progress];
    }

    // Load
    void OnLoadingStateChange(CefRefPtr<CefBrowser>, bool loading, bool back, bool forward) override {
        [delegate_ cefLoadingChanged:loading canGoBack:back canGoForward:forward];
    }
    void OnLoadEnd(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, int) override {
        if (frame->IsMain()) [delegate_ cefLoadFinished];
    }
    void OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, ErrorCode code, const CefString& text,
                     const CefString& failed_url) override {
        if (!frame->IsMain() || code == ERR_ABORTED) return;
        [delegate_ cefLoadFailedURL:ToNS(failed_url) description:ToNS(text)];
    }

    // Request: navigation policy is decided by the Rust core via the delegate.
    bool OnBeforeBrowse(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request, bool,
                        bool) override {
        NSString* url = ToNS(request->GetURL());
        if (pending_internal_ && [url hasPrefix:@"data:text/html"]) {
            pending_internal_ = false;  // our own error page: the only data: load we allow
            return false;
        }
        BSNavDecision d = [delegate_ cefDecideNavigation:url mainFrame:frame->IsMain()];
        return d != BSNavAllow;
    }
    // Chromium's default (cancel) is kept for certificate errors: there is deliberately no bypass.
    void OnRenderProcessTerminated(CefRefPtr<CefBrowser>, TerminationStatus status, int,
                                   const CefString&) override {
        [delegate_ cefProcessCrashed];
    }

    // Downloads
    bool OnBeforeDownload(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem> item, const CefString& name,
                          CefRefPtr<CefBeforeDownloadCallback> callback) override {
        id<BSCefDownloadDelegate> d = g_download_delegate;
        NSString* dest = d ? [d cefBeginDownloadId:item->GetId() suggestedName:ToNS(name) url:ToNS(item->GetURL())] : nil;
        if (dest == nil) return false;
        callback->Continue(ToStd(dest), false);
        return true;
    }
    void OnDownloadUpdated(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem> item,
                           CefRefPtr<CefDownloadItemCallback> callback) override {
        id<BSCefDownloadDelegate> d = g_download_delegate;
        uint32_t id_ = item->GetId();
        if (item->IsComplete()) {
            g_download_callbacks.erase(id_);
            [d cefDownloadFinishedId:id_ url:ToNS(item->GetURL())];
        } else if (item->IsCanceled() || !item->IsValid()) {
            g_download_callbacks.erase(id_);
            [d cefDownloadFailedId:id_];
        } else {
            g_download_callbacks[id_] = callback;
            int pct = item->GetPercentComplete();
            if (pct >= 0) [d cefDownloadId:id_ progress:pct / 100.0];
        }
    }

    // JS dialogs
    bool OnJSDialog(CefRefPtr<CefBrowser>, const CefString& origin, JSDialogType type, const CefString& message,
                    const CefString& default_text, CefRefPtr<CefJSDialogCallback> callback, bool&) override {
        NSInteger t = type == JSDIALOGTYPE_ALERT ? 0 : (type == JSDIALOGTYPE_CONFIRM ? 1 : 2);
        [delegate_ cefRequestDialogType:t origin:ToNS(origin) message:ToNS(message) defaultText:ToNS(default_text)
                                  reply:^(BOOL ok, NSString* text) { callback->Continue(ok, ToStd(text)); }];
        return true;
    }

    // Permissions
    bool OnRequestMediaAccessPermission(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, const CefString& origin,
                                        uint32_t requested, CefRefPtr<CefMediaAccessCallback> callback) override {
        const uint32_t desktop = CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE | CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE;
        BOOL cam = (requested & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE) != 0;
        BOOL mic = (requested & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE) != 0;
        if ((requested & desktop) != 0 || (!cam && !mic)) {  // screen capture is never granted
            callback->Cancel();
            return true;
        }
        uint32_t granted = requested & (CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE | CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE);
        [delegate_ cefRequestPermissionOrigin:ToNS(origin) camera:cam microphone:mic
                                        reply:^(BOOL ok) { if (ok) callback->Continue(granted); else callback->Cancel(); }];
        return true;
    }
    bool OnShowPermissionPrompt(CefRefPtr<CefBrowser>, uint64_t, const CefString&, uint32_t,
                                CefRefPtr<CefPermissionPromptCallback> callback) override {
        callback->Continue(CEF_PERMISSION_RESULT_DENY);  // location, notifications etc. are not offered yet
        return true;
    }

private:
    __weak id<BSCefBrowserDelegate> delegate_;
    CefRefPtr<CefBrowser> browser_;
    NSString* error_display_url_ = nil;
    bool pending_internal_ = false;
    IMPLEMENT_REFCOUNTING(BSClient);
};

}  // namespace

// MARK: - Runtime

@implementation BSCefRuntime

+ (BOOL)initializeWithRootCachePath:(NSString *)root mockKeychain:(BOOL)mockKeychain {
    if (g_started) return YES;
    g_loader = new CefScopedLibraryLoader();
    if (!g_loader->LoadInMain()) return NO;
    CefMainArgs args(*_NSGetArgc(), *_NSGetArgv());
    CefSettings settings;
    settings.external_message_pump = true;
    settings.log_severity = LOGSEVERITY_WARNING;
    CefString(&settings.root_cache_path) = ToStd(root);
    g_app = new BSApp(mockKeychain);
    if (!CefInitialize(args, settings, g_app, nullptr)) return NO;
    g_started = true;
    g_heartbeat = [NSTimer timerWithTimeInterval:1.0 / 30 repeats:YES block:^(NSTimer*) { Pump(); }];
    [[NSRunLoop mainRunLoop] addTimer:g_heartbeat forMode:NSRunLoopCommonModes];
    return YES;
}

+ (BOOL)isReady { return g_ready; }

+ (void)shutdown {
    if (!g_started) return;
    for (auto b : std::vector<CefRefPtr<CefBrowser>>(g_browsers)) b->GetHost()->CloseBrowser(true);
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:3];
    while (!g_browsers.empty() && [deadline timeIntervalSinceNow] > 0) {
        Pump();
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    [g_heartbeat invalidate];
    g_heartbeat = nil;
    g_contexts.clear();
    g_private_context = nullptr;
    CefShutdown();
    g_started = false;
    g_ready = false;
}

static id<BSCefDownloadDelegate> _dl;
+ (id<BSCefDownloadDelegate>)downloadDelegate { return g_download_delegate; }
+ (void)setDownloadDelegate:(id<BSCefDownloadDelegate>)d { g_download_delegate = d; }

+ (void)setBlockedHosts:(NSArray<NSString *> *)hosts {
    auto list = std::make_shared<std::vector<std::string>>();
    for (NSString* h in hosts) {
        std::string s = ToStd(h);
        std::transform(s.begin(), s.end(), s.begin(), ::tolower);
        if (!s.empty()) list->push_back(s);
    }
    std::lock_guard<std::mutex> lock(g_blocked_mutex);
    g_blocked = list;
}

+ (void)cancelDownload:(uint32_t)downloadId {
    auto it = g_download_callbacks.find(downloadId);
    if (it != g_download_callbacks.end()) it->second->Cancel();
}

+ (void)collectCookiesForCachePath:(NSString *)cachePath
                        completion:(void (^)(NSArray<NSDictionary<NSString *, NSString *> *> *))completion {
    CefRefPtr<CefCookieManager> cm = ContextForPath(cachePath)->GetCookieManager(nullptr);
    CefRefPtr<BSCookieCollector> collector = new BSCookieCollector(completion);
    cm->VisitAllCookies(collector);
    // The visitor is never called when there are no cookies, so also finish after a short grace period.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        collector->Finish();
    });
}

+ (void)clearDataForCachePath:(NSString *)cachePath completion:(void (^)(void))completion {
    CefRefPtr<CefRequestContext> ctx = ContextForPath(cachePath);
    ctx->GetCookieManager(nullptr)->DeleteCookies("", "", new BSDeleteCallback(completion));
    ctx->ClearHttpCache(nullptr);
}

+ (void)endPrivateSession { g_private_context = nullptr; }

+ (void)releaseContextForCachePath:(NSString *)cachePath {
    g_contexts.erase(ToStd(cachePath));
}

@end

// MARK: - Browser

@implementation BSCefBrowser {
    NSView* _view;
    CefRefPtr<BSClient> _client;
    double _zoom;
}

- (instancetype)initWithCachePath:(NSString *)cachePath delegate:(id<BSCefBrowserDelegate>)delegate {
    self = [super init];
    if (!self) return nil;
    _zoom = 1.0;
    _view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 900, 600)];
    _view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _client = new BSClient(delegate);
    CefWindowInfo window;
    window.SetAsChild((__bridge void*)_view, CefRect(0, 0, 900, 600));
    CefBrowserSettings settings;
    CefBrowserHost::CreateBrowserSync(window, _client, "about:blank", settings, nullptr, ContextForPath(cachePath));
    return self;
}

- (NSView *)view { return _view; }

- (NSString *)currentURL {
    CefRefPtr<CefBrowser> b = _client->browser();
    if (!b) return nil;
    NSString* u = ToNS(b->GetMainFrame()->GetURL());
    return (u.length == 0 || [u isEqualToString:@"about:blank"]) ? nil : u;
}

- (double)zoomFactor { return _zoom; }
- (void)setZoomFactor:(double)factor {
    _zoom = factor;
    if (auto b = _client->browser()) b->GetHost()->SetZoomLevel(std::log(factor) / std::log(1.2));
}

- (void)loadURL:(NSString *)url { if (auto b = _client->browser()) b->GetMainFrame()->LoadURL(ToStd(url)); }
- (void)reload { if (auto b = _client->browser()) b->Reload(); }
- (void)stop { if (auto b = _client->browser()) b->StopLoad(); }
- (void)goBack { if (auto b = _client->browser()) b->GoBack(); }
- (void)goForward { if (auto b = _client->browser()) b->GoForward(); }
- (void)focus { if (auto b = _client->browser()) b->GetHost()->SetFocus(true); }

- (void)loadErrorHTML:(NSString *)html baseURL:(NSString *)baseURL {
    auto b = _client->browser();
    if (!b) return;
    NSString* encoded = [[html dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
    _client->set_error_display_url(baseURL);
    b->GetMainFrame()->LoadURL(ToStd([@"data:text/html;charset=utf-8;base64," stringByAppendingString:encoded]));
}

- (void)close {
    if (auto b = _client->browser()) b->GetHost()->CloseBrowser(true);
}

@end
