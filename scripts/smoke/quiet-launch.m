// Run a macOS app for automated checks without stealing the person's focus: no activation,
// no Dock icon or menu-bar takeover, windows hidden below the desktop (still capturable by window id;
// full-screen captures show the wallpaper instead). QUIET_VISIBLE=1 keeps them behind other apps only.
// Build: clang -dynamiclib -fobjc-arc -framework AppKit -o quiet-launch.dylib quiet-launch.m
// Use:   DYLD_INSERT_LIBRARIES=quiet-launch.dylib <binary>   (chain with ':' — e.g. ui-probe.dylib)
// Locally built, non-hardened binaries only (like force-appearance.m and ui-probe.m).
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

#if !__has_feature(objc_arc)
#error Build with -fobjc-arc
#endif

static IMP originalSetPolicy;

static void noActivate(id self, SEL _cmd, BOOL flag) {}
static void noActivatePlain(id self, SEL _cmd) {}
static BOOL setAccessoryPolicy(id self, SEL _cmd, NSApplicationActivationPolicy policy) {
    return ((BOOL (*)(id, SEL, NSApplicationActivationPolicy))originalSetPolicy)(
        self, _cmd, NSApplicationActivationPolicyAccessory);
}

static void replace(Class cls, SEL sel, IMP imp, IMP *original) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP old = method_setImplementation(m, imp);
    if (original) *original = old;
}

// Hidden by default (QUIET_VISIBLE=1 opts out): every window (panels and sheets too) lives one level below the desktop, so the
// wallpaper covers it and nothing appears on screen; window captures by id still render it.
static BOOL hidden;
static IMP originalSetLevel;
static NSWindowLevel belowDesktop(void) { return CGWindowLevelForKey(kCGDesktopWindowLevelKey) - 1; }
static void forceLevel(id self, SEL _cmd, NSWindowLevel level) {
    ((void (*)(id, SEL, NSWindowLevel))originalSetLevel)(self, _cmd, belowDesktop());
}

static void sendWindowsBack(void) {
    for (NSWindow *w in NSApp.windows) {
        if (!w.isVisible) continue;
        if (hidden) [w setLevel:belowDesktop()];
        [w orderBack:nil];
    }
}

__attribute__((constructor)) static void quietLaunch(void) {
    hidden = getenv("QUIET_VISIBLE") == NULL;
    if (hidden) replace([NSWindow class], @selector(setLevel:), (IMP)forceLevel, &originalSetLevel);
    Class app = [NSApplication class];
    replace(app, @selector(activateIgnoringOtherApps:), (IMP)noActivate, NULL);
    replace(app, NSSelectorFromString(@"activate"), (IMP)noActivatePlain, NULL);
    replace(app, @selector(setActivationPolicy:), (IMP)setAccessoryPolicy, &originalSetPolicy);
    replace([NSRunningApplication class], @selector(activateWithOptions:), (IMP)noActivate, NULL);

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil queue:nil
                usingBlock:^(NSNotification *n) {
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        for (double delay = 0.2; delay <= 3.0; delay += 0.4) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ sendWindowsBack(); });
        }
    }];
    [nc addObserverForName:NSWindowDidBecomeKeyNotification object:nil queue:nil
                usingBlock:^(NSNotification *n) { [n.object orderBack:nil]; }];
    if (hidden) {
        [nc addObserverForName:NSWindowDidUpdateNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
            NSWindow *w = n.object;
            if (w.isVisible && w.level != belowDesktop()) [w setLevel:belowDesktop()];
        }];
    }
}
