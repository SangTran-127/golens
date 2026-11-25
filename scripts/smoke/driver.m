#import <AppKit/AppKit.h>
#import <CoreImage/CoreImage.h>
#import <objc/runtime.h>
#import <dlfcn.h>
@interface NSTextView (GoLensSmokeLens)
- (NSPoint)smokeLensHitPointForCharacterIndex:(NSInteger)charIndex title:(NSString *)title index:(NSInteger)index;
@end
static BOOL yesImp(id self, SEL _cmd) { return YES; }
static BOOL noImp(id self, SEL _cmd) { return NO; }
static NSWindow *fakeKey;
static id keyWinImp(id self, SEL _cmd) { return fakeKey.attachedSheet ?: fakeKey; }

static void forceActiveViewsRecursive(NSView *v) {
    if (!v) return;
    if ([v isKindOfClass:NSVisualEffectView.class]) {
        ((NSVisualEffectView *)v).state = NSVisualEffectStateActive;
    }
    v.needsDisplay = YES;
    for (NSView *sub in v.subviews) {
        forceActiveViewsRecursive(sub);
    }
}

static void activateWindowAndSheetAppearance(NSWindow *w) {
    if (!w) return;
    for (Class cls in @[NSWindow.class, w.class]) {
        method_setImplementation(class_getInstanceMethod(cls, @selector(isKeyWindow)), (IMP)yesImp);
        method_setImplementation(class_getInstanceMethod(cls, @selector(isMainWindow)), (IMP)yesImp);
        for (NSString *selName in @[@"_hasKeyAppearance", @"_hasMainAppearance", @"_hasActiveAppearance", @"hasKeyAppearance"]) {
            SEL sel = NSSelectorFromString(selName);
            Method m = class_getInstanceMethod(cls, sel);
            if (m) method_setImplementation(m, (IMP)yesImp);
        }
    }
    forceActiveViewsRecursive(w.contentView.superview ?: w.contentView);
    [w displayIfNeeded];
    if (w.attachedSheet) {
        Class scls = w.attachedSheet.class;
        method_setImplementation(class_getInstanceMethod(scls, @selector(isKeyWindow)), (IMP)yesImp);
        method_setImplementation(class_getInstanceMethod(scls, @selector(isMainWindow)), (IMP)yesImp);
        for (NSString *selName in @[@"_hasKeyAppearance", @"_hasMainAppearance", @"_hasActiveAppearance", @"hasKeyAppearance"]) {
            SEL sel = NSSelectorFromString(selName);
            Method m = class_getInstanceMethod(scls, sel);
            if (m) method_setImplementation(m, (IMP)yesImp);
        }
        forceActiveViewsRecursive(w.attachedSheet.contentView.superview ?: w.attachedSheet.contentView);
        [w.attachedSheet displayIfNeeded];
    }
}

static FILE *out;
#import <mach/mach.h>
#import <pthread.h>
static mach_port_t mainThreadPort;
static uintptr_t mainStackLow, mainStackHigh;
static int captureMainStack(uintptr_t *frames, int max) {
    if (!mainThreadPort || thread_suspend(mainThreadPort) != KERN_SUCCESS) return 0;
    int n = 0;
    arm_thread_state64_t st;
    mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(mainThreadPort, ARM_THREAD_STATE64, (thread_state_t)&st, &cnt) == KERN_SUCCESS) {
        frames[n++] = (uintptr_t)arm_thread_state64_get_pc(st) & 0x00007FFFFFFFFFFFULL;
        frames[n++] = (uintptr_t)arm_thread_state64_get_lr(st) & 0x00007FFFFFFFFFFFULL;
        uintptr_t fp = (uintptr_t)arm_thread_state64_get_fp(st);
        while (n < max && fp >= mainStackLow && fp + 16 <= mainStackHigh && (fp & 7) == 0) {
            uintptr_t next = ((uintptr_t *)fp)[0];
            uintptr_t ret = ((uintptr_t *)fp)[1] & 0x00007FFFFFFFFFFFULL;
            if (!ret) break;
            frames[n++] = ret;
            if (next <= fp) break;
            fp = next;
        }
    }
    thread_resume(mainThreadPort);
    return n;
}
static NSString *symbolize(uintptr_t a) {
    Dl_info info;
    if (!dladdr((void *)a, &info) || !info.dli_sname) return [NSString stringWithFormat:@"0x%lx", (unsigned long)a];
    const char *name = info.dli_sname;
    static char *(*demangle)(const char *, size_t, char *, size_t *, uint32_t);
    if (!demangle) demangle = (char *(*)(const char *, size_t, char *, size_t *, uint32_t))dlsym(RTLD_DEFAULT, "swift_demangle");
    NSString *mod = [[NSString stringWithUTF8String:info.dli_fname ?: "?"] lastPathComponent];
    NSString *sym = nil;
    if (demangle && (name[0] == '$' || (name[0] == '_' && name[1] == '$'))) {
        char *d = demangle(name, strlen(name), NULL, NULL, 0);
        if (d) { sym = [NSString stringWithUTF8String:d]; free(d); }
    }
    if (!sym) sym = [NSString stringWithUTF8String:name];
    if (sym.length > 140) sym = [[sym substringToIndex:140] stringByAppendingString:@"..."];
    return [NSString stringWithFormat:@"%@`%@", mod, sym];
}
static NSMutableArray<NSDictionary *> *stallStacks;
static NSArray<NSString *> *steps;
static NSUInteger stepIndex = 0;

static NSURL *stubURL;
static NSModalResponse stubRunModal(id self, SEL _cmd) { return NSModalResponseOK; }
static NSURL *stubURLImp(id self, SEL _cmd) { return stubURL; }
static NSArray *stubURLsImp(id self, SEL _cmd) { return stubURL ? @[stubURL] : @[]; }
static void say(NSString *s) { if (!out) out = stderr; fprintf(out, "DRIVE %s\n", s.UTF8String); fflush(out); }

static NSTextView *findEditor(NSView *v) {
    if ([NSStringFromClass(v.class) containsString:@"GoLensTextView"] && !v.isHiddenOrHasHiddenAncestor) return (NSTextView *)v;
    for (NSView *c in v.subviews) { NSTextView *t = findEditor(c); if (t) return t; }
    return nil;
}

static NSTextView *findConsole(NSView *v) {
    if ([NSStringFromClass(v.class) containsString:@"ConsoleTextView"] && !v.isHiddenOrHasHiddenAncestor) return (NSTextView *)v;
    for (NSView *c in v.subviews) { NSTextView *t = findConsole(c); if (t) return t; }
    return nil;
}

static NSTextView *editor(void) {
    if (fakeKey && fakeKey.isVisible) {
        NSTextView *t = findEditor(fakeKey.contentView);
        if (t) return t;
    }
    for (NSWindow *w in NSApp.windows) {
        if (!w.isVisible) continue;
        NSTextView *t = findEditor(w.contentView);
        if (t) return t;
    }
    return nil;
}

static NSWindow *mainWin(void) {
    NSWindow *best = nil;
    for (NSWindow *w in NSApp.windows) if (w.isVisible && !w.isSheet && w.frame.size.width * w.frame.size.height > best.frame.size.width * best.frame.size.height) best = w;
    return best;
}

static NSWindow *windowLike(NSString *s) { // a visible window whose title, autosave name, identifier or class contains s (the Settings window is not the main window)
    for (NSWindow *w in NSApp.windows) {
        if (!w.isVisible || w.isSheet) continue;
        if ([w.title containsString:s] || [w.frameAutosaveName containsString:s] || [w.identifier containsString:s] || [NSStringFromClass(w.class) containsString:s]) return w;
    }
    return nil;
}

static NSPanel *completionPanel(void) {
    for (NSWindow *w in NSApp.windows)
        if ([NSStringFromClass(w.class) containsString:@"CompletionPanel"]) return (NSPanel *)w;
    return nil;
}

static void runNext(void);
static void after(double s);
static void say(NSString *s);
static NSTextView *editor(void);
static NSTimer *watchTimer; static int watchShows = 0, watchHides = 0, watchSamples = 0; static BOOL watchLast = NO;
static double typeDelay = 0.12;

static void after(double s) {
    NSTimer *t = [NSTimer timerWithTimeInterval:s repeats:NO block:^(NSTimer *timer) { runNext(); }];
    [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
}

#import "driver_ax.h"
#import "driver_actions.h"

static void runNext(void) {
    if (stepIndex >= steps.count) return;
    NSString *step = steps[stepIndex++];
    NSRange colon = [step rangeOfString:@":"];
    NSString *cmd = colon.location == NSNotFound ? step : [step substringToIndex:colon.location];
    NSString *arg = colon.location == NSNotFound ? @"" : [step substringFromIndex:colon.location + 1];
    arg = [arg stringByReplacingOccurrencesOfString:@"\\n" withString:@"\n"];
    arg = [arg stringByReplacingOccurrencesOfString:@"\\t" withString:@"\t"];
    arg = [arg stringByReplacingOccurrencesOfString:@"\\x3b" withString:@";"];
    NSTextView *tv = editor();
    BOOL handled = NO;
    dispatchAXStep(cmd, arg, tv, &handled);
    if (handled) return;
    dispatchActionStep(cmd, arg, tv, &handled);
    if (handled) return;
    if ([cmd isEqualToString:@"keylat"]) { // keylat:<count>: main-thread key-to-paint latency of typing into the focused text view, queue wait included
        NSInteger n = MAX(1, [arg integerValue] ?: 200);
        id responder = NSApp.keyWindow.firstResponder;
        if (![responder respondsToSelector:@selector(insertText:replacementRange:)]) { say(@"keylat no text responder"); after(0.1); return; }
        NSMutableArray<NSNumber *> *samples = [NSMutableArray array];
        for (NSInteger i = 0; i < n; i++) {
            __block BOOL done = NO;
            double t0 = NSProcessInfo.processInfo.systemUptime;
            dispatch_async(dispatch_get_main_queue(), ^{
                [responder insertText:@"x" replacementRange:NSMakeRange(NSNotFound, 0)];
                [NSApp.keyWindow displayIfNeeded];
                [samples addObject:@((NSProcessInfo.processInfo.systemUptime - t0) * 1000.0)];
                done = YES;
            });
            while (!done) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.016]];
        }
        NSArray<NSNumber *> *sorted = [samples sortedArrayUsingSelector:@selector(compare:)];
        double p50 = sorted[sorted.count / 2].doubleValue;
        double p95 = sorted[MIN(sorted.count - 1, (NSUInteger)(sorted.count * 0.95))].doubleValue;
        double mx = sorted.lastObject.doubleValue;
        NSInteger over33 = 0, over50 = 0;
        for (NSNumber *v in sorted) { if (v.doubleValue > 33.4) over33++; if (v.doubleValue > 50.0) over50++; }
        say([NSString stringWithFormat:@"keylat n=%ld p50=%.2f p95=%.2f max=%.2f over33=%ld over50=%ld", (long)n, p50, p95, mx, (long)over33, (long)over50]);
        after(0.2); return;
    }
    if ([cmd isEqualToString:@"fontchurn"]) { // fontchurn:on|report: a background thread creates and frees monospaced system fonts; while it runs AppKit can return nil from monospacedSystemFont on other threads
        static volatile BOOL churnOn = NO;
        static volatile long churnCalls = 0, churnNils = 0;
        if ([arg isEqualToString:@"on"]) {
            if (!churnOn) {
                churnOn = YES;
                [NSThread detachNewThreadWithBlock:^{
                    long n = 0;
                    while (churnOn) {
                        @autoreleasepool {
                            NSFont *f = [NSFont monospacedSystemFontOfSize:9 + (n % 8) weight:(n & 1) ? NSFontWeightMedium : NSFontWeightRegular];
                            if (!f) churnNils++;
                            churnCalls++;
                            n++;
                        }
                    }
                }];
            }
            say(@"fontchurn on");
            after(0.05); return;
        }
        churnOn = NO;
        say([NSString stringWithFormat:@"fontchurn calls=%ld nil=%ld", churnCalls, churnNils]);
        after(0.1); return;
    }
    if ([cmd isEqualToString:@"hangmon"]) { // hangmon:on|report: a background thread pings the main queue every 10 ms; report counts main-thread stalls since on
        static volatile BOOL hangOn = NO;
        static NSMutableArray<NSNumber *> *hangSamples;
        static NSLock *hangLock;
        if ([arg isEqualToString:@"on"]) {
            if (!hangLock) hangLock = [NSLock new];
            [hangLock lock]; hangSamples = [NSMutableArray array]; stallStacks = [NSMutableArray array]; [hangLock unlock];
            if (!mainThreadPort) {
                mainThreadPort = mach_thread_self();
                pthread_t me = pthread_self();
                mainStackHigh = (uintptr_t)pthread_get_stackaddr_np(me);
                mainStackLow = mainStackHigh - pthread_get_stacksize_np(me);
            }
            if (!hangOn) {
                hangOn = YES;
                [NSThread detachNewThreadWithBlock:^{
                    while (hangOn) {
                        double t0 = NSProcessInfo.processInfo.systemUptime;
                        dispatch_semaphore_t s = dispatch_semaphore_create(0);
                        dispatch_async(dispatch_get_main_queue(), ^{ dispatch_semaphore_signal(s); });
                        NSMutableArray<NSArray<NSNumber *> *> *captures = [NSMutableArray array];
                        while (dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, 40 * NSEC_PER_MSEC)) != 0) {
                            if (captures.count < 6) {
                                uintptr_t frames[64];
                                int n = captureMainStack(frames, 64);
                                NSMutableArray<NSNumber *> *one = [NSMutableArray arrayWithCapacity:n];
                                for (int k = 0; k < n; k++) [one addObject:@(frames[k])];
                                [captures addObject:one];
                            }
                        }
                        double ms = (NSProcessInfo.processInfo.systemUptime - t0) * 1000.0;
                        [hangLock lock];
                        [hangSamples addObject:@(ms)];
                        if (captures.count && ms >= 50) [stallStacks addObject:@{@"ms": @(ms), @"epoch": @(NSDate.date.timeIntervalSince1970), @"captures": captures}];
                        [hangLock unlock];
                        usleep(10000);
                    }
                }];
            }
            say(@"hangmon on");
            after(0.05); return;
        }
        [hangLock lock];
        NSArray<NSNumber *> *sorted = [hangSamples sortedArrayUsingSelector:@selector(compare:)];
        hangSamples = [NSMutableArray array];
        NSArray<NSDictionary *> *stalls = [stallStacks sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [b[@"ms"] compare:a[@"ms"]]; }];
        stallStacks = [NSMutableArray array];
        [hangLock unlock];
        for (NSDictionary *st in [stalls subarrayWithRange:NSMakeRange(0, MIN(stalls.count, (NSUInteger)12))]) {
            NSArray<NSArray<NSNumber *> *> *caps = st[@"captures"];
            for (NSUInteger c = 0; c < caps.count; c++) {
                NSMutableArray *names = [NSMutableArray array];
                for (NSNumber *f in caps[c]) [names addObject:symbolize((uintptr_t)f.unsignedLongValue)];
                say([NSString stringWithFormat:@"stall %@ %.0f ms epoch=%.3f capture %lu/%lu: %@", arg, [st[@"ms"] doubleValue], [st[@"epoch"] doubleValue], (unsigned long)c + 1, (unsigned long)caps.count, [names componentsJoinedByString:@" <- "]]);
            }
        }
        if ([arg isEqualToString:@"off"]) hangOn = NO;
        NSInteger over100 = 0, over250 = 0, over500 = 0, over1000 = 0;
        for (NSNumber *v in sorted) { double d = v.doubleValue; if (d > 100) over100++; if (d > 250) over250++; if (d > 500) over500++; if (d > 1000) over1000++; }
        double p99 = sorted.count ? sorted[MIN(sorted.count - 1, (NSUInteger)(sorted.count * 0.99))].doubleValue : 0;
        say([NSString stringWithFormat:@"hangmon %@ n=%lu p99=%.1f max=%.1f over100=%ld over250=%ld over500=%ld over1000=%ld", arg, (unsigned long)sorted.count, p99, sorted.lastObject.doubleValue, (long)over100, (long)over250, (long)over500, (long)over1000]);
        after(0.05); return;
    }
    if ([cmd isEqualToString:@"screen"]) {
        NSWindow *w = tv.window;
        NSRect f = w.frame;
        CGFloat screenH = NSScreen.screens.firstObject.frame.size.height;
        NSString *dir = [NSString stringWithUTF8String:getenv("DRIVE_SHOTS") ?: "/tmp"];
        NSString *path = [dir stringByAppendingPathComponent:[arg stringByAppendingString:@".png"]];
        NSTask *t = [NSTask new];
        t.launchPath = @"/usr/sbin/screencapture";
        (void)f; (void)screenH;
        t.arguments = @[@"-x", @"-o", [NSString stringWithFormat:@"-l%ld", (long)w.windowNumber], path];
        [t launch]; [t waitUntilExit];
        NSWindow *top = nil;
        for (NSWindow *x in NSApp.windows) if (x.isVisible && x != w && (x.isSheet || [NSStringFromClass(x.class) containsString:@"Popover"] || [NSStringFromClass(x.class) containsString:@"CompletionPanel"])) top = x;
        if (top) {
            NSTask *t2 = [NSTask new]; t2.launchPath = @"/usr/sbin/screencapture";
            t2.arguments = @[@"-x", @"-o", [NSString stringWithFormat:@"-l%ld", (long)top.windowNumber], [path stringByReplacingOccurrencesOfString:@".png" withString:@"-overlay.png"]];
            [t2 launch]; [t2 waitUntilExit];
        }
        say([NSString stringWithFormat:@"screen %@ status=%d overlay=%@", path, t.terminationStatus, top ? NSStringFromClass(top.class) : @"none"]);
        after(0.2); return;
    }
    if ([cmd isEqualToString:@"windows"]) {
        for (NSWindow *w in NSApp.windows) if (w.isVisible) say([NSString stringWithFormat:@"window %@ class=%@ frame=%@ sheet=%d", w.title, NSStringFromClass(w.class), NSStringFromRect(w.frame), w.isSheet]);
        after(0.1); return;
    }
    if ([cmd isEqualToString:@"keystats"]) {
        NSArray<NSNumber *> *sorted = [keySamples ?: @[] sortedArrayUsingSelector:@selector(compare:)];
        keySamples = [NSMutableArray array];
        NSUInteger n = sorted.count;
        double (^pct)(double) = ^double(double q) { return n ? sorted[MIN(n - 1, (NSUInteger)(n * q))].doubleValue : 0; };
        NSInteger o16 = 0, o33 = 0, o50 = 0, o100 = 0;
        for (NSNumber *v in sorted) { double d = v.doubleValue; if (d > 16.7) o16++; if (d > 33.4) o33++; if (d > 50) o50++; if (d > 100) o100++; }
        say([NSString stringWithFormat:@"keystats %@ n=%lu p50=%.2f p95=%.2f p99=%.2f max=%.2f over16=%ld over33=%ld over50=%ld over100=%ld", arg, (unsigned long)n, pct(0.5), pct(0.95), pct(0.99), n ? sorted.lastObject.doubleValue : 0, (long)o16, (long)o33, (long)o50, (long)o100]);
        after(0.05); return;
    }
    if ([cmd isEqualToString:@"popovershot"]) { // popovershot:<name>: screenshot of each visible popover window
        NSString *dir = [NSString stringWithUTF8String:getenv("DRIVE_SHOTS") ?: "/tmp"];
        int n = 0;
        for (NSWindow *w in NSApp.windows) {
            if (!w.isVisible || ![NSStringFromClass(w.class) containsString:@"Popover"]) continue;
            NSString *name = n ? [NSString stringWithFormat:@"%@-%d.png", arg, n] : [arg stringByAppendingString:@".png"];
            NSTask *t = [NSTask new];
            t.launchPath = @"/usr/sbin/screencapture";
            t.arguments = @[@"-x", @"-o", [NSString stringWithFormat:@"-l%ld", (long)w.windowNumber], [dir stringByAppendingPathComponent:name]];
            t.environment = @{@"PATH": @"/usr/bin:/bin"};
            [t launch]; [t waitUntilExit];
            n++;
        }
        say([NSString stringWithFormat:@"popovershot %@ -> %d", arg, n]);
        after(0.2); return;
    }
    if ([cmd isEqualToString:@"defaultbool"]) { // defaultbool:<key>|<0 or 1>: sets a Bool preference in this process, the way a Picker binding would
        NSArray *parts = [arg componentsSeparatedByString:@"|"];
        if (parts.count > 1) [NSUserDefaults.standardUserDefaults setBool:[parts[1] boolValue] forKey:parts[0]];
        say([NSString stringWithFormat:@"defaultbool %@", arg]); after(0.5); return;
    }
    if ([cmd isEqualToString:@"diffscrollers"]) {
        NSWindow *baseWin = mainWin();
        NSWindow *w = (baseWin.attachedSheet && baseWin.attachedSheet.isVisible) ? baseWin.attachedSheet : baseWin;
        int nestedHoriz = 0;
        NSMutableArray<NSString *> *docked = [NSMutableArray array];
        NSMutableArray<NSView *> *stack = w ? [NSMutableArray arrayWithObject:w.contentView.superview ?: w.contentView] : [NSMutableArray array];
        while (stack.count) {
            NSView *v = stack.lastObject; [stack removeLastObject];
            if ([v isKindOfClass:NSScroller.class] && !v.isHiddenOrHasHiddenAncestor) {
                NSScroller *s = (NSScroller *)v;
                if (s.bounds.size.width > s.bounds.size.height && s.bounds.size.width > 24) {
                    if ([s.superview isKindOfClass:NSScrollView.class]) {
                        nestedHoriz++;
                    } else {
                        NSRect inWin = [s convertRect:s.bounds toView:nil];
                        [docked addObject:[NSString stringWithFormat:@"%@(val=%.3f,prop=%.3f,w=%.0f,y=%.0f)",
                            s.accessibilityLabel ?: @"scroller", s.doubleValue, s.knobProportion, inWin.size.width, inWin.origin.y]];
                    }
                }
            }
            [stack addObjectsFromArray:v.subviews];
        }
        say([NSString stringWithFormat:@"diffscrollers win=%@ nestedHoriz=%d docked=%lu [%@]",
            w.title ?: @"untitled", nestedHoriz, (unsigned long)docked.count, [docked componentsJoinedByString:@"; "]]);
        after(0.2); return;
    }
    if ([cmd isEqualToString:@"hwheel"]) {
        NSArray<NSString *> *parts = [arg componentsSeparatedByString:@"|"];
        NSString *side = parts.firstObject ?: @"right";
        int32_t dx = parts.count > 1 ? [parts[1] intValue] : -40;
        NSWindow *baseWin = mainWin();
        NSWindow *w = (baseWin.attachedSheet && baseWin.attachedSheet.isVisible) ? baseWin.attachedSheet : baseWin;
        if (w) {
            CGFloat fx = [side isEqualToString:@"left"] ? 0.28 : ([side isEqualToString:@"center"] ? 0.55 : 0.72);
            NSPoint winPt = NSMakePoint(w.frame.size.width * fx, w.frame.size.height * 0.45);
            CGPoint cgLoc = [w convertPointToScreen:winPt];
            for (int i = 0; i < 8; i++) {
                CGEventRef cg = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 2, 0, dx);
                if (cg) {
                    CGEventSetLocation(cg, cgLoc);
                    NSEvent *ev = [NSEvent eventWithCGEvent:cg];
                    CFRelease(cg);
                    if (ev) [NSApp sendEvent:ev];
                }
            }
        }
        say([NSString stringWithFormat:@"hwheel %@ dispatched", arg]);
        after(0.6); return;
    }
    if ([cmd isEqualToString:@"shot"]) {
        NSWindow *w = tv.window ?: mainWin();
        activateWindowAndSheetAppearance(w);
        NSPanel *cp = completionPanel();
        NSString *dir = [NSString stringWithUTF8String:getenv("DRIVE_SHOTS") ?: "/tmp"];
        NSString *path = [dir stringByAppendingPathComponent:[arg stringByAppendingString:@".png"]];
        NSMutableArray *pairs = [NSMutableArray arrayWithObject:@[@(w.windowNumber), path]];
        if (cp.isVisible) [pairs addObject:@[@(cp.windowNumber), [path stringByReplacingOccurrencesOfString:@".png" withString:@"-panel.png"]]];
        NSTask *t = nil;
        for (NSArray *pair in pairs) {
            NSTask *t2 = [NSTask new];
            t2.launchPath = @"/usr/sbin/screencapture";
            t2.arguments = @[@"-x", @"-o", [NSString stringWithFormat:@"-l%@", pair[0]], pair[1]];
            t2.environment = @{@"PATH": @"/usr/bin:/bin"};
            [t2 launch]; [t2 waitUntilExit];
            if (!t) t = t2;
        }
        NSArray *args = t.arguments;
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            // screencapture -l sometimes fails for a window that is on screen; retry once, then draw the window in process.
            [NSThread sleepForTimeInterval:0.3];
            NSTask *retry = [NSTask new];
            retry.launchPath = @"/usr/sbin/screencapture";
            retry.arguments = @[@"-x", @"-o", [NSString stringWithFormat:@"-l%ld", (long)w.windowNumber], path];
            retry.environment = @{@"PATH": @"/usr/bin:/bin"};
            [retry launch]; [retry waitUntilExit];
            if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
                NSView *root = w.contentView.superview ?: w.contentView;
                NSBitmapImageRep *rep = [root bitmapImageRepForCachingDisplayInRect:root.bounds];
                [root cacheDisplayInRect:root.bounds toBitmapImageRep:rep];
                [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
                say([NSString stringWithFormat:@"shot %@ drawn in process (screencapture status %d)", arg, retry.terminationStatus]);
            } else {
                say([NSString stringWithFormat:@"shot %@ captured on retry", arg]);
            }
        }
        if (w.attachedSheet && w.attachedSheet.isVisible) {
            NSString *sheetPath = [path stringByReplacingOccurrencesOfString:@".png" withString:@"-sheet-tmp.png"];
            NSTask *ts = [NSTask new];
            ts.launchPath = @"/usr/sbin/screencapture";
            ts.arguments = @[@"-x", @"-o", [NSString stringWithFormat:@"-l%ld", (long)w.attachedSheet.windowNumber], sheetPath];
            ts.environment = @{@"PATH": @"/usr/bin:/bin"};
            [ts launch]; [ts waitUntilExit];
            NSImage *baseImg = [[NSImage alloc] initWithContentsOfFile:path];
            NSImage *sheetImg = [[NSImage alloc] initWithContentsOfFile:sheetPath];
            if (baseImg && sheetImg && baseImg.size.width > 0 && sheetImg.size.height > 0) {
                CGFloat ptW = baseImg.size.width, ptH = baseImg.size.height;
                NSBitmapImageRep *baseRep = (NSBitmapImageRep *)baseImg.representations.firstObject;
                NSInteger pixW = baseRep.pixelsWide > 0 ? baseRep.pixelsWide : (NSInteger)(ptW * 2);
                NSInteger pixH = baseRep.pixelsHigh > 0 ? baseRep.pixelsHigh : (NSInteger)(ptH * 2);
                NSBitmapImageRep *outRep = [[NSBitmapImageRep alloc]
                    initWithBitmapDataPlanes:NULL
                    pixelsWide:pixW
                    pixelsHigh:pixH
                    bitsPerSample:8
                    samplesPerPixel:4
                    hasAlpha:YES
                    isPlanar:NO
                    colorSpaceName:NSDeviceRGBColorSpace
                    bytesPerRow:0
                    bitsPerPixel:0];
                outRep.size = NSMakeSize(ptW, ptH);
                [NSGraphicsContext saveGraphicsState];
                [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:outRep]];
                [baseImg drawInRect:NSMakeRect(0, 0, ptW, ptH)];

                CGFloat sx = round((ptW - sheetImg.size.width) / 2.0);
                CGFloat sy = round((ptH - sheetImg.size.height) / 2.0);
                NSRect sheetRect = NSMakeRect(sx, sy, sheetImg.size.width, sheetImg.size.height);
                NSBezierPath *sheetClip = [NSBezierPath bezierPathWithRoundedRect:sheetRect xRadius:14.0 yRadius:14.0];

                // Draw native macOS 26 sheet elevation shadow
                [NSGraphicsContext saveGraphicsState];
                NSShadow *shadow = [[NSShadow alloc] init];
                shadow.shadowColor = [NSColor colorWithWhite:0.0 alpha:0.28];
                shadow.shadowOffset = NSMakeSize(0, -10);
                shadow.shadowBlurRadius = 32.0;
                [shadow set];
                [[NSColor colorWithWhite:1.0 alpha:0.02] setFill];
                [sheetClip fill];
                [NSGraphicsContext restoreGraphicsState];

                // Draw Liquid Glass refracted backdrop of the underlying window inside the sheet shape
                [NSGraphicsContext saveGraphicsState];
                [sheetClip addClip];
                Class ciImageCls = NSClassFromString(@"CIImage");
                Class ciFilterCls = NSClassFromString(@"CIFilter");
                CIImage *ciBase = ciImageCls ? [(CIImage *)[ciImageCls alloc] initWithBitmapImageRep:baseRep] : nil;
                if (ciBase && ciFilterCls) {
                    CIFilter *clamp = [ciFilterCls filterWithName:@"CIAffineClamp"];
                    [clamp setValue:ciBase forKey:@"inputImage"];
                    [clamp setValue:[NSAffineTransform transform] forKey:@"inputTransform"];
                    CIFilter *blur = [ciFilterCls filterWithName:@"CIGaussianBlur"];
                    [blur setValue:[clamp valueForKey:@"outputImage"] forKey:@"inputImage"];
                    [blur setValue:@(22.0) forKey:@"inputRadius"];
                    CIFilter *colorCtrl = [ciFilterCls filterWithName:@"CIColorControls"];
                    [colorCtrl setValue:[blur valueForKey:@"outputImage"] forKey:@"inputImage"];
                    [colorCtrl setValue:@(1.35) forKey:@"inputSaturation"];
                    CIImage *outCI = [colorCtrl valueForKey:@"outputImage"];
                    CIImage *blurred = [outCI imageByCroppingToRect:NSMakeRect(0, 0, pixW, pixH)];
                    if (blurred) {
                        NSCIImageRep *ciRep = [NSCIImageRep imageRepWithCIImage:blurred];
                        NSImage *blurredImg = [[NSImage alloc] initWithSize:NSMakeSize(ptW, ptH)];
                        [blurredImg addRepresentation:ciRep];
                        [blurredImg drawInRect:NSMakeRect(0, 0, ptW, ptH)];
                    }
                }
                [sheetImg drawInRect:sheetRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:0.86];
                [NSGraphicsContext restoreGraphicsState];

                // Specular Liquid Glass 1pt rim highlight
                BOOL isDark = [w.effectiveAppearance.name containsString:@"Dark"];
                [[NSColor colorWithWhite:1.0 alpha:(isDark ? 0.22 : 0.55)] setStroke];
                sheetClip.lineWidth = 1.0;
                [sheetClip stroke];

                [NSGraphicsContext restoreGraphicsState];
                NSData *pngData = [outRep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                [pngData writeToFile:path atomically:YES];
            }
            [NSFileManager.defaultManager removeItemAtPath:sheetPath error:nil];
        }
        for (NSWindow *pw in NSApp.windows) {
            NSString *pwCls = NSStringFromClass(pw.class);
            if (!pw.isVisible || (![pwCls containsString:@"PopupPanel"] && ![pwCls containsString:@"Popover"]) || !pw.contentView) continue;
            activateWindowAndSheetAppearance(pw);
            [pw.contentView layoutSubtreeIfNeeded];
            [pw displayIfNeeded];
            NSRect b = pw.contentView.bounds;
            if (b.size.width <= 0 || b.size.height <= 0) continue;
            NSBitmapImageRep *popRep = [pw.contentView bitmapImageRepForCachingDisplayInRect:b];
            if (!popRep) continue;
            [pw.contentView cacheDisplayInRect:b toBitmapImageRep:popRep];
            NSImage *baseImg = [[NSImage alloc] initWithContentsOfFile:path];
            if (baseImg && baseImg.size.width > 0 && baseImg.size.height > 0) {
                CGFloat ptW = baseImg.size.width, ptH = baseImg.size.height;
                NSBitmapImageRep *baseRep = (NSBitmapImageRep *)baseImg.representations.firstObject;
                NSInteger pixW = baseRep.pixelsWide > 0 ? baseRep.pixelsWide : (NSInteger)(ptW * 2);
                NSInteger pixH = baseRep.pixelsHigh > 0 ? baseRep.pixelsHigh : (NSInteger)(ptH * 2);
                NSBitmapImageRep *outRep = [[NSBitmapImageRep alloc]
                    initWithBitmapDataPlanes:NULL pixelsWide:pixW pixelsHigh:pixH
                    bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                    colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
                outRep.size = NSMakeSize(ptW, ptH);
                [NSGraphicsContext saveGraphicsState];
                [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:outRep]];
                [baseImg drawInRect:NSMakeRect(0, 0, ptW, ptH)];
                NSRect popRect = NSMakeRect(pw.frame.origin.x - w.frame.origin.x, pw.frame.origin.y - w.frame.origin.y, b.size.width, b.size.height);
                NSBezierPath *popClip = [NSBezierPath bezierPathWithRoundedRect:popRect xRadius:10.0 yRadius:10.0];
                [NSGraphicsContext saveGraphicsState];
                NSShadow *shadow = [[NSShadow alloc] init];
                shadow.shadowColor = [NSColor colorWithWhite:0.0 alpha:0.32];
                shadow.shadowOffset = NSMakeSize(0, -6);
                shadow.shadowBlurRadius = 18.0;
                [shadow set];
                BOOL isDark = [w.effectiveAppearance.name containsString:@"Dark"];
                [(isDark ? [NSColor colorWithWhite:0.16 alpha:0.96] : [NSColor colorWithWhite:0.97 alpha:0.96]) setFill];
                [popClip fill];
                [NSGraphicsContext restoreGraphicsState];
                [NSGraphicsContext saveGraphicsState];
                [popClip addClip];
                NSImage *popImg = [[NSImage alloc] initWithSize:b.size];
                [popImg addRepresentation:popRep];
                [popImg drawInRect:popRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
                [NSGraphicsContext restoreGraphicsState];
                [[NSColor colorWithWhite:(isDark ? 1.0 : 0.0) alpha:0.18] setStroke];
                popClip.lineWidth = 1.0;
                [popClip stroke];
                [NSGraphicsContext restoreGraphicsState];
                NSData *pngData = [outRep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                [pngData writeToFile:path atomically:YES];
            }
        }
        say([NSString stringWithFormat:@"shot %@ status=%d args=%@", path, t.terminationStatus, [args componentsJoinedByString:@" "]]);
        after(0.2); return;
    }
    if ([cmd isEqualToString:@"menushot"]) { // captures every visible menu window (context menus) as <name>-menuN.png
        NSString *dir = [NSString stringWithUTF8String:getenv("DRIVE_SHOTS") ?: "/tmp"];
        int n = 0;
        for (NSWindow *x in NSApp.windows) {
            if (!x.isVisible || x == mainWin()) continue;
            say([NSString stringWithFormat:@"menushot window %@", NSStringFromClass(x.class)]);
            NSTask *t = [NSTask new]; t.launchPath = @"/usr/sbin/screencapture";
            t.arguments = @[@"-x", @"-o", [NSString stringWithFormat:@"-l%ld", (long)x.windowNumber], [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-menu%d.png", arg, n++]]];
            [t launch]; [t waitUntilExit];
        }
        say([NSString stringWithFormat:@"menushot %@ windows=%d", arg, n]);
        after(0.3); return;
    }
    if ([cmd isEqualToString:@"pick"]) {
        NSString *target = arg; __block int tries = 0;
        NSTimer *t = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
            tries++;
            for (NSWindow *w in NSApp.windows) {
                if ([w isKindOfClass:NSOpenPanel.class] && w.isVisible) {
                    NSOpenPanel *p = (NSOpenPanel *)w;
                    p.directoryURL = [NSURL fileURLWithPath:target isDirectory:YES];
                    [timer invalidate];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ say([NSString stringWithFormat:@"picking %@ url=%@", target, p.URL.path]); if (![p.URL.path hasPrefix:target]) { say(@"pick: wrong url, cancelling"); [NSApp stopModalWithCode:NSModalResponseCancel]; } else [NSApp stopModalWithCode:NSModalResponseOK]; [p orderOut:nil]; });
                    return;
                }
            }
            if (tries == 20) { [timer invalidate]; NSMutableArray *c = [NSMutableArray array]; for (NSWindow *w in NSApp.windows) [c addObject:NSStringFromClass(w.class)]; say([NSString stringWithFormat:@"pick: no open panel; windows=%@", c]); }
        }];
        [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
        [[NSRunLoop mainRunLoop] addTimer:t forMode:NSModalPanelRunLoopMode];
        after(0.1); return;
    }
    if ([cmd isEqualToString:@"goplscount"]) {
        NSTask *task = [NSTask new];
        task.launchPath = @"/bin/sh";
        task.arguments = @[@"-c", [NSString stringWithFormat:@"ps -axo ppid=,command= | awk '$1==%d && $2 ~ /gopls/ && $0 !~ /telemetry/' | wc -l", getpid()]];
        NSPipe *pipe = [NSPipe pipe]; task.standardOutput = pipe; [task launch]; [task waitUntilExit];
        NSString *n = [[NSString alloc] initWithData:[pipe.fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding];
        say([NSString stringWithFormat:@"gopls children: %@", [n stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]]);
        after(0.1); return;
    }
    if ([cmd isEqualToString:@"restartls"]) {
        void (*restart)(void) = (void (*)(void))dlsym(RTLD_DEFAULT, "RestartLanguageServer");
        if (restart) dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ restart(); });
        say([NSString stringWithFormat:@"restartls -> %d", restart != NULL]);
        after(0.1); return;
    }
    if ([cmd isEqualToString:@"guestsh"]) {
        void (*start)(const char *, const char *) = (void (*)(const char *, const char *))dlsym(RTLD_DEFAULT, "StartTerminal");
        void (*write)(const char *, const char *, int) = (void (*)(const char *, const char *, int))dlsym(RTLD_DEFAULT, "WriteTerminal");
        NSString *tid = [NSString stringWithFormat:@"driver-guestsh-%lu", (unsigned long)stepIndex];
        NSString *line = [arg stringByAppendingString:@"; exit\n"];
        const char *cwd = [NSProcessInfo.processInfo.environment[@"DRIVE_GUEST_CWD"] ?: NSHomeDirectory() UTF8String];
        if (start && write) {
            start(tid.UTF8String, cwd);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ write(tid.UTF8String, line.UTF8String, (int)strlen(line.UTF8String)); });
        }
        say([NSString stringWithFormat:@"guestsh %@ -> %d", arg, start && write]);
        after(3.0); return;
    }
    if ([cmd isEqualToString:@"killgopls"]) {
        system([[NSString stringWithFormat:@"pkill -KILL -P %d -f 'gopls serve'", getpid()] UTF8String]);
        say(@"killed gopls");
        after(0.1); return;
    }
    if ([cmd isEqualToString:@"pausegopls"] || [cmd isEqualToString:@"resumegopls"]) { // SIGSTOP / SIGCONT, so requests wait instead of failing
        system([[NSString stringWithFormat:@"pkill -%@ -P %d -f 'gopls serve'", [cmd isEqualToString:@"pausegopls"] ? @"STOP" : @"CONT", getpid()] UTF8String]);
        say(cmd);
        after(0.1); return;
    }
    if ([cmd isEqualToString:@"stubpanel"]) {
        // Open/save panels return OK with this path instead of showing (the macOS 26 panel can't be driven).
        stubURL = [NSURL fileURLWithPath:arg];
        method_setImplementation(class_getInstanceMethod([NSSavePanel class], @selector(runModal)), (IMP)stubRunModal);
        method_setImplementation(class_getInstanceMethod([NSSavePanel class], @selector(URL)), (IMP)stubURLImp);
        method_setImplementation(class_getInstanceMethod([NSOpenPanel class], @selector(URLs)), (IMP)stubURLsImp);
        say([NSString stringWithFormat:@"stubpanel %@", arg]);
        after(0.1); return;
    }
    if ([cmd isEqualToString:@"panelok"]) {
        NSOpenPanel *panel = nil;
        for (NSWindow *w in NSApp.windows) if ([w isKindOfClass:[NSOpenPanel class]] && w.isVisible) panel = (NSOpenPanel *)w;
        panel.directoryURL = [NSURL fileURLWithPath:arg isDirectory:YES];
        say([NSString stringWithFormat:@"panelok %@ -> %d", arg, panel != nil]);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [panel ok:nil]; });
        after(1.5); return;
    }
    if ([cmd isEqualToString:@"askquit"]) { say(@"askquit"); after(1.0); dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; }); return; }
    // ---- smoke-suite assertion steps (print facts; scripts/smoke/run.sh judges them) ----
    if ([cmd isEqualToString:@"time"]) { say([NSString stringWithFormat:@"time %@ %.3f epoch=%.3f", arg, [NSProcessInfo processInfo].systemUptime, NSDate.date.timeIntervalSince1970]); after(0); return; }
    if ([cmd isEqualToString:@"waitlabel"]) { // waitlabel:<text>: pause until a label in the main window or its sheet contains text (max 90 s)
        CFAbsoluteTime begin = CFAbsoluteTimeGetCurrent();
        NSTimer *timer = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            NSMutableArray *acc = [NSMutableArray array]; labelDepth = 30; collectLabels(mainWin(), acc, 0);
            if (mainWin().attachedSheet) collectLabels(mainWin().attachedSheet, acc, 0);
            labelDepth = 12;
            BOOL found = [[acc componentsJoinedByString:@" | "] rangeOfString:arg].location != NSNotFound;
            double secs = CFAbsoluteTimeGetCurrent() - begin;
            if (found || secs > 90) { [t invalidate]; say([NSString stringWithFormat:@"waitlabel '%@' -> %d after %.1f s", arg, found, secs]); after(0.1); }
        }];
        [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
        return;
    }
    if ([cmd isEqualToString:@"waitfile"]) { // pause until the shell creates arg (max 90 s)
        __block int n = 0;
        [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *t) {
            BOOL ok = [NSFileManager.defaultManager fileExistsAtPath:arg];
            if (ok || ++n > 450) { [t invalidate]; say([NSString stringWithFormat:@"waitfile %@ -> %d", arg.lastPathComponent, ok]); after(0.05); }
        }];
        return;
    }
    if ([cmd isEqualToString:@"panelshot"]) { // panelshot:name: each visible popup panel on its own (screencapture -l captures occluded windows)
        NSString *dir = [NSString stringWithUTF8String:getenv("DRIVE_SHOTS") ?: "/tmp"];
        int n = 0;
        for (NSWindow *w in NSApp.windows) {
            if (!w.isVisible || ![NSStringFromClass(w.class) containsString:@"PopupPanel"]) continue;
            NSString *name = n ? [NSString stringWithFormat:@"%@-%d.png", arg, n] : [arg stringByAppendingString:@".png"];
            NSTask *t = [NSTask new];
            t.launchPath = @"/usr/sbin/screencapture";
            t.arguments = @[@"-x", @"-o", [NSString stringWithFormat:@"-l%ld", (long)w.windowNumber], [dir stringByAppendingPathComponent:name]];
            t.environment = @{@"PATH": @"/usr/bin:/bin"};
            [t launch]; [t waitUntilExit];
            n++;
        }
        say([NSString stringWithFormat:@"panelshot %@ -> %d", arg, n]); after(0.2); return;
    }
    if ([cmd isEqualToString:@"underline"]) { // diagnostic underline at the first occurrence of arg: attribute + red pixels drawn under it
        NSRange r = [tv.string rangeOfString:arg];
        if (r.location == NSNotFound) { say([NSString stringWithFormat:@"underline %@ missing", arg]); after(0.1); return; }
        NSLayoutManager *lm = tv.layoutManager;
        id u = [lm temporaryAttributesAtCharacterIndex:r.location effectiveRange:NULL][NSUnderlineStyleAttributeName];
        [tv scrollRangeToVisible:r]; [tv displayIfNeeded];
        NSRect g = [lm boundingRectForGlyphRange:[lm glyphRangeForCharacterRange:r actualCharacterRange:NULL] inTextContainer:tv.textContainer];
        g = NSOffsetRect(g, tv.textContainerOrigin.x, tv.textContainerOrigin.y);
        NSRect band = NSMakeRect(NSMinX(g), NSMaxY(g) - 5, MAX(NSWidth(g), 4), 7);
        NSBitmapImageRep *rep = [tv bitmapImageRepForCachingDisplayInRect:band];
        [tv cacheDisplayInRect:band toBitmapImageRep:rep];
        long red = 0;
        for (NSInteger y = 0; y < rep.pixelsHigh; y++) for (NSInteger x = 0; x < rep.pixelsWide; x++) {
            NSColor *c = [[rep colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
            if (c.redComponent > 0.6 && c.redComponent - c.greenComponent > 0.3 && c.redComponent - c.blueComponent > 0.3) red++;
        }
        say([NSString stringWithFormat:@"underline %@ attr=%d redPixels=%ld", arg, u != nil, red]); after(0.1); return;
    }
    if ([cmd isEqualToString:@"darkmode"]) {
        [NSUserDefaults.standardUserDefaults setObject:@"Dark" forKey:@"AppleInterfaceStyle"];
        [NSDistributedNotificationCenter.defaultCenter postNotificationName:@"AppleInterfaceThemeChangedNotification" object:nil];
        NSAppearance *dark = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        NSApp.appearance = dark;
        for (NSWindow *w in NSApp.windows) { w.appearance = dark; [w.contentView setNeedsDisplay:YES]; }
        [tv setNeedsDisplay:YES];
        say(@"darkmode -> 1"); after(0.6); return;
    }
    if ([cmd isEqualToString:@"lightmode"]) {
        // The app reads AppleInterfaceStyle; removing it falls through to the global "Dark" when the system is dark.
        [NSUserDefaults.standardUserDefaults setObject:@"Light" forKey:@"AppleInterfaceStyle"];
        [NSDistributedNotificationCenter.defaultCenter postNotificationName:@"AppleInterfaceThemeChangedNotification" object:nil];
        NSAppearance *light = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
        NSApp.appearance = light;
        for (NSWindow *w in NSApp.windows) { w.appearance = light; [w.contentView setNeedsDisplay:YES]; }
        [tv setNeedsDisplay:YES];
        say(@"lightmode -> 1"); after(0.6); return;
    }
    if ([cmd isEqualToString:@"sheetshot"]) { // sheetshot:<name>: screenshot of every visible sheet (an alert shown over Settings)
        int n = 0;
        for (NSWindow *w in NSApp.windows) {
            if (!w.isVisible || !w.isSheet) continue;
            activateWindowAndSheetAppearance(w);
            NSString *path = [[NSString stringWithUTF8String:getenv("DRIVE_SHOTS") ?: "/tmp"] stringByAppendingPathComponent:[NSString stringWithFormat:@"%@%@.png", arg, n ? [NSString stringWithFormat:@"-%d", n] : @""]];
            NSTask *t = [NSTask new];
            t.launchPath = @"/usr/sbin/screencapture";
            t.arguments = @[@"-x", @"-o", [NSString stringWithFormat:@"-l%ld", (long)w.windowNumber], path];
            t.environment = @{@"PATH": @"/usr/bin:/bin"};
            [t launch]; [t waitUntilExit];
            if (t.terminationStatus != 0 || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
                NSView *root = w.contentView.superview ?: w.contentView;
                NSBitmapImageRep *rep = [root bitmapImageRepForCachingDisplayInRect:root.bounds];
                [root cacheDisplayInRect:root.bounds toBitmapImageRep:rep];
                [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
                say([NSString stringWithFormat:@"sheetshot %@ drawn in process (screencapture status %d)", arg, t.terminationStatus]);
            }
            n++;
        }
        say([NSString stringWithFormat:@"sheetshot %@ -> %d", arg, n]); after(0.2); return;
    }
    if ([cmd isEqualToString:@"quit"]) {
        say(@"quit");
        for (NSWindow *w in NSApp.windows) {
            if (w.attachedSheet) [w endSheet:w.attachedSheet];
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            _exit(0);
        });
        [NSApp terminate:nil];
        return;
    }
    say([NSString stringWithFormat:@"unknown step %@", step]);
    after(0.1);
}

__attribute__((constructor)) static void start(void) {
    const char *o = getenv("DRIVE_OUT");
    out = o ? fopen(o, "a") : stderr;
    if (!out) out = stderr;
    const char *d = getenv("DRIVE");
    if (!d) return;
    steps = [[NSString stringWithUTF8String:d] componentsSeparatedByString:@";"];
    dispatch_async(dispatch_get_main_queue(), ^{
        @try { [NSApp accessibilitySetValue:@YES forAttribute:@"AXEnhancedUserInterface"]; } @catch (NSException *e) {}
        after(1.0);
    });
}
