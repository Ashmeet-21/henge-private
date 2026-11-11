/* Mac apps with windows (experimental): an AppKit app loaded by Henge's translation layer and run on the main thread
   against Henge's AppKit (tl/shim/appkit), its windows shown by MacScreenView (Swift) through the calls below. */
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <stdatomic.h>
#include <string.h>

#include "henge-ios-jit.h"
#include "henge-tl.h"
#include "henge-vm.h"
#include "../../../tl/loader/tl_loader.h"
#include "../../../tl/shim/appkit/HKShim.h"

HengeDualMapping *henge_ios_jit_get_mapping(void);
extern _Atomic int henge_tl_ran;
void henge_tl_mark_ran(void); /* henge-tl.c: one program or app per launch */

static TlImage *g_exe;
static NSString *g_app;
static NSArray<NSString *> *g_args;
static void (*g_changed)(void);
static HKPresenter g_presenter = {{1180, 680}, 3, NULL};

static void log_line(const char *line) { fprintf(stderr, "%s\n", line); }

/* Henge's AppKit for what iOS lacks; iOS's own libraries for the rest. A library iOS keeps elsewhere (AudioUnit's
   calls are in AudioToolbox) is found by name among what is loaded. */
static void *shim_lookup(const char *install_name, const char *symbol) {
    void *s = hk_lookup(install_name, symbol);
    if (s) return s;
    char buf[1024];
    if (install_name && *install_name && !tl_ios_map_install_name(install_name, buf, sizeof buf) && strncmp(symbol, "_OBJC_", 6))
        return dlsym(RTLD_DEFAULT, symbol + 1);
    return NULL;
}

/* iOS's library names. Built for the Mac (tests/test_tl_app), the frameworks whose Mac versions load the real
   AppKit are refused as well, as tl/tools/tlios does: on iOS they don't, and with AppKit loaded UIFoundation draws
   text the AppKit way, which iOS never does. */
static const char *map_name(const char *name, char *buf, size_t len) {
#if TARGET_OS_OSX
    static const char *const appkit_loaders[] = {"/AuthenticationServices.framework/", "/ScreenCaptureKit.framework/",
                                                 "/MediaPlayer.framework/", "/SafariServices.framework/",
                                                 "/LocalAuthenticationEmbeddedUI.framework/", "/Accessibility.framework/",
                                                 "/MetalKit.framework/", "/WebKit.framework/", "/AVKit.framework/", "/StoreKit.framework/", NULL};
    for (int i = 0; appkit_loaders[i]; i++)
        if (strstr(name, appkit_loaders[i])) return NULL;
#endif
    return tl_ios_map_install_name(name, buf, len);
}

/* A process the app starts inside Henge (processes as threads) runs as its own .app: a helper's bundle. */
static void process_started(int ns, const char *path) {
    const char *macos = strstr(path, ".app/Contents/MacOS/");
    if (!macos) return;
    char app[4096];
    snprintf(app, sizeof app, "%.*s", (int)(macos - path + 4), path);
    tl_adopt_ns_bundle(ns, app);
    fprintf(stderr, "henge: tl: process %d runs %s\n", ns, app);
}

static void window_changed(NSWindow *window, int visible) {
    (void)window, (void)visible;
    if (g_changed) g_changed();
}

/* Google Chrome itself (not Chromium): its pages need renderer processes. */
static BOOL is_branded_chrome(NSString *app) {
    NSString *fw = [app stringByAppendingPathComponent:@"Contents/Frameworks/Google Chrome Framework.framework"];
    return [[NSFileManager defaultManager] fileExistsAtPath:fw];
}

/* What the app's main is given: for a browser built on Chromium (Chrome's open-source build, Electron and CEF apps
   alike) the switches that keep it in one process, without a JIT, drawing in software: what iOS allows. */
static NSArray<NSString *> *arguments_for(NSString *app, NSString *exe) {
    NSMutableArray *args = [NSMutableArray arrayWithObject:exe];
    NSString *fw = [app stringByAppendingPathComponent:@"Contents/Frameworks"];
    NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:fw error:nil];
    BOOL chromium = NO, branded = NO, electron = NO;
    for (NSString *n in names) {
        /* Chromium-based browsers ship "<Name> Framework.framework" with Chromium's helper apps inside (Chrome,
           Chromium, Helium, Brave, Edge...); CEF and Electron apps carry their framework by name. */
        NSString *helpers = [fw stringByAppendingPathComponent:[n stringByAppendingPathComponent:@"Versions/Current/Helpers"]];
        if ([n isEqualToString:@"Chromium Embedded Framework.framework"] || [n isEqualToString:@"Electron Framework.framework"] ||
            ([n hasSuffix:@" Framework.framework"] && [[NSFileManager defaultManager] fileExistsAtPath:helpers]))
            chromium = YES;
        if ([n isEqualToString:@"Google Chrome Framework.framework"] || [n hasPrefix:@"Google Chrome for Testing"]) branded = YES;
        if ([n isEqualToString:@"Electron Framework.framework"]) electron = YES;
    }
    if (chromium) {
        NSString *data = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
            stringByAppendingPathComponent:[@"Mac Apps/" stringByAppendingString:app.lastPathComponent.stringByDeletingPathExtension]];
        [[NSFileManager defaultManager] createDirectoryAtPath:data withIntermediateDirectories:YES attributes:nil error:nil];
        [args addObject:[@"--user-data-dir=" stringByAppendingString:data]];
        if (electron && !getenv("HENGE_TL_ELECTRON_SINGLE"))
            /* Electron does not run as one process (its windows wait for a renderer that never comes): its helpers run
               as processes inside Henge, as few as it allows. */
            [args addObjectsFromArray:@[
                @"--in-process-gpu", @"--enable-features=NetworkServiceInProcess2", @"--renderer-process-limit=1",
                @"--disable-site-isolation-trials", @"--disable-features=RemoteCoreAnimationAPI,SpareRendererForSitePerProcess",
            ]];
        else if (branded)
            /* Google builds Chrome without its in-process renderer (content/browser/browser_main_loop.cc), so its
               renderers run as processes inside Henge, as few as Chrome allows: the GPU and network services in
               the browser, one renderer, no site isolation, no extensions, no WebUI toolbar or preloaded WebUI
               (each would be another renderer, another copy of Chrome's 250 MB of code). */
            [args addObjectsFromArray:@[
                @"--in-process-gpu", @"--enable-features=NetworkServiceInProcess2", @"--renderer-process-limit=1",
                @"--process-per-site", @"--disable-site-isolation-trials", @"--disable-extensions",
                @"--disable-component-extensions-with-background-pages", @"--disable-default-apps",
                @"--disable-features=RemoteCoreAnimationAPI,SpareRendererForSitePerProcess,PreloadTopChromeWebUI,"
                @"WebUIToolbar,WebUIReloadButton,WebUIBackForwardButton,WebUIHomeButton,WebUISplitTabsButton,"
                @"InitialWebUI,InitialWebUIWithoutExtensions",
            ]];
        else
            [args addObjectsFromArray:@[@"--single-process", @"--disable-features=RemoteCoreAnimationAPI"]];
        [args addObjectsFromArray:@[
            @"--no-sandbox", @"--test-type", /* no "unsupported command-line flag" bar over the page */
            @"--js-flags=--jitless", @"--use-mock-keychain", @"--no-first-run",
            @"--no-default-browser-check", @"--disable-component-update", @"--disable-background-networking",
            @"--disable-gpu", @"--disable-gpu-compositing", @"--disable-software-rasterizer", @"--window-position=0,0",
            [NSString stringWithFormat:@"--window-size=%d,%d", (int)g_presenter.screen_size.width, (int)g_presenter.screen_size.height],
        ]];
    }
#if TARGET_OS_OSX
    if (getenv("HENGE_TL_EXTRA_ARGS")) /* the Mac test only: more switches, space-separated */
        for (NSString *a in [@(getenv("HENGE_TL_EXTRA_ARGS")) componentsSeparatedByString:@" "])
            if (a.length) [args addObject:a];
#endif
    return args;
}

void henge_tl_app_set_screen(double width, double height, double scale) {
    g_presenter.screen_size = CGSizeMake(width, height);
    g_presenter.scale = scale;
}

void henge_tl_app_on_change(void (*callback)(void)) { g_changed = callback; }

int henge_tl_app_load(const char *app_path, char *err, size_t errlen) {
    @autoreleasepool {
        if (atomic_load(&henge_tl_ran)) return snprintf(err, errlen, "One Mac app per launch: quit Henge (swipe it away) and open it again."), -1;
        int vm = henge_vm_state();
        if (vm == 1 || vm == 3 || vm == 4) return snprintf(err, errlen, "Stop the Mac first: a Mac app and a Mac cannot run at once."), -1;
        HengeDualMapping *jit = henge_ios_jit_get_mapping();
        if (!jit || !jit->rw_addr || !jit->rx_addr) return snprintf(err, errlen, "Turn on JIT first."), -1;
        if (jit->size < (size_t)400 << 20) return snprintf(err, errlen, "The JIT region is too small (Settings > Performance > Code cache: 1 GB or more)."), -1;
        /* Google Chrome runs a renderer and a storage helper beside the browser, each with its own copy of Chrome's
           code (about 250 MB): four copies need the largest code cache. */
        if (is_branded_chrome(@(app_path)) && jit->size < (size_t)1400 << 20)
            return snprintf(err, errlen, "Google Chrome needs the largest code cache (Settings > Performance > Code cache: 1.5 GB). Chromium runs in less."), -1;
        HengeTlInfo info;
        if (henge_tl_info(app_path, &info, err, errlen)) return -1;
        static TlHost host;
        memset(&host, 0, sizeof host);
        size_t keep = (size_t)16 << 20; /* the region's start stays QEMU's way of finding it; the rest is the app's */
        tl_host_init_region(&host, jit->rx_addr + keep, jit->rw_addr + keep, jit->size - keep);
        host.map_install_name = map_name;
        host.shim_lookup = shim_lookup;
        host.log = log_line;
        host.soft_missing = 1;
        host.no_processes = 1; /* iOS starts no processes: the app's own programs run inside Henge (below) */
        host.processes_as_threads = 1;
        host.process_started = process_started;
        g_presenter.window_changed = window_changed;
        hk_set_presenter(&g_presenter);
#if !TARGET_OS_OSX
        /* AppKit's font methods onto UIKit's font class (only those it lacks), now that a Mac app runs. Not on a Mac:
           there CoreText fonts are plain CF objects, and macOS's UIFoundation would take them for AppKit's. */
        hk_font_adopt(nil);
#endif
        atomic_store(&henge_tl_ran, 1);
        henge_tl_mark_ran();
        fprintf(stderr, "henge: tl: loading the app %s\n", info.executable);
        g_exe = tl_load(&host, info.executable, err, errlen);
        if (!g_exe) return -1;
        g_app = @(app_path);
#if TARGET_OS_OSX
        tl_main_bundle_for_everyone(); /* the Mac test only: see tl_loader.h */
#endif
        /* The app's code sees its bundle as the main bundle; Henge keeps its own (tl_bundle.m). */
        if (tl_adopt_main_bundle(app_path)) fprintf(stderr, "henge: tl: %s has no bundle identifier\n", app_path);
        g_args = arguments_for(g_app, @(info.executable));
        fprintf(stderr, "henge: tl: loaded %zu MB at %p\n", tl_image_size(g_exe) >> 20, tl_image_base(g_exe));
        return 0;
    }
}

int henge_tl_app_run(void) {
    if (!g_exe) return -1;
    int argc = (int)g_args.count;
    const char **argv = calloc((size_t)argc + 1, sizeof *argv);
    for (int i = 0; i < argc; i++) argv[i] = strdup(g_args[i].UTF8String);
    const char *envp[] = {NULL};
    fprintf(stderr, "henge: tl: running the app's main on the main thread\n");
    int rc = tl_run_main(g_exe, argc, argv, envp);
    fprintf(stderr, "henge: tl: the app's main returned %d\n", rc);
    return rc;
}

/* Enters the app's main from a run-loop timer on the main thread, not from a main-queue block: the app's run loop
   then owns the main thread, and a block would keep every later main-queue block (SwiftUI's, Swift concurrency's
   main actor) waiting until the app quits. */
void henge_tl_app_run_soon(void (*finished)(int)) {
    CFRunLoopTimerRef t = CFRunLoopTimerCreateWithHandler(NULL, CFAbsoluteTimeGetCurrent() + 0.05, 0, 0, 0, ^(CFRunLoopTimerRef timer) {
        (void)timer;
        int rc = henge_tl_app_run();
        if (finished) finished(rc);
    });
    CFRunLoopAddTimer(CFRunLoopGetMain(), t, kCFRunLoopCommonModes);
    CFRelease(t);
}

/* ---- windows, for MacScreenView ---- */

static NSArray<NSWindow *> *shown(void) { return hk_visible_windows(); }

int henge_tl_app_window_count(void) { return (int)shown().count; }

void *henge_tl_app_window_layer(int index) {
    NSArray *ws = shown();
    return index >= 0 && index < (int)ws.count ? (__bridge void *)[ws[index] hk_rootLayer] : NULL;
}

int henge_tl_app_window_frame(int index, double *x, double *y, double *w, double *h) {
    NSArray<NSWindow *> *ws = shown();
    if (index < 0 || index >= (int)ws.count) return -1;
    NSRect f = ws[index].frame;
    *x = f.origin.x, *y = f.origin.y, *w = f.size.width, *h = f.size.height;
    return 0;
}

double henge_tl_app_screen_height(void) { return g_presenter.screen_size.height; }

/* A point on the screen (points, origin bottom left) to the frontmost window under it and a point in it. */
static NSWindow *window_at(double sx, double sy, CGPoint *local) {
    for (NSWindow *w in [shown() reverseObjectEnumerator]) {
        NSRect f = w.frame;
        if (sx >= f.origin.x && sx < NSMaxX(f) && sy >= f.origin.y && sy < NSMaxY(f)) {
            *local = CGPointMake(sx - f.origin.x, sy - f.origin.y);
            return w;
        }
    }
    return nil;
}

static __weak NSWindow *g_grab; /* the window a drag started in keeps it */

void henge_tl_app_mouse(int type, double sx, double sy, int clicks, unsigned long flags) {
    CGPoint local = CGPointZero;
    NSWindow *w = nil;
    if (g_grab && (type == NSEventTypeLeftMouseDragged || type == NSEventTypeLeftMouseUp)) {
        w = g_grab;
        local = CGPointMake(sx - w.frame.origin.x, sy - w.frame.origin.y);
    } else {
        w = window_at(sx, sy, &local);
    }
    if (!w) return;
    if (type == NSEventTypeLeftMouseDown) g_grab = w;
    if (type == NSEventTypeLeftMouseUp) g_grab = nil;
    hk_post_mouse(w, (NSEventType)type, local, flags, clicks);
}

void henge_tl_app_scroll(double sx, double sy, double dx, double dy, int phase) {
    CGPoint local;
    NSWindow *w = window_at(sx, sy, &local);
    if (w) hk_post_scroll(w, local, dx, dy, (NSEventPhase)phase);
}

void henge_tl_app_key(int down, unsigned short keycode, const char *chars, unsigned long flags) {
    NSWindow *w = NSApp.keyWindow ?: shown().lastObject;
    if (!w) return;
    NSString *c = chars ? @(chars) : @"";
    hk_post_key(w, down ? NSEventTypeKeyDown : NSEventTypeKeyUp, keycode, c, c, flags);
}
