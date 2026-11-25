static int labelDepth = 12;
static void collectLabels(id el, NSMutableArray *acc, int depth) {
    if (depth > labelDepth || !el) return;
    if ([el isKindOfClass:NSTextView.class] && [[el accessibilityIdentifier] isEqualToString:@"GoLensConsoleLog"]) {
        // The Console log is one text view; report each line the way separate rows were reported.
        for (NSString *line in [[(NSTextView *)el string] componentsSeparatedByString:@"\n"]) if (line.length) [acc addObject:line];
        return;
    }
    NSString *label = nil;
    @try { label = [el respondsToSelector:@selector(accessibilityLabel)] ? [el accessibilityLabel] : nil; } @catch (NSException *e) {}
    NSString *value = nil;
    @try { id v = [el respondsToSelector:@selector(accessibilityValue)] ? [el accessibilityValue] : nil; if ([v isKindOfClass:NSString.class]) value = v; } @catch (NSException *e) {}
    if (label.length) [acc addObject:value.length ? [NSString stringWithFormat:@"%@ [%@]", label, value] : label];
    else if (value.length && labelDepth > 12 && ![el isKindOfClass:NSTextView.class] && value.length < 400) [acc addObject:value]; // static text exposes its string as the value; skip editors
    NSArray *kids = nil;
    @try { kids = [el respondsToSelector:@selector(accessibilityChildren)] ? [el accessibilityChildren] : nil; } @catch (NSException *e) {}
    for (id k in kids) collectLabels(k, acc, depth + 1);
}

#import <objc/message.h>
static id axAttr(id el, NSString *a) {
    NSDictionary *props = @{NSAccessibilityRoleAttribute: @"accessibilityRole", NSAccessibilityDescriptionAttribute: @"accessibilityLabel", NSAccessibilityTitleAttribute: @"accessibilityTitle", NSAccessibilityValueAttribute: @"accessibilityValue", NSAccessibilityChildrenAttribute: @"accessibilityChildren", NSAccessibilityParentAttribute: @"accessibilityParent"};
    @try {
        SEL sel = NSSelectorFromString(props[a] ?: @"");
        if (props[a] && [el respondsToSelector:sel]) {
            id v = ((id (*)(id, SEL))objc_msgSend)(el, sel);
            if (v && !([v isKindOfClass:NSString.class] && ![v length]) && !([v isKindOfClass:NSArray.class] && ![v count])) return v;
        }
        return [el respondsToSelector:@selector(accessibilityAttributeValue:)] ? [el accessibilityAttributeValue:a] : nil;
    } @catch (NSException *e) { return nil; }
}
static id findAX(id el, NSString *target, int depth) {
    if (depth > 40 || !el) return nil;
    for (NSString *a in @[NSAccessibilityDescriptionAttribute, NSAccessibilityTitleAttribute, NSAccessibilityValueAttribute]) {
        id v = axAttr(el, a);
        if (![v isKindOfClass:NSString.class]) continue;
        // Exact title, or the title followed by a combined badge ("cmd, Modified").
        if ([v caseInsensitiveCompare:target] == NSOrderedSame || [[v lowercaseString] hasPrefix:[[target lowercaseString] stringByAppendingString:@", "]]) return el;
    }
    for (id k in axAttr(el, NSAccessibilityChildrenAttribute)) { id f = findAX(k, target, depth + 1); if (f) return f; }
    return nil;
}
static void collectAXLabelled(id el, NSString *target, int depth, NSMutableArray *out) {
    if (depth > 40 || !el) return;
    for (NSString *a in @[NSAccessibilityDescriptionAttribute, NSAccessibilityTitleAttribute, NSAccessibilityValueAttribute]) {
        id v = axAttr(el, a);
        if (![v isKindOfClass:NSString.class]) continue;
        if ([v caseInsensitiveCompare:target] == NSOrderedSame || [[v lowercaseString] hasPrefix:[[target lowercaseString] stringByAppendingString:@", "]]) { [out addObject:el]; break; }
    }
    for (id k in axAttr(el, NSAccessibilityChildrenAttribute)) collectAXLabelled(k, target, depth + 1, out);
}
static void collectAX(id el, NSString *target, int depth, NSMutableArray *out) {
    if (depth > 40 || !el) return;
    for (NSString *a in @[NSAccessibilityDescriptionAttribute, NSAccessibilityTitleAttribute, NSAccessibilityValueAttribute]) {
        id v = axAttr(el, a);
        if ([v isKindOfClass:NSString.class] && [v caseInsensitiveCompare:target] == NSOrderedSame) { [out addObject:el]; break; }
    }
    for (id k in axAttr(el, NSAccessibilityChildrenAttribute)) collectAX(k, target, depth + 1, out);
}
static id findAXDeepest(id el, NSString *target, int depth) {
    if (depth > 40 || !el) return nil;
    for (id k in axAttr(el, NSAccessibilityChildrenAttribute)) { id f = findAXDeepest(k, target, depth + 1); if (f) return f; }
    for (NSString *a in @[NSAccessibilityDescriptionAttribute, NSAccessibilityTitleAttribute, NSAccessibilityValueAttribute]) {
        id v = axAttr(el, a);
        if ([v isKindOfClass:NSString.class] && [v caseInsensitiveCompare:target] == NSOrderedSame) return el;
    }
    return nil;
}
static id findAXButtonContaining(id el, NSString *target, int depth) {
    if (depth > 40 || !el) return nil;
    if ([axAttr(el, NSAccessibilityRoleAttribute) isEqual:NSAccessibilityButtonRole]) {
        for (NSString *a in @[NSAccessibilityDescriptionAttribute, NSAccessibilityTitleAttribute]) {
            id v = axAttr(el, a);
            if ([v isKindOfClass:NSString.class] && [v containsString:target]) return el;
        }
    }
    for (id k in axAttr(el, NSAccessibilityChildrenAttribute)) { id f = findAXButtonContaining(k, target, depth + 1); if (f) return f; }
    return nil;
}
static BOOL axActivate(id el) {
    for (id e = el; e && ![e isKindOfClass:NSWindow.class]; e = axAttr(e, NSAccessibilityParentAttribute)) {
        if ([axAttr(e, NSAccessibilityRoleAttribute) isEqual:NSAccessibilityRowRole]) { [e accessibilitySetValue:@YES forAttribute:NSAccessibilitySelectedAttribute]; return YES; }
        if ([e respondsToSelector:@selector(accessibilityPerformPress)] && [e accessibilityPerformPress]) return YES;
        if ([e respondsToSelector:@selector(accessibilityActionNames)] && [[e accessibilityActionNames] containsObject:NSAccessibilityPressAction]) { [e accessibilityPerformAction:NSAccessibilityPressAction]; return YES; }
    }
    return NO;
}

static void updateMenuForInspection(NSMenu *menu) {
    if (!menu) return;
    id<NSMenuDelegate> del = menu.delegate;
    if ([del respondsToSelector:@selector(menuNeedsUpdate:)]) [del menuNeedsUpdate:menu];
    if ([del respondsToSelector:@selector(menuWillOpen:)]) [del menuWillOpen:menu];
    [menu update];
    if ([del respondsToSelector:@selector(menuDidClose:)]) [del menuDidClose:menu];
}

static NSMenuItem *findMenuItemRecursive(NSMenu *menu, NSString *title) {
    if (!menu || !title.length) return nil;
    updateMenuForInspection(menu);
    NSMenuItem *direct = [menu itemWithTitle:title];
    if (direct && !direct.submenu) return direct;
    for (NSMenuItem *it in menu.itemArray) {
        if (it.submenu) {
            NSMenuItem *found = findMenuItemRecursive(it.submenu, title);
            if (found) return found;
        }
    }
    return direct;
}

static NSMenuItem *resolveMenuPath(NSString *arg) {
    NSArray<NSString *> *parts = [arg componentsSeparatedByString:@"/"];
    NSMenu *m = NSApp.mainMenu;
    NSMenuItem *item = nil;
    for (NSUInteger pi = 0; pi < parts.count; pi++) {
        if (!m) break;
        updateMenuForInspection(m);
        NSString *rem = [[parts subarrayWithRange:NSMakeRange(pi, parts.count - pi)] componentsJoinedByString:@"/"];
        NSMenuItem *direct = [m itemWithTitle:rem];
        if (direct && !direct.submenu) {
            item = direct;
            break;
        }
        NSMenuItem *stepItem = [m itemWithTitle:parts[pi]];
        if (stepItem && stepItem.submenu && pi + 1 < parts.count) {
            item = stepItem;
            m = stepItem.submenu;
            continue;
        }
        if (stepItem && !stepItem.submenu && pi + 1 == parts.count) {
            item = stepItem;
            break;
        }
        NSMenuItem *rec = findMenuItemRecursive(m, rem);
        if (rec) {
            item = rec;
            break;
        }
        item = nil;
        break;
    }
    if (item && item.menu) {
        updateMenuForInspection(item.menu);
    }
    return item;
}

static void dumpMenuItemsRecursive(NSString *topTitle, NSMenu *menu) {
    if (!menu) return;
    updateMenuForInspection(menu);
    for (NSMenuItem *it in menu.itemArray) {
        if (it.isSeparatorItem || !it.title.length) continue;
        say([NSString stringWithFormat:@"menuitem %@ / %@ key=%@ mods=%lu enabled=%d", topTitle, it.title, it.keyEquivalent, (unsigned long)it.keyEquivalentModifierMask, it.isEnabled]);
        if (it.submenu) {
            dumpMenuItemsRecursive(topTitle, it.submenu);
        }
    }
}

static void compositeAttachedSheetIfNeeded(NSWindow *w, NSString *path) {
    if (!w.attachedSheet || !w.attachedSheet.isVisible) return;
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

        [NSGraphicsContext saveGraphicsState];
        NSShadow *shadow = [[NSShadow alloc] init];
        shadow.shadowColor = [NSColor colorWithWhite:0.0 alpha:0.28];
        shadow.shadowOffset = NSMakeSize(0, -10);
        shadow.shadowBlurRadius = 32.0;
        [shadow set];
        [[NSColor colorWithWhite:1.0 alpha:0.02] setFill];
        [sheetClip fill];
        [NSGraphicsContext restoreGraphicsState];

        [NSGraphicsContext saveGraphicsState];
        [sheetClip addClip];
        [sheetImg drawInRect:sheetRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:0.96];
        [NSGraphicsContext restoreGraphicsState];

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

static void dispatchAXStep(NSString *cmd, NSString *arg, NSTextView *tv, BOOL *handled) {
    if ([cmd isEqualToString:@"submenu"]) { *handled = YES;
        NSMenu *m = NSApp.mainMenu; NSMenuItem *item = nil;
        for (NSString *part in [arg componentsSeparatedByString:@"/"]) { updateMenuForInspection(m); item = [m itemWithTitle:part]; m = item.submenu; if (!item) break; }
        updateMenuForInspection(m);
        for (NSMenuItem *it in m.itemArray) say([NSString stringWithFormat:@"submenu %@ / %@ enabled=%d", arg, it.isSeparatorItem ? @"---" : it.title, it.isEnabled]);
        after(0.1); return;
    }
    if ([cmd isEqualToString:@"menudump"]) { *handled = YES;
        for (NSMenuItem *top in NSApp.mainMenu.itemArray) {
            dumpMenuItemsRecursive(top.title, top.submenu);
        }
        after(0.1); return;
    }
    if ([cmd isEqualToString:@"rowexpand"]) { *handled = YES;
        // Select a navigator folder through accessibility, then → expands it (a click only selects a folder).
        id el = nil;
        for (NSWindow *w in NSApp.windows) if (w.isVisible && !el) el = findAX(w, arg, 0);
        BOOL ok = el && axActivate(el);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSMutableArray *stack = [NSMutableArray arrayWithObject:mainWin().contentView]; NSOutlineView *ov = nil;
            while (stack.count && !ov) { NSView *v = stack.lastObject; [stack removeLastObject];
                if (v.isHiddenOrHasHiddenAncestor) continue;
                if ([v isKindOfClass:[NSOutlineView class]]) ov = (NSOutlineView *)v; else [stack addObjectsFromArray:v.subviews]; }
            NSString *right = [NSString stringWithFormat:@"%C", (unichar)NSRightArrowFunctionKey];
            NSEvent *e = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagFunction | NSEventModifierFlagNumericPad timestamp:[[NSProcessInfo processInfo] systemUptime] windowNumber:mainWin().windowNumber context:nil characters:right charactersIgnoringModifiers:right isARepeat:NO keyCode:124];
            [mainWin() makeFirstResponder:ov];
            [ov keyDown:e];
        });
        say([NSString stringWithFormat:@"rowexpand %@ ok=%d", arg, ok]);
        after(1.2); return;
    }
    if ([cmd isEqualToString:@"rowcollapse"]) { *handled = YES; // rowcollapse:<label>: select the outline row through accessibility, then ← collapses it
        id el = nil;
        for (NSWindow *w in NSApp.windows) if (w.isVisible && !el) el = findAX(w, arg, 0);
        BOOL ok = el && axActivate(el);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSMutableArray *stack = [NSMutableArray arrayWithObject:mainWin().contentView]; NSOutlineView *ov = nil;
            while (stack.count && !ov) { NSView *v = stack.lastObject; [stack removeLastObject];
                if (v.isHiddenOrHasHiddenAncestor) continue;
                if ([v isKindOfClass:[NSOutlineView class]]) ov = (NSOutlineView *)v; else [stack addObjectsFromArray:v.subviews]; }
            NSString *left = [NSString stringWithFormat:@"%C", (unichar)NSLeftArrowFunctionKey];
            NSEvent *e = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagFunction | NSEventModifierFlagNumericPad timestamp:[[NSProcessInfo processInfo] systemUptime] windowNumber:mainWin().windowNumber context:nil characters:left charactersIgnoringModifiers:left isARepeat:NO keyCode:123];
            [mainWin() makeFirstResponder:ov];
            [ov keyDown:e];
        });
        say([NSString stringWithFormat:@"rowcollapse %@ ok=%d", arg, ok]);
        after(1.2); return;
    }
    if ([cmd isEqualToString:@"axpress"]) { *handled = YES; // a sheet title and its primary button can share a label: try each match in tree order until one is pressable
        NSMutableArray *matches = [NSMutableArray array];
        for (NSWindow *w in NSApp.windows) if (w.isVisible) collectAXLabelled(w, arg, 0, matches);
        id el = matches.firstObject;
        BOOL ok = NO;
        for (id m in matches) if (axActivate(m)) { el = m; ok = YES; break; }
        say([NSString stringWithFormat:@"axpress %@ -> %@ ok=%d", arg, el ? NSStringFromClass([el class]) : @"none", ok]);
        after(0.8); return;
    }
    if ([cmd isEqualToString:@"winlabels"]) { *handled = YES; // winlabels:<window>: deep labels and values of the window whose title, autosave name or identifier contains <window>
        NSMutableArray *acc = [NSMutableArray array]; labelDepth = 30; collectLabels(windowLike(arg), acc, 0); labelDepth = 12;
        say([NSString stringWithFormat:@"winlabels: %@", [acc componentsJoinedByString:@" | "]]); after(0.1); return;
    }
    if ([cmd isEqualToString:@"winwaitlabel"]) { *handled = YES; // winwaitlabel:<window>|<text>: pause until a label in that window contains text (max 120 s)
        NSArray *parts = [arg componentsSeparatedByString:@"|"];
        if (parts.count < 2) { say(@"winwaitlabel: expected window|text"); after(0.1); return; }
        NSString *name = parts[0], *text = [[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] componentsJoinedByString:@"|"];
        CFAbsoluteTime begin = CFAbsoluteTimeGetCurrent();
        NSTimer *timer = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            NSWindow *w = windowLike(name);
            NSMutableArray *acc = [NSMutableArray array]; labelDepth = 30; if (w) collectLabels(w, acc, 0); labelDepth = 12;
            BOOL found = [[acc componentsJoinedByString:@" | "] rangeOfString:text].location != NSNotFound;
            double secs = CFAbsoluteTimeGetCurrent() - begin;
            if (found || secs > 120) { [t invalidate]; say([NSString stringWithFormat:@"winwaitlabel '%@' -> %d after %.1f s", text, found, secs]); after(0.1); }
        }];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
        return;
    }
    if ([cmd isEqualToString:@"wintable"]) { *handled = YES; // wintable:<window>: labels and values of the visible rows of every table or list in that window, which the accessibility walk of winlabels does not reach
        NSWindow *w = windowLike(arg); NSMutableArray *acc = [NSMutableArray array];
        NSMutableArray *stack = w.contentView ? [NSMutableArray arrayWithObject:w.contentView] : [NSMutableArray array];
        labelDepth = 30;
        while (stack.count) { NSView *v = stack.lastObject; [stack removeLastObject];
            if (v.isHiddenOrHasHiddenAncestor) continue;
            if ([v isKindOfClass:NSTableView.class]) { NSTableView *tv = (NSTableView *)v; NSRange rows = [tv rowsInRect:tv.visibleRect];
                for (NSUInteger r = rows.location; r < NSMaxRange(rows); r++) { NSTableRowView *rv = [tv rowViewAtRow:(NSInteger)r makeIfNecessary:NO]; if (rv) collectLabels(rv, acc, 0); }
                continue; }
            [stack addObjectsFromArray:v.subviews]; }
        labelDepth = 12;
        say([NSString stringWithFormat:@"wintable: %@", [acc componentsJoinedByString:@" | "]]); after(0.1); return;
    }
    if ([cmd isEqualToString:@"winexists"]) { *handled = YES; // winexists:<window>|<label>: whether an element with that label exists inside that window only
        NSArray *parts = [arg componentsSeparatedByString:@"|"];
        NSWindow *w = windowLike(parts[0]);
        id el = (w && parts.count > 1) ? findAX(w, parts[1], 0) : nil;
        say([NSString stringWithFormat:@"winexists %@ -> %d", arg, el != nil]); after(0.1); return;
    }
    if ([cmd isEqualToString:@"winpress"]) { *handled = YES; // winpress:<window>|<label>: press the element with that label inside that window only
        NSArray *parts = [arg componentsSeparatedByString:@"|"];
        NSWindow *w = windowLike(parts[0]);
        id el = nil;
        if (w && parts.count > 1) {
            if (w.attachedSheet && w.attachedSheet.isVisible) el = findAX(w.attachedSheet, parts[1], 0);
            if (!el) el = findAX(w, parts[1], 0);
        }
        BOOL ok = el && axActivate(el);
        say([NSString stringWithFormat:@"winpress %@ -> %@ ok=%d", arg, el ? NSStringFromClass([el class]) : @"none", ok]);
        after(0.8); return;
    }
    if ([cmd isEqualToString:@"winshot"]) { *handled = YES; // winshot:<window>|<name>: screenshot of that window
        NSArray *parts = [arg componentsSeparatedByString:@"|"];
        NSWindow *w = windowLike(parts[0]);
        if (w && parts.count > 1) {
            activateWindowAndSheetAppearance(w);
            NSString *path = [[NSString stringWithUTF8String:getenv("DRIVE_SHOTS") ?: "/tmp"] stringByAppendingPathComponent:[parts[1] stringByAppendingString:@".png"]];
            NSTask *t = [NSTask new];
            t.launchPath = @"/usr/sbin/screencapture";
            t.arguments = @[@"-x", @"-o", [NSString stringWithFormat:@"-l%ld", (long)w.windowNumber], path];
            t.environment = @{@"PATH": @"/usr/bin:/bin"};
            [t launch]; [t waitUntilExit];
            compositeAttachedSheetIfNeeded(w, path);
            say([NSString stringWithFormat:@"winshot %@ status=%d", path, t.terminationStatus]);
        } else say([NSString stringWithFormat:@"winshot %@ -> no window", arg]);
        after(0.2); return;
    }
    if ([cmd isEqualToString:@"wintoggle"]) { *handled = YES; // wintoggle:<window>|<label>: click the checkbox or switch with that accessibility label in that window (SwiftUI toggles do not take AXPress)
        NSArray *parts = [arg componentsSeparatedByString:@"|"];
        NSWindow *w = windowLike(parts[0]);
        NSControl *hit = nil; NSMutableArray *seen = [NSMutableArray array];
        NSMutableArray *stack = w ? [NSMutableArray arrayWithObject:w.contentView.superview ?: w.contentView] : [NSMutableArray array];
        while (stack.count && !hit) {
            NSView *v = stack.lastObject; [stack removeLastObject];
            if ([v isKindOfClass:NSControl.class] && ![v isKindOfClass:NSTextField.class]) {
                NSString *l = v.accessibilityLabel ?: @"";
                if ([l isEqualToString:parts[1]]) hit = (NSControl *)v; else if (l.length) [seen addObject:[NSString stringWithFormat:@"%@:%@", NSStringFromClass(v.class), l]];
            }
            [stack addObjectsFromArray:v.subviews];
        }
        if (hit) [hit performClick:nil];
        say([NSString stringWithFormat:@"wintoggle %@ -> %@ (controls: %@)", arg, hit ? NSStringFromClass(hit.class) : @"none", hit ? @"" : [seen componentsJoinedByString:@", "]]);
        after(0.8); return;
    }
    if ([cmd isEqualToString:@"fieldl"]) { *handled = YES; // fieldl:<window>|<label>|<text>: fill the text field with that accessibility label and press Return
        NSArray *parts = [arg componentsSeparatedByString:@"|"];
        NSWindow *w = windowLike(parts[0]);
        NSTextField *f = nil; NSMutableArray *seen = [NSMutableArray array];
        NSMutableArray *stack = w && parts.count > 2 ? [NSMutableArray arrayWithObject:w.contentView.superview ?: w.contentView] : [NSMutableArray array];
        while (stack.count && !f) {
            NSView *v = stack.lastObject; [stack removeLastObject];
            if ([v isKindOfClass:NSTextField.class] && ((NSTextField *)v).isEditable) {
                if ([v.accessibilityLabel isEqualToString:parts[1]]) f = (NSTextField *)v; else [seen addObject:[NSString stringWithFormat:@"%@:%@", NSStringFromClass(v.class), v.accessibilityLabel ?: @""]];
            }
            [stack addObjectsFromArray:v.subviews];
        }
        if (f) {
            [f.window makeFirstResponder:f];
            NSText *ed = [f.window fieldEditor:YES forObject:f];
            [ed selectAll:nil];
            [ed insertText:parts[2]];
            if (!(parts.count > 3 && [parts[3] isEqualToString:@"noreturn"])) [ed doCommandBySelector:@selector(insertNewline:)];
        }
        say([NSString stringWithFormat:@"fieldl %@ -> %@ %@", parts[1], f ? @"ok" : @"none", f ? @"" : [seen componentsJoinedByString:@", "]]);
        after(0.6); return;
    }
    if ([cmd isEqualToString:@"winsize"]) { *handled = YES; // winsize:<window>|<height>[|<width>]: resize that window, keeping its top-left edge
        NSArray<NSString *> *parts = [arg componentsSeparatedByString:@"|"];
        NSWindow *w = parts.firstObject.length ? windowLike(parts[0]) : mainWin();
        if (w && parts.count > 1) {
            NSRect f = w.frame;
            CGFloat h = [parts[1] doubleValue];
            if (h > 0) { f.origin.y += f.size.height - h; f.size.height = h; }
            if (parts.count > 2 && [parts[2] doubleValue] > 0) { f.size.width = [parts[2] doubleValue]; }
            [w setFrame:f display:YES];
        }
        say([NSString stringWithFormat:@"winsize %@ -> %d", arg, w != nil]); after(0.8); return;
    }
    if ([cmd isEqualToString:@"winscrollend"]) { *handled = YES; // winscrollend:<window>: scroll the tallest scroll view of that window to its bottom
        NSWindow *w = windowLike(arg);
        NSScrollView *best = nil;
        NSMutableArray *stack = w ? [NSMutableArray arrayWithObject:w.contentView.superview ?: w.contentView] : [NSMutableArray array];
        while (stack.count) {
            NSView *v = stack.lastObject; [stack removeLastObject];
            if ([v isKindOfClass:NSScrollView.class] && ((NSScrollView *)v).documentView.bounds.size.height > best.documentView.bounds.size.height) best = (NSScrollView *)v;
            [stack addObjectsFromArray:v.subviews];
        }
        if (best) { NSView *d = best.documentView; [d scrollPoint:d.isFlipped ? NSMakePoint(0, MAX(0, d.bounds.size.height - best.contentSize.height)) : NSZeroPoint]; }
        say([NSString stringWithFormat:@"winscrollend %@ -> %d", arg, best != nil]); after(0.8); return;
    }
    if ([cmd isEqualToString:@"winwheel"]) { *handled = YES; // winwheel:<window>|<dy>: dispatch real pixel scrollWheel events at the center of the multi-column table in that window
        NSArray<NSString *> *parts = [arg componentsSeparatedByString:@"|"];
        NSWindow *w = windowLike(parts.firstObject ?: @"");
        int32_t dy = parts.count > 1 ? [parts[1] intValue] : -45;
        NSTableView *targetTable = nil;
        NSMutableArray *stack = w ? [NSMutableArray arrayWithObject:w.contentView.superview ?: w.contentView] : [NSMutableArray array];
        while (stack.count) {
            NSView *v = stack.lastObject; [stack removeLastObject];
            if ([v isKindOfClass:NSTableView.class] && ((NSTableView *)v).tableColumns.count >= 2) {
                targetTable = (NSTableView *)v;
                break;
            }
            [stack addObjectsFromArray:v.subviews];
        }
        NSScrollView *sv = targetTable.enclosingScrollView;
        CGFloat beforeY = sv ? sv.contentView.bounds.origin.y : -1;
        NSView *hit = nil;
        if (w && sv) {
            NSRect visInWin = [sv convertRect:sv.bounds toView:nil];
            NSPoint midInWin = NSMakePoint(NSMidX(visInWin), NSMidY(visInWin));
            NSView *root = w.contentView.superview ?: w.contentView;
            hit = [root hitTest:midInWin] ?: targetTable;
            CGPoint cgLoc = [w convertPointToScreen:midInWin];
            for (int i = 0; i < 8; i++) {
                CGEventRef cg = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 1, dy);
                if (cg) {
                    CGEventSetLocation(cg, cgLoc);
                    NSEvent *ev = [NSEvent eventWithCGEvent:cg];
                    CFRelease(cg);
                    if (ev) [hit scrollWheel:ev];
                }
            }
        }
        CGFloat afterY = sv ? sv.contentView.bounds.origin.y : -1;
        say([NSString stringWithFormat:@"winwheel %@ -> hit=%@ beforeY=%.1f afterY=%.1f", arg, hit ? NSStringFromClass(hit.class) : @"none", beforeY, afterY]);
        after(0.6); return;
    }
    if ([cmd isEqualToString:@"winclose"]) { *handled = YES; // winclose:<window>
        NSWindow *w = windowLike(arg); [w performClose:nil];
        say([NSString stringWithFormat:@"winclose %@ -> %d", arg, w != nil]); after(0.6); return;
    }
    if ([cmd isEqualToString:@"axpresslast"]) { *handled = YES; // axpresslast:<label>: presses the last element with that label in tree order
        NSMutableArray *hits = [NSMutableArray array];
        for (NSWindow *w in NSApp.windows) if (w.isVisible) collectAX(w, arg, 0, hits);
        id el = hits.lastObject;
        BOOL ok = el && axActivate(el);
        say([NSString stringWithFormat:@"axpresslast %@ (%lu matches) -> %@ ok=%d", arg, (unsigned long)hits.count, el ? NSStringFromClass([el class]) : @"none", ok]);
        after(0.8); return;
    }
    if ([cmd isEqualToString:@"axpressdeep"]) { *handled = YES; // axpressdeep:<label>: presses the deepest element with that label (a SwiftUI button inside a toolbar item)
        id el = nil;
        for (NSWindow *w in NSApp.windows) if (w.isVisible && !el) el = findAXDeepest(w, arg, 0);
        BOOL ok = el && axActivate(el);
        say([NSString stringWithFormat:@"axpressdeep %@ -> %@ ok=%d", arg, el ? NSStringFromClass([el class]) : @"none", ok]);
        after(0.8); return;
    }
    if ([cmd isEqualToString:@"axclick"]) { *handled = YES; // axclick:<label>: a left click at the centre of the element with that label (toolbar items)
        id el = nil; NSWindow *hit = nil;
        for (NSWindow *w in NSApp.windows) if (w.isVisible && !el) { el = findAX(w, arg, 0); if (el) hit = w; }
        NSRect frame = el && [el respondsToSelector:@selector(accessibilityFrame)] ? [el accessibilityFrame] : NSZeroRect;
        if (el && hit && !NSIsEmptyRect(frame)) {
            NSPoint p = [hit convertPointFromScreen:NSMakePoint(NSMidX(frame), NSMidY(frame))];
            for (NSNumber *type in @[@(NSEventTypeLeftMouseDown), @(NSEventTypeLeftMouseUp)]) {
                NSEvent *e = [NSEvent mouseEventWithType:(NSEventType)type.integerValue location:p modifierFlags:0 timestamp:[[NSProcessInfo processInfo] systemUptime] windowNumber:hit.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
                [NSApp postEvent:e atStart:NO];
            }
        }
        say([NSString stringWithFormat:@"axclick %@ -> %@ frame=%@", arg, el ? NSStringFromClass([el class]) : @"none", NSStringFromRect(frame)]);
        after(0.8); return;
    }
    if ([cmd isEqualToString:@"menu"]) { *handled = YES;
        NSMenuItem *item = resolveMenuPath(arg);
        BOOL valid = item && (!item.target || ![item.target respondsToSelector:@selector(validateMenuItem:)] || [item.target validateMenuItem:item]);
        say([NSString stringWithFormat:@"menu %@ isEnabled=%d validate=%d action=%@ target=%@", arg, item.isEnabled, valid, NSStringFromSelector(item.action), NSStringFromClass([item.target class])]);
        if (item) { [item.menu performActionForItemAtIndex:[item.menu indexOfItem:item]]; say([NSString stringWithFormat:@"menu %@ (key %@ mods %lu)", arg, item.keyEquivalent, (unsigned long)item.keyEquivalentModifierMask]); }
        else say([NSString stringWithFormat:@"menu %@ %@", arg, item ? [NSString stringWithFormat:@"disabled (key %@ mods %lu)", item.keyEquivalent, (unsigned long)item.keyEquivalentModifierMask] : @"missing"]);
        after(0.5); return;
    }
    if ([cmd isEqualToString:@"labels"]) { *handled = YES;
        NSMutableArray *acc = [NSMutableArray array];
        NSWindow *w = nil; for (NSWindow *x in NSApp.windows) if (x.isVisible && x.isSheet) w = x; if (!w) w = mainWin();
        collectLabels(w, acc, 0);
        say([NSString stringWithFormat:@"labels(%@): %@", w.title, [acc componentsJoinedByString:@" | "]]);
        after(0.1); return;
    }
    if ([cmd isEqualToString:@"axmenu"]) { *handled = YES; // axmenu:<label>: AXShowMenu on the element or its nearest ancestor that has one
        id el = nil;
        for (NSWindow *w in NSApp.windows) if (w.isVisible && !el) el = findAX(w, arg, 0);
        id target = el;
        while (target && ![target isKindOfClass:NSWindow.class] && !([target respondsToSelector:@selector(accessibilityActionNames)] && [[target accessibilityActionNames] containsObject:NSAccessibilityShowMenuAction])) target = axAttr(target, NSAccessibilityParentAttribute);
        say([NSString stringWithFormat:@"axmenu %@ -> %@ / %@", arg, el ? NSStringFromClass([el class]) : @"none", target ? NSStringFromClass([target class]) : @"none"]);
        if (target && ![target isKindOfClass:NSWindow.class]) dispatch_async(dispatch_get_main_queue(), ^{ [target accessibilityPerformAction:NSAccessibilityShowMenuAction]; });
        after(1.0); return;
    }
    if ([cmd isEqualToString:@"rowmenu"]) { *handled = YES; // rowmenu:<label>|<item>[/<subitem>]: the context menu of the element titled label; lists it and performs item, or subitem of its submenu
        NSRange bar = [arg rangeOfString:@"|"];
        NSString *label = bar.location == NSNotFound ? arg : [arg substringToIndex:bar.location];
        NSString *item = bar.location == NSNotFound ? nil : [arg substringFromIndex:bar.location + 1];
        NSWindow *w = nil; id el = nil;
        for (NSWindow *x in NSApp.windows) if (x.isVisible && !el) { el = findAX(x, label, 0); w = x; }
        if (!el || ![el respondsToSelector:@selector(accessibilityFrame)]) { say([NSString stringWithFormat:@"rowmenu %@ missing", label]); after(0.2); return; }
        NSRect f = [el accessibilityFrame];
        NSPoint loc = [w convertPointFromScreen:NSMakePoint(NSMidX(f), NSMidY(f))];
        NSEvent *e = [NSEvent mouseEventWithType:NSEventTypeRightMouseDown location:loc modifierFlags:0 timestamp:[[NSProcessInfo processInfo] systemUptime] windowNumber:w.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
        NSView *v = [w.contentView.superview hitTest:loc];
        NSMenu *menu = nil; NSView *owner = v;
        while (owner && !(menu = [owner menuForEvent:e])) owner = owner.superview;
        [menu update];
        NSRange slash = item ? [item rangeOfString:@"/"] : NSMakeRange(NSNotFound, 0);
        NSString *top = slash.location == NSNotFound ? item : [item substringToIndex:slash.location];
        NSString *sub = slash.location == NSNotFound ? nil : [item substringFromIndex:slash.location + 1];
        NSInteger found = -1;
        for (NSInteger i = 0; i < menu.numberOfItems; i++) {
            NSMenuItem *it = [menu itemAtIndex:i];
            say([NSString stringWithFormat:@"rowmenu item %@ enabled=%d", it.isSeparatorItem ? @"—" : it.title, it.isEnabled]);
            if (top && [it.title isEqualToString:top]) found = i;
        }
        NSMenu *target = menu;
        if (sub && found >= 0 && [menu itemAtIndex:found].submenu) {
            target = [menu itemAtIndex:found].submenu;
            [target update];
            found = -1;
            for (NSInteger i = 0; i < target.numberOfItems; i++) {
                NSMenuItem *it = [target itemAtIndex:i];
                say([NSString stringWithFormat:@"rowmenu subitem %@ enabled=%d", it.title, it.isEnabled]);
                if ([it.title isEqualToString:sub]) found = i;
            }
        }
        say([NSString stringWithFormat:@"rowmenu %@ items=%ld perform=%@ -> %ld", label, (long)menu.numberOfItems, item ?: @"", (long)found]);
        // A shown menu ends with didCloseMenu:withEvent:, which removes the table's menu highlight overlay; without it later clicks land on the overlay
        if (menu) dispatch_async(dispatch_get_main_queue(), ^{
            [owner didCloseMenu:menu withEvent:e];
            if (found >= 0) [target performActionForItemAtIndex:found];
        });
        after(1.0); return;
    }
    if ([cmd isEqualToString:@"popupselect"]) { *handled = YES; // popupselect:<label or #N>|<item>: picks item in the pop-up button with that accessibility label (or the Nth from the top, sheets first)
        NSRange bar = [arg rangeOfString:@"|"];
        NSString *label = bar.location == NSNotFound ? arg : [arg substringToIndex:bar.location];
        NSString *item = bar.location == NSNotFound ? @"" : [arg substringFromIndex:bar.location + 1];
        NSMutableArray *buttons = [NSMutableArray array];
        NSArray *windows = [NSApp.windows sortedArrayUsingComparator:^NSComparisonResult(NSWindow *a, NSWindow *b) { return a.isSheet == b.isSheet ? NSOrderedSame : (a.isSheet ? NSOrderedAscending : NSOrderedDescending); }];
        for (NSWindow *w in windows) {
            if (!w.isVisible) continue;
            NSMutableArray *found = [NSMutableArray array];
            NSMutableArray *stack = [NSMutableArray arrayWithObject:w.contentView.superview ?: w.contentView];
            while (stack.count) { NSView *v = stack.lastObject; [stack removeLastObject];
                if ([v isKindOfClass:NSPopUpButton.class] && !v.isHiddenOrHasHiddenAncestor) [found addObject:v];
                [stack addObjectsFromArray:v.subviews]; }
            [found sortUsingComparator:^NSComparisonResult(NSView *a, NSView *b) {
                CGFloat ya = [a convertPoint:NSZeroPoint toView:nil].y, yb = [b convertPoint:NSZeroPoint toView:nil].y;
                return ya > yb ? NSOrderedAscending : (ya < yb ? NSOrderedDescending : NSOrderedSame);
            }];
            [buttons addObjectsFromArray:found];
        }
        NSPopUpButton *pb = nil;
        if ([label hasPrefix:@"#"]) {
            NSInteger n = [[label substringFromIndex:1] integerValue];
            if (n >= 0 && n < (NSInteger)buttons.count) pb = buttons[n];
        } else {
            for (NSPopUpButton *b in buttons) {
                NSString *l = nil; id ax = b;
                for (int up = 0; up < 4 && ax && !pb; up++) {
                    @try { l = [ax respondsToSelector:@selector(accessibilityLabel)] ? [ax accessibilityLabel] : nil; } @catch (NSException *e) {}
                    if ([l isEqualToString:label] || [l hasSuffix:[@", " stringByAppendingString:label]]) pb = b;
                    ax = [ax respondsToSelector:@selector(superview)] ? [(NSView *)ax superview] : nil;
                }
                if (pb) break;
            }
        }
        if (pb) {
            NSInteger idx = [pb indexOfItemWithTitle:item];
            BOOL ok = idx >= 0;
            if (ok) { [pb selectItemAtIndex:idx]; [pb.menu performActionForItemAtIndex:idx]; }
            say([NSString stringWithFormat:@"popupselect %@ -> %@ ok=%d of %lu", label, item, ok, (unsigned long)buttons.count]);
        } else {
            NSMutableArray *titles = [NSMutableArray array];
            for (NSPopUpButton *b in buttons) [titles addObject:[NSString stringWithFormat:@"%@/%@", b.titleOfSelectedItem ?: @"", [b accessibilityLabel] ?: @""]];
            say([NSString stringWithFormat:@"popupselect %@ missing; pop-ups: %@", label, [titles componentsJoinedByString:@", "]]);
        }
        after(0.4); return;
    }
    if ([cmd isEqualToString:@"axtext"]) { *handled = YES; // axtext:<label>|<text>: replace the text of the text view with that accessibility label (a SwiftUI TextEditor)
        NSRange bar = [arg rangeOfString:@"|"];
        NSString *label = bar.location == NSNotFound ? arg : [arg substringToIndex:bar.location];
        NSString *text = bar.location == NSNotFound ? @"" : [[arg substringFromIndex:bar.location + 1] stringByReplacingOccurrencesOfString:@"\\t" withString:@"\t"];
        NSTextView *found = nil;
        for (NSWindow *w in NSApp.windows) {
            if (!w.isVisible || found) continue;
            NSMutableArray *stack = [NSMutableArray arrayWithObject:w.contentView.superview ?: w.contentView];
            while (stack.count && !found) { NSView *v = stack.lastObject; [stack removeLastObject];
                if ([v isKindOfClass:NSTextView.class] && ((NSTextView *)v).isEditable) {
                    id ax = v;
                    for (int up = 0; up < 5 && ax && !found; up++) {
                        NSString *l = nil;
                        @try { l = [ax respondsToSelector:@selector(accessibilityLabel)] ? [ax accessibilityLabel] : nil; } @catch (NSException *e) {}
                        if ([l isEqualToString:label] || [l hasSuffix:[@", " stringByAppendingString:label]]) found = (NSTextView *)v;
                        ax = [ax respondsToSelector:@selector(superview)] ? [(NSView *)ax superview] : nil;
                    }
                }
                [stack addObjectsFromArray:v.subviews]; }
        }
        if (found) { [found.window makeFirstResponder:found]; [found selectAll:nil]; [found insertText:text replacementRange:found.selectedRange]; }
        say([NSString stringWithFormat:@"axtext %@ -> %@", label, found ? @"ok" : @"none"]);
        after(0.4); return;
    }
    if ([cmd isEqualToString:@"outline"]) { *handled = YES;
        NSMutableArray *stack = [NSMutableArray arrayWithObject:mainWin().contentView]; NSOutlineView *ov = nil;
        while (stack.count && !ov) { NSView *v = stack.lastObject; [stack removeLastObject];
            if (v.isHiddenOrHasHiddenAncestor) continue;
            if ([v isKindOfClass:[NSOutlineView class]]) ov = (NSOutlineView *)v; else [stack addObjectsFromArray:v.subviews]; }
        BOOL ok = ov && [mainWin() makeFirstResponder:ov];
        say([NSString stringWithFormat:@"outline focus=%d", ok]);
        after(0.5); return;
    }
    if ([cmd isEqualToString:@"menustate"]) { *handled = YES;
        NSMenuItem *item = resolveMenuPath(arg);
        say([NSString stringWithFormat:@"menustate %@ enabled=%d key=%@ mods=%lu", arg, item.isEnabled, item.keyEquivalent, (unsigned long)item.keyEquivalentModifierMask]);
        after(0.1); return;
    }
    if ([cmd isEqualToString:@"rowclick"] || [cmd isEqualToString:@"rowdblclick"]) { *handled = YES;
        // In-process mouse click on the element titled arg (never a system event); rowclick:sheet:<label> looks only in sheets.
        NSWindow *w = nil; id el = nil;
        BOOL sheetOnly = [arg hasPrefix:@"sheet:"];
        if (sheetOnly) arg = [arg substringFromIndex:6];
        for (NSWindow *x in NSApp.windows) if (x.isVisible && !el && (!sheetOnly || x.isSheet)) { el = findAX(x, arg, 0); w = x; }
        if (!el || ![el respondsToSelector:@selector(accessibilityFrame)]) { say([NSString stringWithFormat:@"%@ %@ missing", cmd, arg]); after(0.2); return; }
        NSRect f = [el accessibilityFrame];
        NSPoint screen = NSMakePoint(NSMinX(f) + MIN(20, f.size.width / 2), NSMidY(f));
        NSPoint loc = [w convertPointFromScreen:screen];
        NSInteger clicks = [cmd isEqualToString:@"rowdblclick"] ? 2 : 1;
        for (NSInteger c = 1; c <= clicks; c++) {
            NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:loc modifierFlags:0 timestamp:[[NSProcessInfo processInfo] systemUptime] windowNumber:w.windowNumber context:nil eventNumber:0 clickCount:c pressure:1];
            NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:loc modifierFlags:0 timestamp:[[NSProcessInfo processInfo] systemUptime] windowNumber:w.windowNumber context:nil eventNumber:0 clickCount:c pressure:0];
            [NSApp postEvent:down atStart:NO]; [NSApp postEvent:up atStart:NO];
        }
        say([NSString stringWithFormat:@"%@ %@ at %@", cmd, arg, NSStringFromPoint(loc)]);
        after(0.6); return;
    }
    if ([cmd isEqualToString:@"axpressasync"]) { *handled = YES;
        id el = nil;
        for (NSWindow *w in NSApp.windows) if (w.isVisible && !el) el = findAX(w, arg, 0);
        say([NSString stringWithFormat:@"axpressasync %@ -> %d", arg, el != nil]);
        after(1.0);
        if (el) dispatch_async(dispatch_get_main_queue(), ^{ axActivate(el); });
        return;
    }
    if ([cmd isEqualToString:@"axenabled"]) { *handled = YES;
        id hit = nil;
        for (NSWindow *w in NSApp.windows) if (w.isVisible && !hit) hit = findAXButtonContaining(w, arg, 0);
        NSString *state = !hit ? @"missing" : [hit respondsToSelector:@selector(isAccessibilityEnabled)] ? ([hit isAccessibilityEnabled] ? @"1" : @"0") : [axAttr(hit, NSAccessibilityEnabledAttribute) description];
        say([NSString stringWithFormat:@"axenabled %@ -> %@", arg, state]);
        after(0.1); return;
    }
    if ([cmd isEqualToString:@"axstate"]) { *handled = YES; // axstate:<label>: enabled state of the element with exactly that label (or "label, …")
        id hit = nil;
        for (NSWindow *w in NSApp.windows) if (w.isVisible && !hit) hit = findAX(w, arg, 0);
        NSString *state = !hit ? @"missing" : [hit respondsToSelector:@selector(isAccessibilityEnabled)] ? ([hit isAccessibilityEnabled] ? @"1" : @"0") : [axAttr(hit, NSAccessibilityEnabledAttribute) description];
        say([NSString stringWithFormat:@"axstate %@ -> %@ (%@)", arg, state, hit ? NSStringFromClass([hit class]) : @"none"]);
        after(0.1); return;
    }
    if ([cmd isEqualToString:@"gridgeom"]) { *handled = YES; // gridgeom:<table accessibility label>: screen frames of the header and of the rows the table reports to accessibility; clear=1 when row 0 is the first of them and sits fully between the header and the bottom of the scroll view
        NSTableView *table = nil;
        NSMutableArray *stack = mainWin().contentView ? [NSMutableArray arrayWithObject:mainWin().contentView] : [NSMutableArray array];
        while (stack.count && !table) { NSView *v = stack.lastObject; [stack removeLastObject];
            if (v.isHiddenOrHasHiddenAncestor) continue;
            if ([v isKindOfClass:NSTableView.class] && [v.accessibilityLabel isEqualToString:arg]) table = (NSTableView *)v; else [stack addObjectsFromArray:v.subviews]; }
        if (!table) { say([NSString stringWithFormat:@"gridgeom %@ missing", arg]); after(0.1); return; }
        NSScrollView *sv = table.enclosingScrollView;
        NSRect scroll = [sv.window convertRectToScreen:[sv convertRect:sv.bounds toView:nil]];
        NSRect header = table.headerView ? table.headerView.accessibilityFrame : NSZeroRect;
        NSArray *rows = table.accessibilityRows ?: @[];
        NSMutableArray *desc = [NSMutableArray array];
        for (id r in rows) [desc addObject:[NSString stringWithFormat:@"%ld:%.1f-%.1f", (long)[r accessibilityIndex], NSMinY([r accessibilityFrame]), NSMaxY([r accessibilityFrame])]];
        id first = rows.firstObject;
        NSRect f = first ? [first accessibilityFrame] : NSZeroRect;
        BOOL clear = first && [first accessibilityIndex] == 0 && NSMaxY(f) <= NSMinY(header) + 0.5 && NSMinY(f) >= NSMinY(scroll) - 0.5 && f.size.height > 0;
        NSRange visible = [table rowsInRect:table.visibleRect];
        __block NSInteger views = 0;
        [table enumerateAvailableRowViewsUsingBlock:^(NSTableRowView *rv, NSInteger r) { views++; }];
        say([NSString stringWithFormat:@"gridgeom %@ clear=%d table=%ld visible=%@ views=%ld window=%.0fx%.0f rows=%lu scroll=%.1f-%.1f header=%.1f-%.1f insetTop=%.1f originY=%.1f axrows=%@", arg, clear, (long)table.numberOfRows, NSStringFromRange(visible), (long)views, NSWidth(sv.window.frame), NSHeight(sv.window.frame), (unsigned long)rows.count, NSMinY(scroll), NSMaxY(scroll), NSMinY(header), NSMaxY(header), sv.contentView.contentInsets.top, sv.contentView.bounds.origin.y, [[desc subarrayWithRange:NSMakeRange(0, MIN(desc.count, 4))] componentsJoinedByString:@","]]);
        after(0.1); return;
    }
    if ([cmd isEqualToString:@"firstlinegap"]) { *handled = YES; // firstlinegap:<control label>|<text label>: whether the control covers the visible part of the first line (13 pt monospaced) of the text element inside its scroll area, in any visible window or sheet
        NSArray *parts = [arg componentsSeparatedByString:@"|"];
        id control = nil, text = nil;
        for (NSWindow *w in NSApp.windows) if (w.isVisible && parts.count > 1) { if (!control) control = findAX(w, parts[0], 0); if (!text) text = findAXDeepest(w, parts[1], 0); }
        if (!control || !text) { say([NSString stringWithFormat:@"firstlinegap %@ missing control=%d text=%d", arg, control != nil, text != nil]); after(0.1); return; }
        NSFont *mono = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightRegular];
        CGFloat line = ceil(mono.ascender - mono.descender + mono.leading);
        NSRect c = [control accessibilityFrame], t = [text accessibilityFrame];
        NSRect first = NSMakeRect(NSMinX(t), NSMaxY(t) - line, NSWidth(t), line);
        for (id p = axAttr(text, NSAccessibilityParentAttribute); p; p = axAttr(p, NSAccessibilityParentAttribute)) {
            if ([axAttr(p, NSAccessibilityRoleAttribute) isEqual:NSAccessibilityScrollAreaRole]) { first = NSIntersectionRect(first, [p accessibilityFrame]); break; }
        }
        say([NSString stringWithFormat:@"firstlinegap %@ overlap=%d control=%@ visibleFirstLine=%@", arg, NSIntersectsRect(c, first), NSStringFromRect(c), NSStringFromRect(first)]);
        after(0.1); return;
    }
    if ([cmd isEqualToString:@"wininfo"]) { *handled = YES; // every visible window except the main one, with its accessibility text
        NSWindow *main = mainWin();
        for (NSWindow *w in NSApp.windows) {
            if (!w.isVisible || w == main) continue;
            NSMutableArray *acc = [NSMutableArray array]; labelDepth = 30; collectLabels(w, acc, 0); labelDepth = 12;
            say([NSString stringWithFormat:@"win class=%@ key=%d sheet=%d text=%@", NSStringFromClass(w.class), w.isKeyWindow, w.isSheet, [acc componentsJoinedByString:@" | "]]);
        }
        say(@"wininfo end"); after(0.1); return;
    }
    if ([cmd isEqualToString:@"outlinesel"]) { *handled = YES; // native selection of the file outline + row views that draw as selected
        NSMutableArray *stack = [NSMutableArray arrayWithObject:mainWin().contentView]; NSOutlineView *ov = nil;
        while (stack.count && !ov) { NSView *v = stack.lastObject; [stack removeLastObject];
            if (v.isHiddenOrHasHiddenAncestor) continue;
            if ([v isKindOfClass:[NSOutlineView class]]) ov = (NSOutlineView *)v; else [stack addObjectsFromArray:v.subviews]; }
        NSMutableArray *sel = [NSMutableArray array], *drawn = [NSMutableArray array];
        NSRange vis = [ov rowsInRect:ov.visibleRect];
        for (NSInteger row = (NSInteger)vis.location; row < (NSInteger)NSMaxRange(vis); row++) {
            NSTableRowView *rv = [ov rowViewAtRow:row makeIfNecessary:NO];
            NSMutableArray *acc = [NSMutableArray array];
            for (NSInteger c = 0; c < rv.numberOfColumns && !acc.count; c++) collectLabels([rv viewAtColumn:c], acc, 0);
            NSString *name = acc.firstObject ?: [NSString stringWithFormat:@"row%ld", (long)row];
            if ([ov.selectedRowIndexes containsIndex:row]) [sel addObject:name];
            if (rv.isSelected) [drawn addObject:name];
        }
        // outlinesel:<title> also reports which row that title is on, so names are not needed.
        NSInteger expected = -1;
        if (arg.length) {
            id el = findAX(mainWin(), arg, 0);
            if ([el respondsToSelector:@selector(accessibilityFrame)]) {
                NSRect f = [el accessibilityFrame];
                NSPoint p = [ov convertPoint:[mainWin() convertPointFromScreen:NSMakePoint(NSMidX(f), NSMidY(f))] fromView:nil];
                expected = [ov rowAtPoint:p];
            }
        }
        say([NSString stringWithFormat:@"outlinesel %@=row%ld selected=[%@] drawnSelected=[%@]", arg, (long)expected, [sel componentsJoinedByString:@","], [drawn componentsJoinedByString:@","]]);
        after(0.1); return;
    }
    if ([cmd isEqualToString:@"axexists"]) { *handled = YES;
        id el = nil; for (NSWindow *w in NSApp.windows) if (w.isVisible && !el) el = findAX(w, arg, 0);
        say([NSString stringWithFormat:@"axexists %@ -> %d", arg, el != nil]); after(0.1); return;
    }
    if ([cmd isEqualToString:@"deeplabels"]) { *handled = YES; // like labels, but deep and including static text values
        NSMutableArray *acc = [NSMutableArray array]; labelDepth = arg.length ? arg.intValue : 30; collectLabels(mainWin(), acc, 0);
        if (mainWin().attachedSheet) collectLabels(mainWin().attachedSheet, acc, 0);
        labelDepth = 12;
        say([NSString stringWithFormat:@"deeplabels: %@", [acc componentsJoinedByString:@" | "]]); after(0.1); return;
    }
    if ([cmd isEqualToString:@"popoverlabels"]) { *handled = YES;
        NSMutableArray *acc = [NSMutableArray array]; labelDepth = 30;
        for (NSWindow *w in NSApp.windows) if (w.isVisible && [NSStringFromClass(w.class) containsString:@"Popover"]) collectLabels(w, acc, 0);
        labelDepth = 12;
        say([NSString stringWithFormat:@"popoverlabels: %@", [acc componentsJoinedByString:@" | "]]); after(0.1); return;
    }
    if ([cmd isEqualToString:@"axfind"]) { *handled = YES; // axfind:<text>: up to 8 labels, titles or values containing text in any visible window (editors skipped), reached through every accessibility child, not only the ones deeplabels walks
        NSMutableArray *hits = [NSMutableArray array];
        __block void (^walk)(id, int);
        __block __weak void (^weakWalk)(id, int);
        weakWalk = walk = ^(id el, int depth) {
            if (depth > 60 || !el || hits.count >= 8) return;
            if (![el isKindOfClass:NSTextView.class]) {
                for (NSString *a in @[NSAccessibilityDescriptionAttribute, NSAccessibilityTitleAttribute, NSAccessibilityValueAttribute]) {
                    id v = axAttr(el, a);
                    if ([v isKindOfClass:NSString.class] && [v containsString:arg]) { [hits addObject:v]; break; }
                }
            }
            for (id k in axAttr(el, NSAccessibilityChildrenAttribute)) weakWalk(k, depth + 1);
        };
        for (NSWindow *w in NSApp.windows) if (w.isVisible) walk(w, 0);
        say([NSString stringWithFormat:@"axfind %@ -> %lu: %@", arg, (unsigned long)hits.count, [hits componentsJoinedByString:@" ‖ "]]);
        after(0.1); return;
    }
    if ([cmd isEqualToString:@"sheetpress"]) { *handled = YES; // sheetpress:<title>: click the button with that title in a visible sheet
        NSButton *hit = nil; NSMutableArray *seen = [NSMutableArray array];
        for (NSWindow *w in NSApp.windows) {
            if (!w.isVisible || !w.isSheet || hit) continue;
            NSMutableArray *stack = [NSMutableArray arrayWithObject:w.contentView.superview ?: w.contentView];
            while (stack.count && !hit) {
                NSView *v = stack.lastObject; [stack removeLastObject];
                if ([v isKindOfClass:NSButton.class]) { if ([((NSButton *)v).title isEqualToString:arg]) hit = (NSButton *)v; else [seen addObject:((NSButton *)v).title ?: @""]; }
                [stack addObjectsFromArray:v.subviews];
            }
        }
        if (hit) [hit performClick:nil];
        say([NSString stringWithFormat:@"sheetpress %@ -> %d (buttons: %@)", arg, hit != nil, [seen componentsJoinedByString:@", "]]); after(0.8); return;
    }
}
