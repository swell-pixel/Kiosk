//
//  Project 'Shine' Kiosk
//
//  Created by Alexey Yakovlev on 02/26/2019.
//

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <sys/sysctl.h>

#import "Reachability.h"
#import "Uptime.h"
#import "UIButton+Enabled.h"

//logging
#ifdef DEBUG
 #define LOG(...) NSLog(__VA_ARGS__)
#else
 #define LOG(...) (void)0
#endif
#define ERR(...) NSLog(__VA_ARGS__)

long g_touches; //user activity touch counter

@interface ViewController : UIViewController <WKNavigationDelegate>
@end

@implementation ViewController
{
    NSString *_url, *_host;
    NSTimer *_timer;
    time_t _timeout, _idle;
    NSInteger _error;
    NSArray *_buttons;
    WKWebView *_web;
    Reachability *_reachability;
}

- (id)button:(NSString *)title :(NSInteger)tag
{
    LOG(@" button %@ %ld", title, (long)tag);
    
    UIColor *shadow, *border = [UIColor systemBlueColor];
    if (@available(iOS 13.0, *))
        shadow = [UIColor systemGrayColor];
    else
        shadow = [UIColor blackColor];

    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    UIImage *i = [[UIImage imageNamed:title] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    [b setImage:i forState:UIControlStateNormal];
    [b setTintColor:border];
    [b setTag:tag];
    [b addTarget:self action:@selector(onClick:)
            forControlEvents:UIControlEventTouchUpInside];
    CALayer *l = [b layer];
    [l setMasksToBounds:NO];
    [l setShadowOffset:CGSizeMake(0.0, 3.0)];
    [l setShadowColor:shadow.CGColor];
    [l setBorderColor:border.CGColor];
    [l setBorderWidth:2.0];
    [l setShadowRadius:2.0];
    [l setShadowOpacity:0.5];
    [l setCornerRadius:28]; //button height / 2
    return b;
}

- (void)addObserver:(SEL)selector :(NSString *)name
{    [[NSNotificationCenter defaultCenter] addObserver:self selector:selector name:name object:nil];   }

- (void)removeObserver
{    [[NSNotificationCenter defaultCenter] removeObserver:self];  }

- (void)viewDidLoad
{
    LOG(@"ViewController.viewDidLoad");
    [super viewDidLoad];
    
    _web = [[WKWebView alloc] initWithFrame:CGRectZero];
    _web.navigationDelegate = self;
    _web.allowsBackForwardNavigationGestures  = YES;
    
    _buttons = @
    [
        [self button:@"refresh" :3], //0
        [self button:@"forward" :2], //1
        [self button:@"back"    :1], //2
    ];
    for (UIButton *b in _buttons)
        [_web addSubview:b];
    
    self.view = _web;
    [self addObserver:@selector(onDidBecomeActive:)  :UIApplicationDidBecomeActiveNotification];
    [self addObserver:@selector(onWillResignActive:) :UIApplicationWillResignActiveNotification];
    [self addObserver:@selector(onDefaults:)         :NSUserDefaultsDidChangeNotification];
    [self onDefaults:nil];
}

- (void)viewWillLayoutSubviews
{
    //LOG(@"ViewController.viewWillLayoutSubviews");
    [super viewWillLayoutSubviews];
    
    //position browser below status bar and above home indicator
    UIApplication *app = [UIApplication sharedApplication];
    CGRect statusbar = app.statusBarFrame;
    CGRect window = app.delegate.window.frame;
    CGFloat top = statusbar.size.height;
    CGFloat bottom = statusbar.size.height > 22 ? 34 : 0;
    _web.frame = CGRectMake(0, top,
                            window.size.width,
                            window.size.height - top - bottom);
    
    //group navigation buttons vertically in lower right with right padding
    CGFloat right = 8, spacing = 8, height = 56, width = 56;
    top = CGRectGetHeight(_web.frame) - height - bottom;
    for (UIView *view in _buttons)
    {
        view.frame = CGRectMake(CGRectGetWidth(_web.frame) - width - right, top, width, height);
        top -= height + spacing;
    }
}

- (void)viewDidDisappear:(BOOL)animated //never called for our single screen app
{
    LOG(@"ViewController.viewDidDisappear");
    [super viewDidDisappear:animated];

    [self removeObserver];
    [_reachability stopNotifier];
    [_timer invalidate];
    [_web stopLoading];
    [_web setNavigationDelegate:nil];
    [_web removeFromSuperview];
    self.view = _web = nil;
    _timeout = _idle = 0;
}

- (void)onDidBecomeActive:(NSNotification *)notification
{   LOG(@"ViewController.onDidBecomeActive");  }

- (void)onWillResignActive:(NSNotification *)notification
{   LOG(@"ViewController.onWillResignActive"); g_touches = 0;  }

- (void)onDefaults:(NSNotification *)notification
{
    LOG(@"ViewController.onDefaults");
    NSDictionary *cfg = [[NSUserDefaults standardUserDefaults]
                         dictionaryForKey:@"com.apple.configuration.managed"];

    NSString *nav = cfg[@"navigationButtons"];
    if (!nav.length)
        nav = @"1";
    BOOL hide = [nav isEqualToString:@"0"];
    for (UIButton *b in _buttons)
        b.hidden = hide;

    NSString *url = cfg[@"homeURL"];
    if (!url.length)
        url = @"https://www.bing.com"; //default
    NSRange r = [url rangeOfString:@"://"];
    if (r.location != NSNotFound && ![url isEqualToString:_url]) //different url?
    {
        _host = [[NSURL URLWithString:(_url = url)] host];
        [self addObserver:@selector(onReachability:) :kReachabilityChangedNotification];
        _reachability = [Reachability reachabilityForInternetConnection];
        [_reachability startNotifier];
        time_t now = uptime();
        if ([_reachability currentReachabilityStatus] && //connected?
            now >= _idle) //first time or idle?
            [self load:now];

        NSString *str = cfg[@"inactivityTimeout"];
        if (!str)
            str = @"30"; //default (in minutes)
        time_t timeout = abs([str intValue]*60); //timeout (in seconds)
        if (timeout != _timeout)
        {
            [_timer invalidate];
            if ((_timeout = timeout) != 0) //non-zero timeout?
            {
                //check for idle every 55 sec (BEFORE 60 sec web requests time out)
                _timer = [NSTimer scheduledTimerWithTimeInterval:55
                                                          target:self
                                                        selector:@selector(onTimer:)
                                                        userInfo:nil
                                                         repeats:YES];
            }
        }
    }
}
                  
- (void)onReachability:(NSNotification *)notification
{
    LOG(@"ViewController.onReachability url=%@ error=%ld",
        _web.URL.absoluteString, (long)_error);
    Reachability *reachability = [notification object];
    if ([reachability currentReachabilityStatus])
    {
        time_t now = uptime();
        if (_error && //previous request failed?
            ![_web.URL.absoluteString isEqualToString:@"about:blank"])
        {
            _error = 0;
            [_web reload];
        }
        else if (now >= _idle) //stale request?
        {
            _error = 0;
            [self load:now];
        }
    }
    else
    {
        LOG(@" Not connected");
    }
}

- (void)onTimer:(NSTimer *)timer
{
    time_t now = uptime();
    if (!_idle || g_touches)
        _idle = now + _timeout;
    LOG(@"ViewController.onTimer now=%ld idle=%ld timeout=%ld",
        now, _idle, _timeout);
    if (now >= _idle) //idle timeout?
        [self load:now];
    g_touches = 0;
}

- (void)onClick:(UIButton *)button
{
    LOG(@"ViewController.onClick tag=%ld error=%ld",
        (long)button.tag, (long)_error);
    switch (button.tag)
    {
        case 1: if ([_web canGoBack])    [_web goBack];    break;
        case 2: if ([_web canGoForward]) [_web goForward]; break;
        case 3:
            if (_error) //previous request failed?
            {
                _error = 0;
                [self load:uptime()];
            }
            else
                [_web reload];
            break;
    }
}

- (void)webView:(WKWebView *)web decidePolicyForNavigationAction:(WKNavigationAction *)action
                                                 decisionHandler:(void (^)(WKNavigationActionPolicy))handler
{
    LOG(@" Web.decidePolicyForNavigationAction %@", action.request.URL.absoluteString);
    handler(WKNavigationActionPolicyAllow);
}

- (void)webView:(WKWebView *)web didFinishNavigation:(WKNavigation *)nav
{
    LOG(@" Web.didFinishNavigation");
    ((UIButton *)_buttons[2]).enabled = [_web canGoBack];
    ((UIButton *)_buttons[1]).enabled = [_web canGoForward];
    [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
}

- (void)webView:(WKWebView *)web didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
    completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition,
                                NSURLCredential *credential))handler
{
    NSURLProtectionSpace *p = challenge.protectionSpace;
    LOG(@" Web.didReceiveAuthenticationChallenge");
    if ([_host isEqualToString:p.host])
    {
        LOG(@" accept=%@", p.host);
        SecTrustRef serverTrust = p.serverTrust;
        CFDataRef exceptions = SecTrustCopyExceptions(serverTrust);
        SecTrustSetExceptions(serverTrust, exceptions);
        CFRelease(exceptions);
        handler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:serverTrust]);
    }
    else
    {
        LOG(@" reject=%@", p.host);
        handler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
    }
}

- (void)webView:(WKWebView *)web didFailProvisionalNavigation:(WKNavigation *)nav withError:(NSError *)err
{   [self error:@"Web.didFailProvisionalNavigation" :[err localizedDescription]]; _error = err.code;  }

- (void)webView:(WKWebView *)web didFailNavigation:(WKNavigation *)nav withError:(NSError *)err
{   [self error:@"Web.didFailNavigation" :[err localizedDescription]]; _error = err.code;  }

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)web
{   [self error:@"Web.webViewWebContentProcessDidTerminate" :@"Web content process terminated."];  }

- (void)error:(NSString *)ctx :(NSString *)msg
{
    ERR(@" %@ %@", ctx, msg);
//    [_web loadHTMLString:[NSString stringWithFormat:@ TODO: HTML messages overwrite _web.URL
//        "<html>"
//        "<style>\n"
//        " <!--\n"
//        " body{font-family:sans-serif;font-size:160%%;}\n"
//        " -->\n"
//        "</style>\n"
//        "<body>\n"
//        " <br> %@\n"
//        " <br> %@\n"
//        "</body>\n"
//        "</html>",
//        _web.URL.absoluteString, msg] baseURL:nil];
//    msg = [NSString stringWithFormat:@"%@\n%@", _web.URL.absoluteString, msg];
//    UIAlertController *a = [UIAlertController alertControllerWithTitle:nil
//                                                               message:msg
//                                                        preferredStyle:UIAlertControllerStyleActionSheet];
//    [self presentViewController:a animated:YES completion:nil];
    [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
}

- (void)load:(time_t)now
{
    if (!_error) //previous request succeded?
    {
        NSString *url = _web.URL.absoluteString;
        NSRange r = [url rangeOfString:@"/" options:NSBackwardsSearch];
        if (r.location != NSNotFound && r.location == url.length-1) //trailing slash?
            url = [url substringToIndex:r.location]; //cut
        LOG(@"ViewController.load url=%@ error=%ld", url, (long)_error);
        if (![url isEqualToString:_url]) //not already loaded?
        {
            LOG(@" Web.loadRequest");
            [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:YES];
            NSURLRequest *req = [[NSURLRequest alloc] initWithURL:[[NSURL alloc] initWithString:_url]];
            [_web stopLoading];
            [_web loadRequest:req];
            ((UIButton *)_buttons[2]).enabled = NO;
            ((UIButton *)_buttons[1]).enabled = NO;
        }
    }
    _idle = now + _timeout;
}

@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
 @property (nonatomic) UIWindow *window;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opt
{
    LOG(@"AppDelegate.didFinishLaunchingWithOptions");
    UINavigationController *nc = [[UINavigationController alloc]
                                  initWithRootViewController:[[ViewController alloc] init]];
    nc.navigationBar.hidden = YES;
    
    UIColor *background;
    if (@available(iOS 13.0, *))
        background = [UIColor secondarySystemBackgroundColor];
    else
        background = [UIColor whiteColor];

    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.backgroundColor = background;
    self.window.rootViewController = nc;
    [self.window makeKeyAndVisible];
    return YES;
}

@end

@interface App : UIApplication
@end

@implementation App

- (void)sendEvent:(UIEvent *)event
{
    [super sendEvent:event];
    UITouch *touch = [[event allTouches] anyObject];
    if (touch.phase == UITouchPhaseEnded)
    {   g_touches++;  }  //LOG(@"App.sendEvent %ld", g_touches);  }
}

@end

int main(int argc, char * argv[])
{
    @autoreleasepool
    {   return UIApplicationMain(argc, argv, @"App", @"AppDelegate");  }
}
