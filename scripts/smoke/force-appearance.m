#import <AppKit/AppKit.h>

__attribute__((constructor)) static void forceAppearance(void) {
    const char *mode = getenv("FORCE_APPEARANCE");
    NSAppearanceName name = (mode && strcmp(mode, "light") == 0) ? NSAppearanceNameAqua : NSAppearanceNameDarkAqua;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSApp.appearance = [NSAppearance appearanceNamed:name];
    });
}
