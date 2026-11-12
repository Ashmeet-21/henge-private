/* IOSurfaces as layer contents. A Mac app's compositor (Chromium's) hands each finished frame to Core Animation as an
   IOSurface set as a layer's contents, and re-signals the same surface with -setContentsChanged when it redraws into
   it. iOS's Core Animation is not known to show an IOSurface given that way (a Chromium window on the phone showed its
   frame colour and nothing it composited), so once a Mac app runs there, such contents become an image of the
   surface's pixels (copied, so the app may draw on into the surface). HK_SURFACE_COPY=1 does the same on a Mac, to
   test it. */
#import "HKShim.h"
#import <IOSurface/IOSurfaceRef.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static IMP g_set_contents, g_contents_changed;
static char g_surface_key;
static int g_said;

/* The surface's pixels as an image, or NULL for a pixel format this does not know. */
static CGImageRef image_of_surface(IOSurfaceRef s) {
    OSType format = IOSurfaceGetPixelFormat(s);
    CGBitmapInfo info;
    if (format == 'BGRA') info = kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaPremultipliedFirst;
    else if (format == 'RGBA') info = kCGBitmapByteOrder32Big | (CGBitmapInfo)kCGImageAlphaPremultipliedLast;
    else return NULL;
    size_t w = IOSurfaceGetWidth(s), h = IOSurfaceGetHeight(s), row = IOSurfaceGetBytesPerRow(s);
    if (!w || !h) return NULL;
    IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
    CFDataRef data = CFDataCreate(NULL, IOSurfaceGetBaseAddress(s), (CFIndex)(row * h));
    IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CFRelease(data);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef img = CGImageCreate(w, h, 8, 32, row, cs, info, provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(cs);
    CGDataProviderRelease(provider);
    return img;
}

static void set_contents(CALayer *self, SEL _cmd, id contents) {
    if (contents && CFGetTypeID((__bridge CFTypeRef)contents) == IOSurfaceGetTypeID()) {
        IOSurfaceRef s = (__bridge IOSurfaceRef)contents;
        if (g_said++ < 3)
            hk_log("an IOSurface as layer contents (%zux%zu, '%.4s'): shown as an image", IOSurfaceGetWidth(s), IOSurfaceGetHeight(s),
                   (const char *)&(OSType){CFSwapInt32HostToBig(IOSurfaceGetPixelFormat(s))});
        objc_setAssociatedObject(self, &g_surface_key, contents, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CGImageRef img = image_of_surface(s);
        if (img) {
            ((void (*)(id, SEL, id))g_set_contents)(self, _cmd, (__bridge id)img);
            CGImageRelease(img);
            return;
        }
    } else if (objc_getAssociatedObject(self, &g_surface_key)) {
        objc_setAssociatedObject(self, &g_surface_key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    ((void (*)(id, SEL, id))g_set_contents)(self, _cmd, contents);
}

/* The app drew again into the surface it already gave: a fresh image of it. */
static void contents_changed(CALayer *self, SEL _cmd) {
    id surface = objc_getAssociatedObject(self, &g_surface_key);
    if (surface) {
        CGImageRef img = image_of_surface((__bridge IOSurfaceRef)surface);
        if (img) {
            ((void (*)(id, SEL, id))g_set_contents)(self, @selector(setContents:), (__bridge id)img);
            CGImageRelease(img);
        }
    }
    if (g_contents_changed) ((void (*)(id, SEL))g_contents_changed)(self, _cmd);
}

void hk_surfaces_as_images(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Method m = class_getInstanceMethod([CALayer class], @selector(setContents:));
        g_set_contents = method_setImplementation(m, (IMP)set_contents);
        SEL changed = NSSelectorFromString(@"setContentsChanged");
        Method c = class_getInstanceMethod([CALayer class], changed);
        if (c) g_contents_changed = method_setImplementation(c, (IMP)contents_changed);
        else class_addMethod([CALayer class], changed, (IMP)contents_changed, "v@:");
    });
}
