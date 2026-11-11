/* AppKit's private classes that apps check for by name (NSClassFromString) and then swizzle or call: present, with
   the methods they look for, doing nothing. */
#import "HKShim.h"

/* Chromium's Services-menu filter (chrome_swizzle_services_menu_updater.mm) stops the browser unless these exist
   and answer these selectors, with the type encodings its own replacements have. */
@interface _NSServiceEntry : HKShimObject
@property(copy) NSString *bundleIdentifier;
@end
@implementation _NSServiceEntry
@end

@interface _NSServicesMenuUpdater : HKShimObject
- (void)populateMenu:(id)menu withServiceEntries:(NSArray *)entries forDisplay:(BOOL)display;
- (void)plugMenu:(id)menu intoMenu:(id)parent;
@end
@implementation _NSServicesMenuUpdater
- (void)populateMenu:(id)menu withServiceEntries:(NSArray *)entries forDisplay:(BOOL)display {}
- (void)plugMenu:(id)menu intoMenu:(id)parent {}
@end
