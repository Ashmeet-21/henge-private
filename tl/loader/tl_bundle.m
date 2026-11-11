/* The guest app's bundle as the process's main bundle. */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#include "tl_loader.h"

static NSBundle *g_bundle;
static IMP g_host_main_bundle;
static int g_for_everyone;

void tl_main_bundle_for_everyone(void) { g_for_everyone = 1; }

/* The app's own code asking (objc_msgSend tail-calls this, so the return address is the caller's) gets the app's
   bundle; anything else, the host included (Henge reads its own resources and build all launch), the host's. */
static NSBundle *main_bundle(id self, SEL _cmd) {
    if (g_bundle && (g_for_everyone || tl_image_containing(__builtin_return_address(0)))) return g_bundle;
    return ((NSBundle * (*)(id, SEL))g_host_main_bundle)(self, _cmd);
}

void *tl_main_bundle(void) { return (__bridge void *)g_bundle; }

int tl_adopt_main_bundle(const char *app_path) {
    @autoreleasepool {
        NSBundle *b = [NSBundle bundleWithPath:@(app_path)];
        if (!b || !b.bundleIdentifier) return -1;
        g_bundle = b;
        Method m = class_getClassMethod([NSBundle class], @selector(mainBundle));
        IMP old = method_setImplementation(m, (IMP)main_bundle);
        if (old != (IMP)main_bundle) g_host_main_bundle = old;
        /* Not yet: CFBundleGetMainBundle() still answers the host's bundle (LiveContainer rewrites the CFBundle). */
        return 0;
    }
}
