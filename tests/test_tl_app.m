/* The app's glue for Mac apps with windows (ios/Henge/Native/henge-tl-app.m) on the Mac: the same loading, switches,
   bindings and window hand-off the phone uses, with iOS's library names (so Mac-only libraries are refused as on
   iOS; symbols Mac libraries have beyond iOS's are not, which tl/tools/tlios checks instead). Windows are drawn to
   PNG files every few seconds.

   test_tl_app APP SNAPDIR [SECONDS] */
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <stdatomic.h>

#include "henge-ios-jit.h"
#include "henge-tl.h"
#include "jit_region.h"

static HvJitRegion jit;
static HengeDualMapping mapping;
_Atomic int henge_tl_ran;
int henge_vm_state(void) { return 0; }
HengeDualMapping *henge_ios_jit_get_mapping(void) { return &mapping; }

static NSString *g_dir;
static int g_n;

static void changed(void) { fprintf(stderr, "test_tl_app: %d windows\n", henge_tl_app_window_count()); }

static void snap(CFRunLoopTimerRef t, void *info) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        int n = henge_tl_app_window_count();
        for (int i = 0; i < n; i++) {
            CALayer *root = (__bridge CALayer *)henge_tl_app_window_layer(i);
            double x, y, w, h;
            henge_tl_app_window_frame(i, &x, &y, &w, &h);
            size_t W = (size_t)w * 2, H = (size_t)h * 2;
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
            td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            td.storageMode = MTLStorageModeShared;
            id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
            id<MTLCommandQueue> q = [dev newCommandQueue];
            CALayer *stage = [CALayer layer], *old = root.superlayer;
            stage.anchorPoint = CGPointZero;
            stage.frame = CGRectMake(0, 0, W, H);
            CALayer *scaled = [CALayer layer];
            scaled.anchorPoint = CGPointZero;
            scaled.frame = CGRectMake(0, 0, w, h);
            scaled.transform = CATransform3DMakeScale(2, 2, 1);
            [stage addSublayer:scaled];
            [root removeFromSuperlayer];
            [scaled addSublayer:root];
            CARenderer *r = [CARenderer rendererWithMTLTexture:tex options:@{kCARendererMetalCommandQueue : q}];
            r.layer = stage;
            r.bounds = stage.frame;
            [CATransaction flush]; /* the renderer sees only what is committed after it has the layer */
            [r beginFrameAtTime:CACurrentMediaTime() timeStamp:NULL];
            [r addUpdateRect:r.bounds];
            [r render];
            [r endFrame];
            id<MTLCommandBuffer> cb = [q commandBuffer];
            [cb commit];
            [cb waitUntilCompleted];
            [root removeFromSuperlayer];
            [old addSublayer:root];
            void *px = malloc(W * H * 4);
            [tex getBytes:px bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
            CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            CGContextRef ctx = CGBitmapContextCreate(px, W, H, 8, W * 4, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
            CGImageRef upside = CGBitmapContextCreateImage(ctx); /* the texture's rows run top down: turn it over */
        CGContextClearRect(ctx, CGRectMake(0, 0, W, H));
        CGContextTranslateCTM(ctx, 0, H);
        CGContextScaleCTM(ctx, 1, -1);
        CGContextDrawImage(ctx, CGRectMake(0, 0, W, H), upside);
        CGImageRelease(upside);
        CGImageRef img = CGBitmapContextCreateImage(ctx);
            NSString *path = [g_dir stringByAppendingPathComponent:[NSString stringWithFormat:@"win%d-%03d.png", i, g_n]];
            CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, NULL);
            CGImageDestinationAddImage(d, img, NULL);
            CGImageDestinationFinalize(d);
            CFRelease(d);
            CGImageRelease(img);
            CGContextRelease(ctx);
            CGColorSpaceRelease(cs);
            free(px);
            fprintf(stderr, "test_tl_app: %s\n", path.UTF8String);
        }
        g_n++;
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "usage: test_tl_app APP SNAPDIR [SECONDS]\n");
            return 2;
        }
        setenv("HV_JIT_SPLIT", "1", 1);
        if (hv_jit_region_open(&jit, (getenv("TEST_TL_APP_MB") ? atoi(getenv("TEST_TL_APP_MB")) : 1536) << 20)) return 1; /* the phone's largest code cache */
        mapping = (HengeDualMapping){.rx_addr = (uint8_t *)jit.base, .rw_addr = (uint8_t *)jit.base + jit.rw_diff, .size = jit.capacity * 4};
        g_dir = @(argv[2]);
        [[NSFileManager defaultManager] createDirectoryAtPath:g_dir withIntermediateDirectories:YES attributes:nil error:nil];
        double every = argc > 3 ? atof(argv[3]) : 5;
        /* NSParagraphStyle, string drawing: UIKit always has UIFoundation loaded on iOS. */
        dlopen("/System/Library/PrivateFrameworks/UIFoundation.framework/UIFoundation", RTLD_LAZY);
        henge_tl_app_set_screen(1180, 680, 2);
        henge_tl_app_on_change(changed);
        /* Loaded on another thread, as the app does (MacAppScreen loads off the main thread). */
        static char err[512] = "";
        __block int rc = 0;
        const char *app = argv[1];
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            rc = henge_tl_app_load(app, err, sizeof err);
            dispatch_semaphore_signal(done);
        });
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
        if (rc) {
            fprintf(stderr, "test_tl_app: %s\n", err);
            return 1;
        }
        CFRunLoopTimerRef t = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + every, every, 0, 0, snap, NULL);
        CFRunLoopAddTimer(CFRunLoopGetMain(), t, kCFRunLoopCommonModes);
        return henge_tl_app_run();
    }
}
