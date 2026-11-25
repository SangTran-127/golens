static double ghostStart, ghostLimit;
static void ghostPoll(void) {
    NSTextView *e = editor();
    NSString *state = [e respondsToSelector:NSSelectorFromString(@"inlineSuggestionDebugState")] ? [e valueForKey:@"inlineSuggestionDebugState"] : @"unsupported";
    double elapsed = NSProcessInfo.processInfo.systemUptime - ghostStart;
    if ([state hasPrefix:@"visible"] || elapsed > ghostLimit) {
        say([NSString stringWithFormat:@"ghostwait %.0f ms %@", elapsed * 1000, state]);
        after(0.1);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ ghostPoll(); });
}
static void typeString(NSString *text, NSUInteger i) {
    NSTextView *tv = editor();
    if (i >= text.length || !tv) { after(0.05); return; }
    NSRange r = [text rangeOfComposedCharacterSequenceAtIndex:i];
    NSString *ch = [text substringWithRange:r];
    [tv insertText:ch replacementRange:NSMakeRange(NSNotFound, 0)];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(typeDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ typeString(text, NSMaxRange(r)); });
}

static NSMutableArray<NSNumber *> *keySamples;
static double keyDue;
static BOOL imeMode;
static BOOL eventMode;
static BOOL sendKeyEvent(NSTextView *tv, NSString *ch) {
    NSDictionary<NSString *, NSArray *> *special = @{
        @"\n": @[@36, @"\r"], @"\t": @[@48, @"\t"], @"\u232B": @[@51, @"\x7f"], @"\u238B": @[@53, @"\x1b"],
        @"\u2190": @[@123, [NSString stringWithFormat:@"%C", (unichar)NSLeftArrowFunctionKey]],
        @"\u2192": @[@124, [NSString stringWithFormat:@"%C", (unichar)NSRightArrowFunctionKey]],
        @"\u2193": @[@125, [NSString stringWithFormat:@"%C", (unichar)NSDownArrowFunctionKey]],
        @"\u2191": @[@126, [NSString stringWithFormat:@"%C", (unichar)NSUpArrowFunctionKey]]};
    if ([ch isEqualToString:@"\u21E5"]) return NO;
    NSArray *sp = special[ch];
    unsigned short code = sp ? [sp[0] unsignedShortValue] : 0;
    NSString *chars = sp ? sp[1] : ch;
    NSEventModifierFlags mods = (!sp && ch.length == 1 && [NSCharacterSet.uppercaseLetterCharacterSet characterIsMember:[ch characterAtIndex:0]]) ? NSEventModifierFlagShift : 0;
    double ts = NSProcessInfo.processInfo.systemUptime;
    NSEvent *down = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:mods timestamp:ts windowNumber:tv.window.windowNumber context:nil characters:chars charactersIgnoringModifiers:chars.lowercaseString isARepeat:NO keyCode:code];
    NSEvent *up = [NSEvent keyEventWithType:NSEventTypeKeyUp location:NSZeroPoint modifierFlags:mods timestamp:ts windowNumber:tv.window.windowNumber context:nil characters:chars charactersIgnoringModifiers:chars.lowercaseString isARepeat:NO keyCode:code];
    [NSApp sendEvent:down];
    [NSApp sendEvent:up];
    return YES;
}
static NSMutableString *imeWord;
static void imeCommit(NSTextView *tv) {
    if (!imeWord.length) return;
    [tv insertText:[imeWord copy] replacementRange:NSMakeRange(NSNotFound, 0)];
    [imeWord setString:@""];
}
static void codeStringAt(NSString *text, NSUInteger i);
static void codeString(NSString *text, NSUInteger i) { keyDue = 0; codeStringAt(text, i); }
static void codeStringAt(NSString *text, NSUInteger i) {
    NSTextView *tv = editor();
    if (i >= text.length || !tv) { if (imeMode) imeCommit(tv); after(0.3); return; }
    NSRange r = [text rangeOfComposedCharacterSequenceAtIndex:i];
    NSString *ch = [text substringWithRange:r];
    double due = keyDue;
    BOOL ident = ch.length == 1 && ([NSCharacterSet.alphanumericCharacterSet characterIsMember:[ch characterAtIndex:0]] || [ch isEqualToString:@"_"]);
    if (imeMode && !ident) imeCommit(tv);
    BOOL sent = eventMode && ![ch isEqualToString:@"\u23F8"] && sendKeyEvent(tv, ch);
    if ([ch isEqualToString:@"\u23F8"]) { keyDue = 0; dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ codeStringAt(text, NSMaxRange(r)); }); return; }
    if (sent) {}
    else if ([ch isEqualToString:@"\n"]) [tv doCommandBySelector:@selector(insertNewline:)];
    else if ([ch isEqualToString:@"\t"]) [tv doCommandBySelector:@selector(insertTab:)];
    else if ([ch isEqualToString:@"\u2193"]) [tv doCommandBySelector:@selector(moveDown:)];
    else if ([ch isEqualToString:@"\u2192"]) [tv doCommandBySelector:@selector(moveRight:)];
    else if ([ch isEqualToString:@"\u21E5"]) [tv doCommandBySelector:@selector(moveToEndOfLine:)];
    else if ([ch isEqualToString:@"\u238B"]) [tv doCommandBySelector:@selector(cancelOperation:)];
    else if ([ch isEqualToString:@"\u232B"]) [tv doCommandBySelector:@selector(deleteBackward:)];
    else if ([ch isEqualToString:@"\u2191"]) [tv doCommandBySelector:@selector(moveUp:)];
    else if ([ch isEqualToString:@"\u2190"]) [tv doCommandBySelector:@selector(moveLeft:)];
    else if (imeMode && ident) {
        if (!imeWord) imeWord = [NSMutableString string];
        [imeWord appendString:ch];
        [tv setMarkedText:[imeWord copy] selectedRange:NSMakeRange(imeWord.length, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
    }
    else [tv insertText:ch replacementRange:NSMakeRange(NSNotFound, 0)];
    [tv.window displayIfNeeded];
    double now = NSProcessInfo.processInfo.systemUptime;
    if (due > 0) {
        double ms = (now - due) * 1000.0;
        if (!keySamples) keySamples = [NSMutableArray array];
        [keySamples addObject:@(ms)];
        if (ms > 50) say([NSString stringWithFormat:@"slowkey %.1f ms epoch=%.3f char=%@", ms, NSDate.date.timeIntervalSince1970, [ch isEqualToString:@"\n"] ? @"NL" : ch]);
    }
    keyDue = now + typeDelay;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(typeDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ codeStringAt(text, NSMaxRange(r)); });
}

static void dispatchActionStep(NSString *cmd, NSString *arg, NSTextView *tv, BOOL *handled) {
    if ([cmd isEqualToString:@"wait"]) { *handled = YES; after(arg.doubleValue); return; }
    if ([cmd isEqualToString:@"caret"]) { *handled = YES;
        NSRange r = [tv.string rangeOfString:arg];
        if (r.location == NSNotFound) { say([NSString stringWithFormat:@"caret: not found %@", arg]); }
        else {
            [tv.window makeFirstResponder:tv];
            [tv setSelectedRange:NSMakeRange(NSMaxRange(r), 0)];
            [tv scrollRangeToVisible:NSMakeRange(NSMaxRange(r), 0)];
            say([NSString stringWithFormat:@"caret at %lu", (unsigned long)NSMaxRange(r)]);
        }
        after(0.3); return;
    }
    if ([cmd isEqualToString:@"type"]) { *handled = YES; typeDelay = 0.12; typeString(arg, 0); return; }
    if ([cmd isEqualToString:@"typefast"]) { *handled = YES; typeDelay = 0.03; typeString(arg, 0); return; }
    if ([cmd isEqualToString:@"postkey"]) { *handled = YES;
        NSArray *parts = [arg componentsSeparatedByString:@","];
        unsigned short code = (unsigned short)[parts[0] intValue];
        NSString *chars = parts.count > 1 ? parts[1] : @"";
        if (code == 36) chars = @"\r"; else if (code == 53) chars = @"\x1b"; else if (code == 125) chars = [NSString stringWithFormat:@"%C", (unichar)NSDownArrowFunctionKey];
        NSWindow *w = NSApp.keyWindow ?: tv.window;
        NSEventModifierFlags mods = parts.count > 2 ? (NSEventModifierFlags)[parts[2] integerValue] : 0; // postkey:code,chars,modifierFlags[,secondsOffset]
        double stamp = [[NSProcessInfo processInfo] systemUptime] + (parts.count > 3 ? [parts[3] doubleValue] : 0);
        NSEvent *down = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:mods timestamp:stamp windowNumber:0 context:nil characters:chars charactersIgnoringModifiers:chars isARepeat:NO keyCode:code];
        NSEvent *up = [NSEvent keyEventWithType:NSEventTypeKeyUp location:NSZeroPoint modifierFlags:mods timestamp:stamp windowNumber:0 context:nil characters:chars charactersIgnoringModifiers:chars isARepeat:NO keyCode:code];
        [NSApp postEvent:down atStart:NO];
        [NSApp postEvent:up atStart:NO];
        say([NSString stringWithFormat:@"postkey %@", arg]);
        after(0.4); return;
    }
    if ([cmd isEqualToString:@"open"]) { *handled = YES;
        NSString *file = arg;
        id ws = nil; (void)ws;
        say([NSString stringWithFormat:@"open %@ (use menu)", file]);
        after(0.1); return;
    }
    if ([cmd isEqualToString:@"cursors"]) { *handled = YES; // cursors: the editor's insertion points and selections (single {loc, len}, or count/primary/list)
        say([NSString stringWithFormat:@"cursors %@", [tv valueForKey:@"multiCursorSummary"]]);
        after(0.1); return;
    }
    if ([cmd isEqualToString:@"optclick"] || [cmd isEqualToString:@"ctrlshiftclick"] || [cmd isEqualToString:@"optdrag"]) { *handled = YES;
        // optclick:text / ctrlshiftclick:text click with that modifier at the start of text; optdrag:from|to drags with Option held
        NSArray<NSString *> *ends = [arg componentsSeparatedByString:@"|"];
        NSMutableArray<NSValue *> *points = [NSMutableArray array];
        for (NSString *needle in ends) {
            NSRange r = [tv.string rangeOfString:needle];
            if (r.location == NSNotFound) { say([NSString stringWithFormat:@"%@: not found %@", cmd, needle]); after(0.1); return; }
            NSLayoutManager *lm = tv.layoutManager;
            NSUInteger g = [lm glyphIndexForCharacterAtIndex:r.location];
            NSRect line = [lm lineFragmentRectForGlyphAtIndex:g effectiveRange:NULL];
            NSPoint p = NSMakePoint([lm locationForGlyphAtIndex:g].x + line.origin.x + tv.textContainerOrigin.x + 1, NSMidY(line) + tv.textContainerOrigin.y);
            [points addObject:[NSValue valueWithPoint:[tv convertPoint:p toView:nil]]];
        }
        NSEventModifierFlags mods = [cmd isEqualToString:@"ctrlshiftclick"] ? (NSEventModifierFlagControl | NSEventModifierFlagShift) : NSEventModifierFlagOption;
        NSTimeInterval ts = [[NSProcessInfo processInfo] systemUptime];
        NSPoint first = points.firstObject.pointValue, last = points.lastObject.pointValue;
        NSInteger wn = tv.window.windowNumber;
        [tv mouseDown:[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:first modifierFlags:mods timestamp:ts windowNumber:wn context:nil eventNumber:0 clickCount:1 pressure:1]];
        if (points.count > 1) [tv mouseDragged:[NSEvent mouseEventWithType:NSEventTypeLeftMouseDragged location:last modifierFlags:mods timestamp:ts + 0.01 windowNumber:wn context:nil eventNumber:0 clickCount:1 pressure:1]];
        [tv mouseUp:[NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:last modifierFlags:mods timestamp:ts + 0.02 windowNumber:wn context:nil eventNumber:0 clickCount:1 pressure:0]];
        say([NSString stringWithFormat:@"%@ %@ -> %@", cmd, [arg stringByReplacingOccurrencesOfString:@"\n" withString:@"⏎"], [tv valueForKey:@"multiCursorSummary"]]);
        after(0.3); return;
    }
    if ([cmd isEqualToString:@"gutterclick"] || [cmd isEqualToString:@"textclick"] || [cmd isEqualToString:@"bpclick"] || [cmd isEqualToString:@"cmdclick"]) { *handled = YES;
        NSRange r = [tv.string rangeOfString:arg];
        if (r.location == NSNotFound) { say([NSString stringWithFormat:@"%@: not found %@", cmd, arg]); after(0.1); return; }
        NSLayoutManager *lm = tv.layoutManager;
        NSUInteger g = [lm glyphIndexForCharacterAtIndex:r.location];
        NSRect line = [lm lineFragmentRectForGlyphAtIndex:g effectiveRange:NULL];
        [tv scrollRangeToVisible:r];
        CGFloat gx = tv.visibleRect.origin.x;
        CGFloat gw = MAX(48.0, tv.textContainer.lineFragmentPadding - 6.0);
        CGFloat x = [cmd isEqualToString:@"bpclick"] ? (gx + gw - 14.0) : [cmd isEqualToString:@"cmdclick"] ? [lm locationForGlyphAtIndex:g].x + tv.textContainerOrigin.x + 6 : [cmd isEqualToString:@"gutterclick"] ? (gx + 8.0) : [lm locationForGlyphAtIndex:g].x + tv.textContainerOrigin.x + 2;
        NSPoint p = NSMakePoint(x, NSMidY(line) + tv.textContainerOrigin.y);
        NSPoint w = [tv convertPoint:p toView:nil];
        NSEventModifierFlags mods = [cmd isEqualToString:@"cmdclick"] ? NSEventModifierFlagCommand : 0;
        NSTimeInterval ts = [[NSProcessInfo processInfo] systemUptime];
        NSEvent *e = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:w modifierFlags:mods timestamp:ts windowNumber:tv.window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
        NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:w modifierFlags:mods timestamp:ts + 0.01 windowNumber:tv.window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:0];
        [NSApp postEvent:up atStart:YES];
        [tv mouseDown:e];
        [tv.window nextEventMatchingMask:NSEventMaskLeftMouseUp untilDate:[NSDate distantPast] inMode:NSEventTrackingRunLoopMode dequeue:YES];
        [tv.window nextEventMatchingMask:NSEventMaskLeftMouseUp untilDate:[NSDate distantPast] inMode:NSDefaultRunLoopMode dequeue:YES];
        say([NSString stringWithFormat:@"%@ %@ at %@", cmd, arg, NSStringFromPoint(p)]);
        after(0.4); return;
    }
    if ([cmd isEqualToString:@"changebar"]) { *handled = YES; // text: clicks the source control change bar at the right edge of the gutter on that line
        NSRange r = [tv.string rangeOfString:arg];
        if (r.location == NSNotFound) { say([NSString stringWithFormat:@"changebar: not found %@", arg]); after(0.1); return; }
        [tv scrollRangeToVisible:r];
        NSLayoutManager *lm = tv.layoutManager;
        NSRect line = [lm lineFragmentRectForGlyphAtIndex:[lm glyphIndexForCharacterAtIndex:r.location] effectiveRange:NULL];
        CGFloat x = tv.visibleRect.origin.x + MAX(48.0, tv.textContainer.lineFragmentPadding - 6.0) - 3.0;
        NSPoint w = [tv convertPoint:NSMakePoint(x, NSMidY(line) + tv.textContainerOrigin.y) toView:nil];
        NSTimeInterval ts = [[NSProcessInfo processInfo] systemUptime];
        NSEvent *e = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:w modifierFlags:0 timestamp:ts windowNumber:tv.window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
        NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:w modifierFlags:0 timestamp:ts + 0.01 windowNumber:tv.window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:0];
        [NSApp postEvent:up atStart:YES];
        [tv mouseDown:e];
        [tv.window nextEventMatchingMask:NSEventMaskLeftMouseUp untilDate:[NSDate distantPast] inMode:NSEventTrackingRunLoopMode dequeue:YES];
        [tv.window nextEventMatchingMask:NSEventMaskLeftMouseUp untilDate:[NSDate distantPast] inMode:NSDefaultRunLoopMode dequeue:YES];
        say([NSString stringWithFormat:@"changebar %@ x=%.0f", arg, x]);
        after(1.0); return;
    }
    if ([cmd isEqualToString:@"gutterctx"]) { *handled = YES; // text|item: the gutter context menu on the line holding text, lists it and performs item
        NSArray *parts = [arg componentsSeparatedByString:@"|"];
        NSRange r = [tv.string rangeOfString:parts[0]];
        if (r.location == NSNotFound || parts.count < 2) { say([NSString stringWithFormat:@"gutterctx: not found %@", arg]); after(0.1); return; }
        [tv scrollRangeToVisible:r];
        NSLayoutManager *lm = tv.layoutManager;
        NSRect line = [lm lineFragmentRectForGlyphAtIndex:[lm glyphIndexForCharacterAtIndex:r.location] effectiveRange:NULL];
        NSPoint w = [tv convertPoint:NSMakePoint(tv.visibleRect.origin.x + 28.0, NSMidY(line) + tv.textContainerOrigin.y) toView:nil];
        NSEvent *e = [NSEvent mouseEventWithType:NSEventTypeRightMouseDown location:w modifierFlags:0 timestamp:[[NSProcessInfo processInfo] systemUptime] windowNumber:tv.window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
        NSMenu *menu = [tv menuForEvent:e];
        [menu update];
        NSMutableArray *titles = [NSMutableArray array];
        NSMenuItem *hit = nil;
        for (NSMenuItem *it in menu.itemArray) {
            if (it.isSeparatorItem) continue;
            [titles addObject:it.title];
            if ([it.title isEqualToString:parts[1]]) hit = it;
        }
        say([NSString stringWithFormat:@"gutterctx %@ items=[%@] performed=%d", arg, [titles componentsJoinedByString:@","], hit != nil]);
        if (hit) dispatch_async(dispatch_get_main_queue(), ^{ [menu performActionForItemAtIndex:[menu indexOfItem:hit]]; });
        after(1.0); return;
    }
    if ([cmd isEqualToString:@"lensclick"]) { *handled = YES; // anchor|title1,title2|index: lenses are drawn after the line's text, split by "|"
        NSArray *parts = [arg componentsSeparatedByString:@"|"];
        NSRange r = parts.count == 3 ? [tv.string rangeOfString:parts[0]] : NSMakeRange(NSNotFound, 0);
        if (r.location == NSNotFound) { say([NSString stringWithFormat:@"lensclick: not found %@", arg]); after(0.1); return; }
        NSArray *titles = [parts[1] componentsSeparatedByString:@","];
        NSInteger idx = [parts[2] integerValue];
        NSString *targetTitle = (idx >= 0 && idx < (NSInteger)titles.count) ? titles[idx] : @"";
        [tv scrollRangeToVisible:r];
        [tv displayIfNeeded];
        NSPoint p = NSZeroPoint;
        if ([tv respondsToSelector:@selector(smokeLensHitPointForCharacterIndex:title:index:)]) {
            p = [tv smokeLensHitPointForCharacterIndex:(NSInteger)r.location title:targetTitle index:idx];
        }
        if (NSEqualPoints(p, NSZeroPoint)) {
            NSDictionary *attrs = @{NSFontAttributeName: [NSFont systemFontOfSize:10]};
            NSLayoutManager *lm = tv.layoutManager;
            NSUInteger g = [lm glyphIndexForCharacterAtIndex:r.location];
            NSRect used = [lm lineFragmentUsedRectForGlyphAtIndex:g effectiveRange:NULL];
            CGFloat x = NSMaxX(used) + tv.textContainerOrigin.x + 16;
            CGFloat sep = [@"|" sizeWithAttributes:attrs].width + 6;
            for (NSInteger i = 0; i < idx && i < (NSInteger)titles.count; i++) x += [titles[i] sizeWithAttributes:attrs].width + 6 + sep;
            if (idx >= 0 && idx < (NSInteger)titles.count) x += [titles[idx] sizeWithAttributes:attrs].width / 2;
            p = NSMakePoint(x, NSMidY(used) + tv.textContainerOrigin.y);
        }
        NSEvent *e = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:[tv convertPoint:p toView:nil] modifierFlags:0 timestamp:[[NSProcessInfo processInfo] systemUptime] windowNumber:tv.window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
        [tv mouseDown:e];
        say([NSString stringWithFormat:@"lensclick %@ at %@", targetTitle, NSStringFromPoint(p)]);
        after(0.4); return;
    }
    if ([cmd isEqualToString:@"watch"]) { *handled = YES;
        if ([arg isEqualToString:@"on"]) {
            watchShows = watchHides = watchSamples = 0; watchLast = completionPanel().isVisible;
            watchTimer = [NSTimer scheduledTimerWithTimeInterval:0.005 repeats:YES block:^(NSTimer *t) {
                BOOL v = completionPanel().isVisible; watchSamples++;
                if (v && !watchLast) watchShows++;
                if (!v && watchLast) watchHides++;
                watchLast = v;
            }];
            [[NSRunLoop mainRunLoop] addTimer:watchTimer forMode:NSRunLoopCommonModes];
        } else {
            [watchTimer invalidate];
            say([NSString stringWithFormat:@"watch shows=%d hides=%d samples=%d visibleNow=%d", watchShows, watchHides, watchSamples, completionPanel().isVisible]);
        }
        after(0.1); return;
    }
    if ([cmd isEqualToString:@"click"]) { *handled = YES;
        NSRange r = [tv.string rangeOfString:arg];
        if (r.location != NSNotFound) { [tv setSelectedRange:NSMakeRange(NSMaxRange(r), 0)]; }
        say([NSString stringWithFormat:@"click after %@ -> %lu", arg, (unsigned long)NSMaxRange(r)]);
        after(0.3); return;
    }
    if ([cmd isEqualToString:@"key"]) { *handled = YES;
        [tv doCommandBySelector:NSSelectorFromString(arg)];
        say([NSString stringWithFormat:@"key %@", arg]);
        after(0.3); return;
    }
    if ([cmd isEqualToString:@"undo"]) { *handled = YES; [tv.undoManager undo]; say(@"undo"); after(0.3); return; }
    if ([cmd isEqualToString:@"redo"]) { *handled = YES; [tv.undoManager redo]; say(@"redo"); after(0.3); return; }
    if ([cmd isEqualToString:@"head"]) { *handled = YES;
        NSString *s = tv.string ?: @"";
        NSRange first = [s lineRangeForRange:NSMakeRange(0, 0)];
        say([NSString stringWithFormat:@"head %@ len=%lu window=%@", [[s substringWithRange:first] stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet], (unsigned long)s.length, tv.window.title]);
        after(0.05); return;
    }
    if ([cmd isEqualToString:@"save"]) { *handled = YES;
        NSEvent *e = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand timestamp:0 windowNumber:tv.window.windowNumber context:nil characters:@"s" charactersIgnoringModifiers:@"s" isARepeat:NO keyCode:1];
        [NSApp.mainMenu performKeyEquivalent:e];
        say(@"save");
        after(0.5); return;
    }
    if ([cmd isEqualToString:@"panel"]) { *handled = YES;
        NSPanel *p = completionPanel();
        NSRange sel = tv.selectedRange;
        NSRect caret = [tv firstRectForCharacterRange:sel actualRange:NULL];
        if (!p || !p.isVisible) { say([NSString stringWithFormat:@"panel hidden caret=%@", NSStringFromRect(caret)]); after(0.1); return; }
        NSMutableArray *labels = [NSMutableArray array];
        collectLabels(p.contentView, labels, 0);
        say([NSString stringWithFormat:@"panel visible frame=%@ caretLine=%@ gapBelowLine=%.1f parent=%d rows=%@",
             NSStringFromRect(p.frame), NSStringFromRect(caret), NSMinY(caret) - NSMaxY(p.frame), p.parentWindow != nil, [labels componentsJoinedByString:@" | "]]);
        after(0.1); return;
    }
    if ([cmd isEqualToString:@"panelwait"]) { *handled = YES;
        CFAbsoluteTime begin = CFAbsoluteTimeGetCurrent();
        NSString *label = arg.length ? arg : @"-";
        [NSTimer scheduledTimerWithTimeInterval:0.01 repeats:YES block:^(NSTimer *timer) {
            NSPanel *p = completionPanel();
            double ms = (CFAbsoluteTimeGetCurrent() - begin) * 1000;
            if (p && p.isVisible) {
                [timer invalidate];
                say([NSString stringWithFormat:@"panelwait %@ %.0f ms", label, ms]);
                after(0.1);
            } else if (ms > 4000) {
                [timer invalidate];
                say([NSString stringWithFormat:@"panelwait %@ timeout", label]);
                after(0.1);
            }
        }];
        return;
    }
    if ([cmd isEqualToString:@"line"]) { *handled = YES;
        NSString *s = tv.string;
        NSRange lr = [s lineRangeForRange:tv.selectedRange];
        NSRange prev = lr.location > 0 ? [s lineRangeForRange:NSMakeRange(lr.location - 1, 0)] : lr;
        say([NSString stringWithFormat:@"line: %@ | sel=%@", [[s substringWithRange:NSUnionRange(prev, lr)] stringByReplacingOccurrencesOfString:@"\n" withString:@"⏎"], NSStringFromRange(tv.selectedRange)]);
        after(0.1); return;
    }
    if ([cmd isEqualToString:@"clearline"]) { *handled = YES;
        NSString *s = tv.string;
        NSRange lr = [s lineRangeForRange:tv.selectedRange];
        NSUInteger end = NSMaxRange(lr);
        while (end > lr.location && [[NSCharacterSet newlineCharacterSet] characterIsMember:[s characterAtIndex:end - 1]]) end--;
        [tv.window makeFirstResponder:tv];
        [tv setSelectedRange:NSMakeRange(lr.location, end - lr.location)];
        [tv doCommandBySelector:@selector(deleteBackward:)];
        say([NSString stringWithFormat:@"clearline %@", NSStringFromRange(NSMakeRange(lr.location, end - lr.location))]);
        after(0.3); return;
    }
    if ([cmd isEqualToString:@"waitgone"]) { *handled = YES; // waitgone:<text>: pause until the editor no longer contains text (max 15 s), for edits applied asynchronously
        CFAbsoluteTime begin = CFAbsoluteTimeGetCurrent();
        [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *t) {
            NSTextView *e = editor();
            BOOL gone = e && [e.string rangeOfString:arg].location == NSNotFound;
            double secs = CFAbsoluteTimeGetCurrent() - begin;
            if (gone || secs > 15) { [t invalidate]; say([NSString stringWithFormat:@"waitgone '%@' -> %d after %.1f s", arg, gone, secs]); after(0.1); }
        }];
        return;
    }
    if ([cmd isEqualToString:@"find"]) { *handled = YES;
        NSRange r = [tv.string rangeOfString:arg];
        say([NSString stringWithFormat:@"find '%@' -> %@", arg, r.location == NSNotFound ? @"absent" : @"present"]);
        after(0.1); return;
    }
    if ([cmd isEqualToString:@"select"]) { *handled = YES;
        NSRange r = [tv.string rangeOfString:arg];
        if (r.location != NSNotFound) { [tv.window makeFirstResponder:tv]; [tv setSelectedRange:r]; }
        say([NSString stringWithFormat:@"select %@ -> %@", arg, NSStringFromRange(r)]);
        after(0.3); return;
    }
    if ([cmd isEqualToString:@"front"]) { *handled = YES;
        NSTask *t = [NSTask new];
        t.launchPath = @"/usr/bin/osascript";
        t.arguments = @[@"-e", [NSString stringWithFormat:@"tell application \"System Events\" to set frontmost of (first process whose unix id is %d) to true", getpid()]];
        [t launch]; [t waitUntilExit];
        say([NSString stringWithFormat:@"front status=%d active=%d", t.terminationStatus, NSApp.isActive]);
        after(1.0); return;
    }
    if ([cmd isEqualToString:@"term"]) { *handled = YES;
        NSView *found = nil;
        NSMutableArray *stack = [NSMutableArray arrayWithObject:mainWin().contentView];
        while (stack.count && !found) { NSView *v = stack.lastObject; [stack removeLastObject];
            if ([NSStringFromClass(v.class) containsString:@"TerminalView"] && !v.isHiddenOrHasHiddenAncestor) found = v;
            [stack addObjectsFromArray:v.subviews]; }
        if (found) { [found.window makeFirstResponder:found]; [(id<NSTextInputClient>)found insertText:arg replacementRange:NSMakeRange(NSNotFound, 0)]; }
        say([NSString stringWithFormat:@"term %@ -> %@", arg, found ? NSStringFromClass(found.class) : @"none"]);
        after(0.5); return;
    }
    if ([cmd isEqualToString:@"fakeactive"]) { *handled = YES;
        method_setImplementation(class_getInstanceMethod(NSApplication.class, @selector(isActive)), (IMP)yesImp);
        NSWindow *w = tv.window ?: mainWin();
        fakeKey = w;
        method_setImplementation(class_getInstanceMethod(NSApplication.class, @selector(keyWindow)), (IMP)keyWinImp);
        method_setImplementation(class_getInstanceMethod(NSApplication.class, @selector(mainWindow)), (IMP)keyWinImp);
        activateWindowAndSheetAppearance(w);
        [w makeKeyWindow];
        [NSNotificationCenter.defaultCenter postNotificationName:NSWindowDidBecomeMainNotification object:w];
        [NSNotificationCenter.defaultCenter postNotificationName:NSApplicationDidBecomeActiveNotification object:NSApp];
        [NSNotificationCenter.defaultCenter postNotificationName:NSWindowDidBecomeKeyNotification object:w];
        if (tv) [w makeFirstResponder:tv];
        say([NSString stringWithFormat:@"fakeactive key=%d", w.isKeyWindow]);
        after(0.8); return;
    }
    if ([cmd isEqualToString:@"fakeinactive"]) { *handled = YES;
        method_setImplementation(class_getInstanceMethod(NSApplication.class, @selector(isActive)), (IMP)noImp);
        [NSNotificationCenter.defaultCenter postNotificationName:NSApplicationDidResignActiveNotification object:NSApp];
        say(@"fakeinactive");
        after(0.2); return;
    }
    if ([cmd isEqualToString:@"activate"] || [cmd isEqualToString:@"keywin"]) { *handled = YES;
        [tv.window makeKeyWindow];
        [tv.window makeFirstResponder:tv];
        after(0.6); return;
    }
    if ([cmd isEqualToString:@"codefast"]) { *handled = YES; imeMode = NO; eventMode = NO; typeDelay = 0.02; codeString(arg, 0); return; }
    if ([cmd isEqualToString:@"code"]) { *handled = YES; imeMode = NO; eventMode = NO; typeDelay = 0.06; codeString(arg, 0); return; }
    if ([cmd isEqualToString:@"imecode"]) { *handled = YES; imeMode = YES; eventMode = NO; typeDelay = 0.06; codeString(arg, 0); return; }
    if ([cmd isEqualToString:@"keys"] || [cmd isEqualToString:@"keysfast"]) { *handled = YES; imeMode = NO; eventMode = YES; typeDelay = [cmd isEqualToString:@"keys"] ? 0.06 : 0.02; codeString(arg, 0); return; }
    if ([cmd isEqualToString:@"fr"]) { *handled = YES;
        id fr = NSApp.keyWindow.firstResponder;
        if ([fr respondsToSelector:@selector(insertText:replacementRange:)]) [fr insertText:arg replacementRange:NSMakeRange(NSNotFound, 0)];
        else if ([fr respondsToSelector:@selector(insertText:)]) [fr insertText:arg];
        say([NSString stringWithFormat:@"fr %@ -> %@ (%@)", arg, NSStringFromClass([fr class]), NSApp.keyWindow.title]);
        after(0.4); return;
    }
    if ([cmd isEqualToString:@"frkey"]) { *handled = YES;
        id fr = NSApp.keyWindow.firstResponder;
        [fr doCommandBySelector:NSSelectorFromString(arg)];
        say([NSString stringWithFormat:@"frkey %@ -> %@", arg, NSStringFromClass([fr class])]);
        after(0.4); return;
    }
    if ([cmd isEqualToString:@"field"]) { *handled = YES;
        // field:N:text -> set the Nth editable NSTextField of the key window (sheet first) to text
        NSRange c2 = [arg rangeOfString:@":"]; NSInteger n = [[arg substringToIndex:c2.location] integerValue]; NSString *text = [arg substringFromIndex:c2.location + 1];
        NSWindow *w = nil; for (NSWindow *x in NSApp.windows) if (x.isVisible && x.isSheet) w = x; if (!w) w = NSApp.keyWindow ?: mainWin();
        NSMutableArray *fields = [NSMutableArray array]; NSMutableArray *stack = [NSMutableArray arrayWithObject:w.contentView];
        while (stack.count) { NSView *v = stack.firstObject; [stack removeObjectAtIndex:0];
            if ([v isKindOfClass:NSTextField.class] && ((NSTextField *)v).isEditable) [fields addObject:v]; [stack addObjectsFromArray:v.subviews]; }
        NSTextField *f = n < (NSInteger)fields.count ? fields[n] : nil;
        if (f) { [w makeFirstResponder:f]; NSText *ed = [w fieldEditor:YES forObject:f]; [ed selectAll:nil]; [ed insertText:text]; }
        say([NSString stringWithFormat:@"field %ld/%lu -> %@ value=%@", (long)n, (unsigned long)fields.count, f ? @"ok" : @"none", f.stringValue]);
        after(0.4); return;
    }
    if ([cmd isEqualToString:@"winkey"]) { *handled = YES; // winkey:<title>: make that project window key (and the faked key window) with its editor focused
        NSWindow *w = windowLike(arg);
        if (w) {
            fakeKey = w;
            [w makeKeyWindow];
            [NSNotificationCenter.defaultCenter postNotificationName:NSWindowDidBecomeMainNotification object:w];
            [NSNotificationCenter.defaultCenter postNotificationName:NSWindowDidBecomeKeyNotification object:w];
            NSTextView *e = findEditor(w.contentView);
            if (e) [w makeFirstResponder:e];
        }
        say([NSString stringWithFormat:@"winkey %@ -> %d", arg, w != nil]);
        after(0.5); return;
    }
    if ([cmd isEqualToString:@"wintype"]) { *handled = YES; // wintype:<title>|text: insert text at the caret of that window's editor
        NSArray *parts = [arg componentsSeparatedByString:@"|"];
        NSWindow *w = windowLike(parts[0]);
        NSTextView *e = w ? findEditor(w.contentView) : nil;
        if (e && parts.count > 1) [e insertText:parts[1] replacementRange:e.selectedRange];
        say([NSString stringWithFormat:@"wintype %@ -> %d", parts[0], e != nil]);
        after(0.3); return;
    }
    if ([cmd isEqualToString:@"winconsole"]) { *handled = YES; // winconsole:<title>: the text that window's console shows, one line, newlines as ' | '
        NSWindow *w = windowLike(arg);
        NSTextView *c = w ? findConsole(w.contentView) : nil;
        NSString *s = [c.string ?: @"" stringByReplacingOccurrencesOfString:@"\n" withString:@" | "];
        if (s.length > 6000) s = [s substringFromIndex:s.length - 6000];
        say([NSString stringWithFormat:@"winconsole %@ -> found=%d text=%@", arg, c != nil, s]);
        after(0.1); return;
    }
    if ([cmd isEqualToString:@"wineditor"]) { *handled = YES; // wineditor:<title>: the file, length and first line of that window's editor
        NSWindow *w = windowLike(arg);
        NSTextView *e = w ? findEditor(w.contentView) : nil;
        NSString *file = @"";
        @try { file = [(id)e valueForKey:@"filePath"] ?: @""; } @catch (NSException *ex) {}
        NSString *s = e.string ?: @"";
        NSString *first = [[s componentsSeparatedByString:@"\n"] firstObject] ?: @"";
        say([NSString stringWithFormat:@"wineditor %@ -> window=%@ file=%@ len=%lu first=%@", arg, w.title, file, (unsigned long)s.length, first]);
        after(0.1); return;
    }
    if ([cmd isEqualToString:@"sheettext"]) { *handled = YES;
        // sheettext:N:text -> replace the text of the Nth editable NSTextView in the visible sheet (a SwiftUI TextEditor)
        NSRange c2 = [arg rangeOfString:@":"]; NSInteger n = [[arg substringToIndex:c2.location] integerValue]; NSString *text = [arg substringFromIndex:c2.location + 1];
        NSWindow *w = nil; for (NSWindow *x in NSApp.windows) if (x.isVisible && x.isSheet) w = x;
        NSMutableArray *views = [NSMutableArray array]; NSMutableArray *stack = w ? [NSMutableArray arrayWithObject:w.contentView] : [NSMutableArray array];
        while (stack.count) { NSView *v = stack.firstObject; [stack removeObjectAtIndex:0];
            if ([v isKindOfClass:NSTextView.class] && ((NSTextView *)v).isEditable && !((NSTextView *)v).isFieldEditor) [views addObject:v]; [stack addObjectsFromArray:v.subviews]; }
        NSTextView *tv2 = n < (NSInteger)views.count ? views[n] : nil;
        if (tv2) { [w makeFirstResponder:tv2]; [tv2 selectAll:nil]; [tv2 insertText:text replacementRange:tv2.selectedRange]; }
        say([NSString stringWithFormat:@"sheettext %ld/%lu -> %@", (long)n, (unsigned long)views.count, tv2 ? @"ok" : @"none"]);
        after(0.4); return;
    }
    if ([cmd isEqualToString:@"fieldp"]) { *handled = YES;
        // fieldp:placeholder:text -> fill the text field with that placeholder in any visible window and press Return
        NSRange c2 = [arg rangeOfString:@":"]; NSString *ph = [arg substringToIndex:c2.location]; NSString *text = [arg substringFromIndex:c2.location + 1];
        NSTextField *f = nil;
        for (NSWindow *w in NSApp.windows) { if (!w.isVisible || f) continue;
            NSMutableArray *stack = [NSMutableArray arrayWithObject:w.contentView];
            while (stack.count && !f) { NSView *v = stack.lastObject; [stack removeLastObject];
                if ([v isKindOfClass:NSTextField.class] && [((NSTextField *)v).placeholderString isEqualToString:ph]) f = (NSTextField *)v; else [stack addObjectsFromArray:v.subviews]; } }
        if (f) { [f.window makeFirstResponder:f]; NSText *ed = [f.window fieldEditor:YES forObject:f]; [ed selectAll:nil]; [ed insertText:text]; [ed doCommandBySelector:@selector(insertNewline:)]; }
        say([NSString stringWithFormat:@"fieldp %@ -> %@", ph, f ? @"ok" : @"none"]);
        after(0.6); return;
    }
    if ([cmd isEqualToString:@"text"]) { *handled = YES;
        // dump the editor text to the log (for checking auto-indent/format results)
        say([NSString stringWithFormat:@"TEXT<<<\n%@\n>>>", tv.string]);
        after(0.1); return;
    }
    if ([cmd isEqualToString:@"rclick"]) { *handled = YES; // rclick:x,yFromTop in window points: a right click posted to the app's own queue
        NSArray *xy = [arg componentsSeparatedByString:@","];
        NSWindow *w = mainWin();
        NSPoint p = NSMakePoint([xy[0] doubleValue], w.frame.size.height - [xy[1] doubleValue]);
        for (NSNumber *type in @[@(NSEventTypeRightMouseDown), @(NSEventTypeRightMouseUp)]) {
            NSEvent *e = [NSEvent mouseEventWithType:(NSEventType)type.integerValue location:p modifierFlags:0 timestamp:[[NSProcessInfo processInfo] systemUptime] windowNumber:w.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
            [NSApp postEvent:e atStart:NO];
        }
        say([NSString stringWithFormat:@"rclick %@", arg]);
        after(0.3); return;
    }
    if ([cmd isEqualToString:@"ctxmenu"]) { *handled = YES; // ctxmenu:x,yFromTop: asks the view under the point for its context menu, lists it, pops it up
        NSArray *xy = [arg componentsSeparatedByString:@","];
        NSWindow *w = mainWin();
        NSPoint p = NSMakePoint([xy[0] doubleValue], w.frame.size.height - [xy[1] doubleValue]);
        NSEvent *e = [NSEvent mouseEventWithType:NSEventTypeRightMouseDown location:p modifierFlags:0 timestamp:[[NSProcessInfo processInfo] systemUptime] windowNumber:w.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
        NSView *v = [w.contentView.superview hitTest:p];
        NSMenu *menu = nil; NSView *owner = v;
        while (owner && !(menu = [owner menuForEvent:e])) owner = owner.superview;
        [menu update];
        for (NSMenuItem *it in menu.itemArray) say([NSString stringWithFormat:@"ctxmenu item %@ enabled=%d", it.isSeparatorItem ? @"—" : it.title, it.isEnabled]);
        say([NSString stringWithFormat:@"ctxmenu %@ view=%@ owner=%@ items=%lu", arg, NSStringFromClass(v.class), NSStringFromClass(owner.class), (unsigned long)menu.numberOfItems]);
        if (menu && xy.count > 2) { // ctxmenu:x,y,index performs that item instead of showing the menu
            NSInteger i = [xy[2] integerValue];
            dispatch_async(dispatch_get_main_queue(), ^{ [menu performActionForItemAtIndex:i]; });
        } else if (menu) dispatch_async(dispatch_get_main_queue(), ^{ [NSMenu popUpContextMenu:menu withEvent:e forView:owner]; });
        after(1.0); return;
    }
    if ([cmd isEqualToString:@"editorctx"]) { *handled = YES; // editorctx:text lists the editor context menu at text; editorctx:text|Title also performs that item
        NSString *perform = nil;
        NSRange bar = [arg rangeOfString:@"|"];
        if (bar.location != NSNotFound) { perform = [arg substringFromIndex:bar.location + 1]; arg = [arg substringToIndex:bar.location]; }
        NSUInteger idx = tv.string.length > 0 ? tv.string.length - 1 : 0;
        if (arg.length > 0) {
            NSRange r = [tv.string rangeOfString:arg];
            if (r.location != NSNotFound) idx = r.location;
        }
        NSLayoutManager *lm = tv.layoutManager;
        NSUInteger g = [lm glyphIndexForCharacterAtIndex:idx];
        NSRect line = [lm lineFragmentRectForGlyphAtIndex:g effectiveRange:NULL];
        NSPoint p = arg.length > 0
            ? NSMakePoint([lm locationForGlyphAtIndex:g].x + tv.textContainerOrigin.x + 2, NSMidY(line) + tv.textContainerOrigin.y)
            : NSMakePoint(tv.bounds.size.width - 20, NSMaxY(tv.bounds) - 10);
        NSPoint winPt = [tv convertPoint:p toView:nil];
        NSEvent *e = [NSEvent mouseEventWithType:NSEventTypeRightMouseDown location:winPt modifierFlags:0 timestamp:[[NSProcessInfo processInfo] systemUptime] windowNumber:tv.window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
        NSMenu *menu = [tv menuForEvent:e];
        [menu update];
        NSMutableArray *topItems = [NSMutableArray array];
        for (NSMenuItem *it in menu.itemArray) {
            if (it.isSeparatorItem) continue;
            if (it.submenu) {
                NSMutableArray *sub = [NSMutableArray array];
                for (NSMenuItem *sit in it.submenu.itemArray) if (!sit.isSeparatorItem) [sub addObject:sit.title];
                [topItems addObject:[NSString stringWithFormat:@"%@[%lu:%@]", it.title, (unsigned long)sub.count, [sub componentsJoinedByString:@","]]];
            } else {
                [topItems addObject:it.title];
            }
        }
        say([NSString stringWithFormat:@"editorctx(%@) count=%lu items=%@", arg, (unsigned long)topItems.count, [topItems componentsJoinedByString:@" | "]]);
        if (perform) {
            NSMenu *targetMenu = nil;
            NSInteger idx = -1;
            NSMutableArray<NSMenu *> *queue = [NSMutableArray arrayWithObject:menu];
            while (queue.count && idx < 0) {
                NSMenu *cur = queue.firstObject;
                [queue removeObjectAtIndex:0];
                [cur update];
                NSInteger direct = [cur indexOfItemWithTitle:perform];
                if (direct >= 0) { targetMenu = cur; idx = direct; break; }
                for (NSMenuItem *it in cur.itemArray) if (it.submenu) [queue addObject:it.submenu];
            }
            if (targetMenu && idx >= 0) dispatch_async(dispatch_get_main_queue(), ^{ [targetMenu performActionForItemAtIndex:idx]; });
            say([NSString stringWithFormat:@"editorctx perform %@ -> %d", perform, targetMenu != nil && idx >= 0]);
            after(0.5); return;
        }
        after(0.1); return;
    }
    if ([cmd isEqualToString:@"wake"]) { *handled = YES; // an app-defined event so a modal loop notices a stopModal
        [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0] atStart:NO];
        say(@"wake"); after(0.3); return;
    }
    if ([cmd isEqualToString:@"selinfo"]) { *handled = YES;
        NSTextView *e = editor();
        NSString *file = @"";
        @try { file = [[(id)e valueForKey:@"filePath"] lastPathComponent] ?: @""; } @catch (NSException *ex) {}
        say([NSString stringWithFormat:@"selinfo window=%@ file=%@ caret=%lu len=%lu", mainWin().title, file, (unsigned long)e.selectedRange.location, (unsigned long)e.string.length]);
        after(0.1); return;
    }
    if ([cmd isEqualToString:@"focus"]) { *handled = YES;
        say([NSString stringWithFormat:@"firstResponder=%@ active=%d key=%@", NSStringFromClass([NSApp.keyWindow.firstResponder class]), NSApp.isActive, NSApp.keyWindow.title]);
        after(0.1); return;
    }
    if ([cmd isEqualToString:@"info"]) { *handled = YES;
        NSMutableArray *all = [NSMutableArray array];
        for (NSWindow *w in NSApp.windows) {
            NSMutableArray *stack = [NSMutableArray arrayWithObject:w.contentView ?: [NSView new]];
            while (stack.count) { NSView *v = stack.lastObject; [stack removeLastObject];
                if ([NSStringFromClass(v.class) containsString:@"GoLensTextView"]) [all addObject:[NSString stringWithFormat:@"len=%lu hidden=%d", (unsigned long)((NSTextView *)v).string.length, v.isHiddenOrHasHiddenAncestor]];
                [stack addObjectsFromArray:v.subviews]; }
        }
        say([NSString stringWithFormat:@"editors: %@", [all componentsJoinedByString:@", "]]);
        after(0.1); return;
    }
    if ([cmd isEqualToString:@"splitinfo"]) { *handled = YES;
        NSMutableArray<NSTextView *> *tvs = [NSMutableArray array];
        NSWindow *w = mainWin();
        NSMutableArray *stack = [NSMutableArray arrayWithObject:w.contentView ?: [NSView new]];
        while (stack.count) {
            NSView *v = stack.lastObject; [stack removeLastObject];
            if ([NSStringFromClass(v.class) containsString:@"GoLensTextView"] && !v.isHiddenOrHasHiddenAncestor) [tvs addObject:(NSTextView *)v];
            [stack addObjectsFromArray:v.subviews];
        }
        [tvs sortUsingComparator:^NSComparisonResult(NSTextView *a, NSTextView *b) {
            CGFloat ax = [a convertPoint:NSZeroPoint toView:nil].x;
            CGFloat bx = [b convertPoint:NSZeroPoint toView:nil].x;
            return ax < bx ? NSOrderedAscending : (ax > bx ? NSOrderedDescending : NSOrderedSame);
        }];
        NSMutableArray *desc = [NSMutableArray array];
        for (NSUInteger i = 0; i < tvs.count; i++) {
            NSTextView *t = tvs[i];
            NSString *fp = @"";
            @try { fp = [[t valueForKey:@"filePath"] lastPathComponent] ?: @""; } @catch (NSException *e) {}
            NSString *flat = [[t.string stringByReplacingOccurrencesOfString:@"\n" withString:@" "] stringByReplacingOccurrencesOfString:@"\t" withString:@" "];
            if (flat.length > 120) flat = [flat substringToIndex:120];
            [desc addObject:[NSString stringWithFormat:@"pane%lu[file=%@ x=%.0f len=%lu text=%@]", (unsigned long)i, fp, [t convertPoint:NSZeroPoint toView:nil].x, (unsigned long)t.string.length, flat]];
        }
        say([NSString stringWithFormat:@"splitinfo count=%lu %@", (unsigned long)tvs.count, [desc componentsJoinedByString:@" || "]]);
        after(0.1); return;
    }
    if ([cmd isEqualToString:@"button"]) { *handled = YES;
        NSButton *hit = nil;
        for (NSWindow *w in NSApp.windows) {
            NSMutableArray *stack = [NSMutableArray arrayWithObject:w.contentView];
            while (stack.count && !hit) { NSView *v = stack.lastObject; [stack removeLastObject];
                if ([v isKindOfClass:[NSButton class]] && [((NSButton *)v).title isEqualToString:arg]) hit = (NSButton *)v;
                else [stack addObjectsFromArray:v.subviews]; }
            if (hit) break;
        }
        [hit performClick:nil];
        say([NSString stringWithFormat:@"button %@ -> %d", arg, hit != nil]);
        after(0.6); return;
    }
    if ([cmd isEqualToString:@"panelclick"]) { *handled = YES;
        // In-process click at x,y points from the top-left of the first visible child panel.
        NSArray *xy = [arg componentsSeparatedByString:@","];
        NSWindow *panel = nil;
        for (NSWindow *w in NSApp.windows) if (w.isVisible && w.parentWindow && [w isKindOfClass:[NSPanel class]]) panel = w;
        if (!panel) { say(@"panelclick no panel"); after(0.1); return; }
        NSPoint p = NSMakePoint([xy[0] doubleValue], panel.frame.size.height - [xy[1] doubleValue]);
        NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:p modifierFlags:0 timestamp:[[NSProcessInfo processInfo] systemUptime] windowNumber:panel.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
        NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:p modifierFlags:0 timestamp:[[NSProcessInfo processInfo] systemUptime] windowNumber:panel.windowNumber context:nil eventNumber:0 clickCount:1 pressure:0];
        [NSApp postEvent:up atStart:NO];   // queued first: the button's tracking loop inside sendEvent dequeues it
        [panel sendEvent:down];
        say([NSString stringWithFormat:@"panelclick %@ in %@", arg, NSStringFromRect(panel.frame)]);
        after(0.5); return;
    }
    if ([cmd isEqualToString:@"clickpastline"]) { *handled = YES;
        // In-process click dx points past the end of the line containing text, given as text|dx.
        NSArray *parts = [arg componentsSeparatedByString:@"|"];
        NSString *needle = parts.firstObject;
        CGFloat dx = parts.count > 1 ? [parts[1] doubleValue] : 40;
        NSRange r = [tv.string rangeOfString:needle];
        if (r.location == NSNotFound) { say([NSString stringWithFormat:@"clickpastline %@ missing", needle]); after(0.1); return; }
        NSRange line = [tv.string lineRangeForRange:NSMakeRange(r.location, 0)];
        NSUInteger last = NSMaxRange(line) > line.location ? NSMaxRange(line) - 1 : line.location;
        NSRange g = [tv.layoutManager glyphRangeForCharacterRange:NSMakeRange(line.location, last - line.location) actualCharacterRange:NULL];
        NSRect rect = [tv.layoutManager boundingRectForGlyphRange:g inTextContainer:tv.textContainer];
        NSPoint p = NSMakePoint(NSMaxX(rect) + tv.textContainerOrigin.x + dx, NSMidY(rect) + tv.textContainerOrigin.y);
        NSPoint w = [tv convertPoint:p toView:nil];
        NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:w modifierFlags:0 timestamp:[[NSProcessInfo processInfo] systemUptime] windowNumber:tv.window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
        NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:w modifierFlags:0 timestamp:[[NSProcessInfo processInfo] systemUptime] windowNumber:tv.window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:0];
        [NSApp postEvent:up atStart:NO];
        [tv mouseDown:down];
        say([NSString stringWithFormat:@"clickpastline %@ at %@", needle, NSStringFromPoint(w)]);
        after(0.3); return;
    }
    if ([cmd isEqualToString:@"clickend"]) { *handled = YES;
        // In-process click near the right edge of the visible editor on the line containing arg.
        NSRange r = [tv.string rangeOfString:arg];
        if (r.location == NSNotFound) { say([NSString stringWithFormat:@"clickend %@ missing", arg]); after(0.1); return; }
        NSRange g = [tv.layoutManager glyphRangeForCharacterRange:NSMakeRange(r.location, 1) actualCharacterRange:NULL];
        NSRect rect = [tv.layoutManager boundingRectForGlyphRange:g inTextContainer:tv.textContainer];
        NSPoint p = NSMakePoint(NSMaxX(tv.visibleRect) - 22, NSMidY(rect) + tv.textContainerOrigin.y);
        NSPoint w = [tv convertPoint:p toView:nil];
        NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:w modifierFlags:0 timestamp:[[NSProcessInfo processInfo] systemUptime] windowNumber:tv.window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
        [tv mouseDown:down];
        say([NSString stringWithFormat:@"clickend %@ at %@", arg, NSStringFromPoint(w)]);
        after(0.3); return;
    }
    if ([cmd isEqualToString:@"hover"]) { *handled = YES;
        // In-process mouse move over the first occurrence of arg (never a system event).
        NSRange r = [tv.string rangeOfString:arg];
        if (r.location == NSNotFound) { say([NSString stringWithFormat:@"hover %@ missing", arg]); after(0.1); return; }
        NSRange g = [tv.layoutManager glyphRangeForCharacterRange:NSMakeRange(r.location + 1, 1) actualCharacterRange:NULL];
        NSRect rect = [tv.layoutManager boundingRectForGlyphRange:g inTextContainer:tv.textContainer];
        NSPoint p = NSMakePoint(NSMidX(rect) + tv.textContainerOrigin.x, NSMidY(rect) + tv.textContainerOrigin.y);
        NSPoint w = [tv convertPoint:p toView:nil];
        NSEvent *e = [NSEvent mouseEventWithType:NSEventTypeMouseMoved location:w modifierFlags:0 timestamp:[[NSProcessInfo processInfo] systemUptime] windowNumber:tv.window.windowNumber context:nil eventNumber:0 clickCount:0 pressure:0];
        [tv mouseMoved:e];
        say([NSString stringWithFormat:@"hover %@ at %@", arg, NSStringFromPoint(w)]);
        after(0.2); return;
    }
    if ([cmd isEqualToString:@"cmdhover"]) { *handled = YES;
        // cmdhover:<text>: in-process mouse move with Command held over the last character of the first occurrence of text,
        // then reports whether the start of text carries the underline and the cursor
        NSRange r = [tv.string rangeOfString:arg];
        if (r.location == NSNotFound) { say([NSString stringWithFormat:@"cmdhover %@ missing", arg]); after(0.1); return; }
        [tv scrollRangeToVisible:r];
        NSRange g = [tv.layoutManager glyphRangeForCharacterRange:NSMakeRange(NSMaxRange(r) - 1, 1) actualCharacterRange:NULL];
        NSRect rect = [tv.layoutManager boundingRectForGlyphRange:g inTextContainer:tv.textContainer];
        NSPoint w = [tv convertPoint:NSMakePoint(NSMidX(rect) + tv.textContainerOrigin.x, NSMidY(rect) + tv.textContainerOrigin.y) toView:nil];
        NSEvent *e = [NSEvent mouseEventWithType:NSEventTypeMouseMoved location:w modifierFlags:NSEventModifierFlagCommand timestamp:[[NSProcessInfo processInfo] systemUptime] windowNumber:tv.window.windowNumber context:nil eventNumber:0 clickCount:0 pressure:0];
        [tv mouseMoved:e];
        NSRange range = NSMakeRange(r.location, r.length);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSRange eff = NSMakeRange(0, 0);
            id u = [tv.layoutManager temporaryAttribute:NSUnderlineStyleAttributeName atCharacterIndex:range.location longestEffectiveRange:&eff inRange:range];
            BOOL whole = u != nil && NSMaxRange(eff) >= NSMaxRange(range);
            say([NSString stringWithFormat:@"cmdhover %@ underline=%d whole=%d hand=%d", arg, u != nil, whole, NSCursor.currentCursor == NSCursor.pointingHandCursor]);
            after(0.1);
        });
        return;
    }
    if ([cmd isEqualToString:@"issueclick"]) { *handled = YES;
        // In-process click near the right edge of the line holding arg (where inline issue annotations sit).
        NSRange r = [tv.string rangeOfString:arg];
        if (r.location == NSNotFound) { say([NSString stringWithFormat:@"issueclick %@ missing", arg]); after(0.1); return; }
        NSRange g = [tv.layoutManager glyphRangeForCharacterRange:NSMakeRange(r.location, 1) actualCharacterRange:NULL];
        NSRect line = [tv.layoutManager lineFragmentRectForGlyphAtIndex:g.location effectiveRange:NULL];
        CGFloat midY = NSMidY(line) + tv.textContainerOrigin.y;
        NSPoint p = NSZeroPoint;
        BOOL found = NO;
        if ([tv respondsToSelector:NSSelectorFromString(@"issueHitRectsDebug")]) {
            for (NSValue *v in (NSArray *)[tv valueForKey:@"issueHitRectsDebug"]) {
                NSRect ir = v.rectValue;
                if (midY >= NSMinY(ir) - 1 && midY <= NSMaxY(ir) + 1) { p = NSMakePoint(NSMidX(ir), NSMidY(ir)); found = YES; break; }
            }
        } else {
            p = NSMakePoint(NSMaxX(tv.visibleRect) - 60, midY); found = YES;
        }
        if (!found) { say([NSString stringWithFormat:@"issueclick %@ no issue on that line", arg]); after(0.1); return; }
        NSPoint w = [tv convertPoint:p toView:nil];
        NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:w modifierFlags:0 timestamp:[[NSProcessInfo processInfo] systemUptime] windowNumber:tv.window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
        NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:w modifierFlags:0 timestamp:[[NSProcessInfo processInfo] systemUptime] windowNumber:tv.window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:0];
        // Straight to the text view: in an inactive app a posted first click only activates the window.
        [tv mouseDown:down]; (void)up;
        NSView *hit = [tv.window.contentView.superview hitTest:w];
        say([NSString stringWithFormat:@"issueclick %@ at %@ hit=%@ key=%d", arg, NSStringFromPoint(w), NSStringFromClass(hit.class), tv.window.isKeyWindow]);
        after(0.6); return;
    }
    if ([cmd isEqualToString:@"mark"]) { *handled = YES; say([NSString stringWithFormat:@"mark %@", arg]); after(0.05); return; }
    if ([cmd isEqualToString:@"focusclass"]) { *handled = YES;
        NSView *hit = nil; NSWindow *hw = nil;
        for (NSWindow *w in NSApp.windows) {
            NSMutableArray *stack = [NSMutableArray arrayWithObject:w.contentView];
            while (stack.count && !hit) { NSView *v = stack.lastObject; [stack removeLastObject];
                if ([NSStringFromClass(v.class) containsString:arg]) hit = v; else [stack addObjectsFromArray:v.subviews]; }
            if (hit) { hw = w; break; }
        }
        say([NSString stringWithFormat:@"focusclass %@ -> %d", arg, hit && [hw makeFirstResponder:hit]]);
        after(0.3); return;
    }
    if ([cmd isEqualToString:@"panelframes"]) { *handled = YES;
        NSScrollView *sv = tv.enclosingScrollView;
        NSRect editorFrame = sv ? [sv.window convertRectToScreen:[sv convertRect:sv.bounds toView:nil]] : NSZeroRect;
        NSRange r = arg.length ? [tv.string rangeOfString:arg] : NSMakeRange(NSNotFound, 0);
        NSRect textFrame = r.location == NSNotFound ? NSZeroRect : [tv firstRectForCharacterRange:r actualRange:NULL];
        say([NSString stringWithFormat:@"panelframes editor=%@ text=%@", NSStringFromRect(editorFrame), NSStringFromRect(textFrame)]);
        for (NSWindow *w in NSApp.windows) {
            if (!w.isVisible || w == mainWin()) continue;
            say([NSString stringWithFormat:@"panelframes window=%@ frame=%@ insideEditor=%d", NSStringFromClass(w.class), NSStringFromRect(w.frame), NSContainsRect(NSInsetRect(editorFrame, -1, -1), w.frame)]);
        }
        after(0.1); return;
    }
    if ([cmd isEqualToString:@"edited"]) { *handled = YES; say([NSString stringWithFormat:@"edited %d", mainWin().isDocumentEdited]); after(0.1); return; }
    if ([cmd isEqualToString:@"edstate"]) { *handled = YES; // edstate[:tag]: caret line/col (1-based) and line text, font size, wrap, line fragments of the caret line and of the whole text (folding lowers it), minimap shown
        NSString *s = tv.string ?: @"";
        NSUInteger loc = MIN(tv.selectedRange.location, s.length), line = 1, lineStart = 0;
        for (NSUInteger i = 0; i < loc; i++) if ([s characterAtIndex:i] == '\n') { line++; lineStart = i + 1; }
        NSRange lr = [s lineRangeForRange:NSMakeRange(loc, 0)];
        NSString *text = [[s substringWithRange:lr] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSLayoutManager *lm = tv.layoutManager; NSTextContainer *tc = tv.textContainer;
        __block NSUInteger frags = 0, visual = 0;
        if (lm && tc) {
            [lm ensureLayoutForTextContainer:tc];
            NSRange all = NSMakeRange(0, lm.numberOfGlyphs);
            if (all.length) [lm enumerateLineFragmentsForGlyphRange:all usingBlock:^(NSRect r, NSRect u, NSTextContainer *c, NSRange g, BOOL *stop) { visual++; }];
            NSRange gr = [lm glyphRangeForCharacterRange:lr actualCharacterRange:NULL];
            if (gr.length) [lm enumerateLineFragmentsForGlyphRange:gr usingBlock:^(NSRect r, NSRect u, NSTextContainer *c, NSRange g, BOOL *stop) { frags++; }];
        }
        BOOL minimap = NO;
        NSMutableArray *stack = tv.window.contentView ? [NSMutableArray arrayWithObject:tv.window.contentView] : [NSMutableArray array];
        while (stack.count && !minimap) { NSView *v = stack.lastObject; [stack removeLastObject];
            if (v.isHiddenOrHasHiddenAncestor) continue;
            if ([NSStringFromClass(v.class) containsString:@"Minimap"]) minimap = YES; else [stack addObjectsFromArray:v.subviews]; }
        say([NSString stringWithFormat:@"edstate %@ line=%lu col=%lu font=%.1f wrap=%d frags=%lu visual=%lu minimap=%d len=%lu text=%@", arg.length ? arg : @"-",
             (unsigned long)line, (unsigned long)(loc - lineStart + 1), tv.font.pointSize, tc.containerSize.width < 1e7, (unsigned long)frags, (unsigned long)visual, minimap, (unsigned long)s.length, text]);
        after(0.1); return;
    }
    if ([cmd isEqualToString:@"pasteboard"]) { *handled = YES; // pasteboard: the general pasteboard's string, one line, newlines as ' | ' (first 2000 characters)
        NSString *p = [[NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString] ?: @"" stringByReplacingOccurrencesOfString:@"\n" withString:@" | "];
        if (p.length > 2000) p = [p substringToIndex:2000];
        say([NSString stringWithFormat:@"pasteboard %@", p]);
        after(0.1); return;
    }
    if ([cmd isEqualToString:@"panelkey"]) { *handled = YES; // key event sent straight to the visible popup panel (the fake key window would get it otherwise)
        NSWindow *panel = nil; for (NSWindow *w in NSApp.windows) if (w.isVisible && [NSStringFromClass(w.class) containsString:@"PopupPanel"]) panel = w;
        unsigned short code = (unsigned short)arg.intValue; NSString *chars = code == 53 ? @"\x1b" : code == 36 ? @"\r" : @"";
        NSEvent *e = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:[[NSProcessInfo processInfo] systemUptime] windowNumber:panel.windowNumber context:nil characters:chars charactersIgnoringModifiers:chars isARepeat:NO keyCode:code];
        [panel sendEvent:e]; [panel.firstResponder keyDown:e];
        say([NSString stringWithFormat:@"panelkey %@ -> %d", arg, panel != nil]); after(0.5); return;
    }
    if ([cmd isEqualToString:@"ghost"]) { *handled = YES; // inline AI suggestion state of the editor: hidden or visible|anchor|text
        NSString *state = [tv respondsToSelector:NSSelectorFromString(@"inlineSuggestionDebugState")] ? [tv valueForKey:@"inlineSuggestionDebugState"] : @"unsupported";
        say([NSString stringWithFormat:@"ghost %@", state]); after(0.1); return;
    }
    if ([cmd isEqualToString:@"ghostwait"]) { *handled = YES; // ghostwait:<seconds>: wait for a suggestion to appear; reports the time it took after this step started
        ghostLimit = arg.doubleValue > 0 ? arg.doubleValue : 5;
        ghostStart = NSProcessInfo.processInfo.systemUptime;
        ghostPoll();
        return;
    }
    if ([cmd isEqualToString:@"undotitle"]) { *handled = YES; say([NSString stringWithFormat:@"undotitle %@ canUndo=%d", tv.undoManager.undoActionName, tv.undoManager.canUndo]); after(0.1); return; }
}
