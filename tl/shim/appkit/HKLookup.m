/* What Henge's AppKit answers for a symbol a program imports from a Mac-only library (or a Mac-only symbol of a
   library iOS has): its classes, C functions and constants, from the generated table of this image's own symbols (iOS
   has classes of its own named NSColor and NSFont, so never by name); then, by name, the classes UIFoundation has on
   both systems (NSParagraphStyle, NSShadow...), never one from a Mac-only library loaded in the Mac test runner. */
#import "HKShim.h"
#import <objc/runtime.h>
#include <dlfcn.h>
#include <string.h>

static const char *own_image(void) {
    static const char *path;
    if (!path) {
        Dl_info info;
        if (dladdr((const void *)&hk_lookup, &info)) path = strdup(info.dli_fname);
    }
    return path;
}

static int class_allowed(Class c) {
    const char *img = class_getImageName(c);
    if (!img) return 0;
    const char *own = own_image();
    return (own && !strcmp(img, own)) || strstr(img, "/UIFoundation.framework/") != NULL;
}

void *hk_lookup(const char *install_name, const char *symbol) {
    if (!symbol || symbol[0] != '_') return NULL;
    /* Classes that go by another runtime name here, since iOS has its own of the same name (HKShim.h). */
    static const char *const renamed[][2] = {
        {"_OBJC_CLASS_$_NSColor", "_OBJC_CLASS_$_HKColor"}, {"_OBJC_METACLASS_$_NSColor", "_OBJC_METACLASS_$_HKColor"},
        {"_OBJC_CLASS_$_NSFont", "_OBJC_CLASS_$_HKFont"}, {"_OBJC_METACLASS_$_NSFont", "_OBJC_METACLASS_$_HKFont"},
        {"_OBJC_CLASS_$_NSFontDescriptor", "_OBJC_CLASS_$_HKFontDescriptor"},
        {"_OBJC_METACLASS_$_NSFontDescriptor", "_OBJC_METACLASS_$_HKFontDescriptor"},
    };
    for (size_t i = 0; i < sizeof renamed / sizeof *renamed; i++)
        if (!strcmp(symbol, renamed[i][0])) symbol = renamed[i][1];
    for (int i = 0; i < hk_nsymbols; i++) /* this image's own definitions first, classes included */
        if (!strcmp(hk_symbols[i].name, symbol)) return hk_symbols[i].address;
    if (!strncmp(symbol, "_OBJC_CLASS_$_", 14) || !strncmp(symbol, "_OBJC_METACLASS_$_", 18)) {
        int meta = symbol[6] == 'M';
        Class c = objc_getClass(symbol + (meta ? 18 : 14));
        if (!c || !class_allowed(c)) return NULL;
        return meta ? (__bridge void *)object_getClass(c) : (__bridge void *)c;
    }
    return NULL;
}
