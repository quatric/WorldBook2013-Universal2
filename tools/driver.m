// Test driver injected (DYLD_INSERT_LIBRARIES) into a built app for trial
// runs; never part of the shipped app. Runs the steps in WB_DRIVE, one per
// line or separated by ';':
//   wait <seconds>        click <title>        type <text>
//   key <return|tab|esc>  shot <file.png>      views  (prints the view tree)
//   menu <item title>     windows
//   trace <level>         (translated runtime's XL_VERBOSE)
//   players               (state of AVPlayerLayers)
//   keys <text>           (key events per character)
//   mouse <x> <y>         move <x> <y>  (points in a `shot` of the key window)
// Buttons, matrix cells and menu items are found by title in all windows.
// WB_DRIVE_STEPS=1 logs each step as it starts.
#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#include <dlfcn.h>
#include <objc/runtime.h>

static NSMutableArray *sSteps;
static NSView *sLastHit;     // the view the last `mouse` landed on

static void Log(NSString *aFormat, ...)
{
	va_list args;
	va_start(args, aFormat);
	NSString *s = [[NSString alloc] initWithFormat:aFormat arguments:args];
	va_end(args);
	fprintf(stderr, "drive: %s\n", [s UTF8String]);
}

static NSArray *Windows(void)
{
	NSMutableArray *result = [NSMutableArray array];
	for (NSWindow *w in [NSApp orderedWindows])
		if ([w isVisible])
			[result addObject:w];
	return result;
}

static BOOL ClickIn(NSView *aView, NSString *aTitle)
{
	if ([aView isHidden])
		return NO;
	if ([aView isKindOfClass:[NSMatrix class]]) {
		NSMatrix *m = (NSMatrix *)aView;
		for (NSInteger r = 0; r < [m numberOfRows]; r++)
			for (NSInteger c = 0; c < [m numberOfColumns]; c++) {
				NSCell *cell = [m cellAtRow:r column:c];
				if ([[cell title] isEqualToString:aTitle] && [cell isEnabled]) {
					[m selectCellAtRow:r column:c];
					[m sendAction];
					return YES;
				}
			}
	}
	if ([aView isKindOfClass:[NSButton class]] && [(NSButton *)aView isEnabled]
		&& ([[(NSButton *)aView title] isEqualToString:aTitle] || [[(NSButton *)aView alternateTitle] isEqualToString:aTitle])) {
		[(NSButton *)aView performClick:nil];
		return YES;
	}
	for (NSView *v in [aView subviews])
		if (ClickIn(v, aTitle))
			return YES;
	return NO;
}

static BOOL MenuIn(NSMenu *aMenu, NSString *aTitle)
{
	for (NSInteger i = 0; i < [aMenu numberOfItems]; i++) {
		NSMenuItem *item = [aMenu itemAtIndex:i];
		if ([[item title] isEqualToString:aTitle]) {
			[aMenu performActionForItemAtIndex:i];
			return YES;
		}
		if ([item hasSubmenu] && MenuIn([item submenu], aTitle))
			return YES;
	}
	return NO;
}

static void Dump(NSView *aView, int aDepth)
{
	NSString *extra = @"";
	if ([aView respondsToSelector:@selector(title)] && ![aView isKindOfClass:[NSBox class]])
		extra = [NSString stringWithFormat:@" \"%@\"", [(id)aView title]];
	else if ([aView isKindOfClass:[NSTextField class]])
		extra = [NSString stringWithFormat:@" '%@'", [(NSTextField *)aView stringValue]];
	Log(@"%*s%@ %@%@%@", aDepth * 2, "", NSStringFromClass([aView class]), NSStringFromRect([aView frame]), extra, [aView isHidden] ? @" hidden" : @"");
	for (NSView *v in [aView subviews])
		Dump(v, aDepth + 1);
}

static void Shot(NSString *aPath)
{
	NSWindow *w = [NSApp modalWindow] ?: [NSApp keyWindow] ?: [Windows() firstObject];
	NSView *view = [[w contentView] superview] ?: [w contentView];
	if (view == nil) {
		Log(@"no window to shoot");
		return;
	}
	NSBitmapImageRep *rep = [view bitmapImageRepForCachingDisplayInRect:[view bounds]];
	[view cacheDisplayInRect:[view bounds] toBitmapImageRep:rep];
	[[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:aPath atomically:YES];
	Log(@"shot %@ (%@)", aPath, NSStringFromClass([w class]));
}

static void Key(NSString *aName)
{
	NSWindow *w = [NSApp modalWindow] ?: [NSApp keyWindow];
	NSWindow *target = w ?: [sLastHit window];
	NSDictionary *codes = @{ @"return": @[@"\r", @36], @"tab": @[@"\t", @48], @"esc": @[@"\x1b", @53] };
	NSArray *k = codes[aName];
	NSEvent *e = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:[target windowNumber] context:nil characters:k[0] charactersIgnoringModifiers:k[0] isARepeat:NO keyCode:[k[1] unsignedShortValue]];
	// no key window (the app is not activated): the clicked window becomes key
	// within the app; the event is queued so that it is the current event
	// while it is handled
	if (!w)
		[target makeKeyWindow];
	[NSApp postEvent:e atStart:NO];
}

// ANSI key codes, for apps that look at -keyCode as well as the characters
static unsigned short KeyCode(unichar aChar)
{
	static const char *rows = "asdfhgzxcv\0bqweryt123465=97-80]ou[ip\rlj'k;\\,/nm.\t `";
	unichar c = aChar >= 'A' && aChar <= 'Z' ? aChar - 'A' + 'a' : aChar;
	for (unsigned short i = 0; i < 51; i++)
		if (rows[i] == c && rows[i] != 0)
			return i;
	return 0;
}

// posts real key down/up events for each character, through the event queue
static void Keys(NSString *aText)
{
	NSWindow *w = [NSApp modalWindow] ?: [NSApp keyWindow] ?: Windows().firstObject;
	NSTimeInterval now = [[NSProcessInfo processInfo] systemUptime];
	for (NSUInteger i = 0; i < [aText length]; i++) {
		unichar ch = [aText characterAtIndex:i];
		NSString *s = [NSString stringWithCharacters:&ch length:1];
		NSEventModifierFlags m = (ch >= 'A' && ch <= 'Z') ? NSEventModifierFlagShift : 0;
		for (int up = 0; up < 2; up++)
			[NSApp postEvent:[NSEvent keyEventWithType:up ? NSEventTypeKeyUp : NSEventTypeKeyDown location:NSZeroPoint modifierFlags:m timestamp:now + i * 0.1 + up * 0.05 windowNumber:[w windowNumber] context:nil characters:s charactersIgnoringModifiers:[s lowercaseString] isARepeat:NO keyCode:KeyCode(ch)] atStart:NO];
	}
}

// reports the AVPlayerLayers in a layer tree (their content isn't in shots)
static void Players(CALayer *aLayer)
{
	if ([aLayer isKindOfClass:[AVPlayerLayer class]]) {
		AVPlayer *p = [(AVPlayerLayer *)aLayer player];
		AVPlayerItem *item = [p currentItem];
		Log(@"player %@: status %ld, item status %ld, rate %.2f, time %.2f of %.2f, ready %d, hidden %d, frame %@, error %@",
			[[(AVURLAsset *)[item asset] URL] lastPathComponent], (long)[p status], (long)[item status], [p rate],
			CMTimeGetSeconds([p currentTime]), CMTimeGetSeconds([item duration]), [(AVPlayerLayer *)aLayer isReadyForDisplay],
			[aLayer isHidden], NSStringFromRect(NSRectFromCGRect([aLayer frame])), [item error] ?: [p error]);
	}
	for (CALayer *l in [aLayer sublayers])
		Players(l);
}

// runs a block from the main run loop in common modes; unlike the main
// dispatch queue this also happens inside nested (modal, tracking) loops
// started by an earlier block
static void Later(void (^aBlock)(void))
{
	CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, aBlock);
	CFRunLoopWakeUp(CFRunLoopGetMain());
}

static void Next(void);

static void Run(NSString *aLine)
{
	NSString *line = [aLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
	NSRange space = [line rangeOfString:@" "];
	NSString *cmd = space.location == NSNotFound ? line : [line substringToIndex:space.location];
	NSString *arg = space.location == NSNotFound ? @"" : [line substringFromIndex:space.location + 1];
	if (getenv("WB_DRIVE_STEPS"))
		Log(@"step: %@", line);
	if ([cmd isEqualToString:@"wait"]) {
		NSTimer *t = [NSTimer timerWithTimeInterval:[arg doubleValue] repeats:NO block:^(NSTimer *aTimer) { Next(); }];
		[[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
		return;
	}
	if ([cmd isEqualToString:@"click"]) {
		BOOL done = NO;
		for (NSWindow *w in Windows())
			if ((done = ClickIn([[w contentView] superview] ?: [w contentView], arg)))
				break;
		Log(@"click %@: %@", arg, done ? @"ok" : @"NOT FOUND");
	} else if ([cmd isEqualToString:@"menu"]) {
		Log(@"menu %@: %@", arg, MenuIn([NSApp mainMenu], arg) ? @"ok" : @"NOT FOUND");
	} else if ([cmd isEqualToString:@"type"]) {
		// the app is not activated (that would take the user's keyboard), so
		// there may be no key window: the window of the last click stands in
		NSWindow *w = [NSApp modalWindow] ?: [NSApp keyWindow] ?: [sLastHit window];
		id responder = [w firstResponder];
		if (![responder respondsToSelector:@selector(insertText:)] && sLastHit) {
			NSView *v = sLastHit;
			while (v && ![v isKindOfClass:[NSTextField class]] && ![v isKindOfClass:[NSTextView class]])
				v = [v superview];
			if (v && [w makeFirstResponder:v])
				responder = [w firstResponder];
		}
		if ([responder respondsToSelector:@selector(insertText:)])
			[responder insertText:arg];
		Log(@"type into %@", NSStringFromClass([responder class]));
	} else if ([cmd isEqualToString:@"mouse"] || [cmd isEqualToString:@"move"] || [cmd isEqualToString:@"dclick"]) {
		// x y in the coordinates of a `shot` of the key window (top left origin)
		NSWindow *w = [NSApp modalWindow] ?: [NSApp keyWindow] ?: Windows().firstObject;
		NSArray *xy = [arg componentsSeparatedByString:@" "];
		NSPoint p = NSMakePoint([xy[0] doubleValue], NSHeight([w frame]) - [xy[1] doubleValue]);
		if ([cmd isEqualToString:@"move"]) {
			[w sendEvent:[NSEvent mouseEventWithType:NSEventTypeMouseMoved location:p modifierFlags:0 timestamp:0 windowNumber:[w windowNumber] context:nil eventNumber:0 clickCount:0 pressure:0]];
		} else {
			// queued, not sent: a mouse-down handler may run its own
			// tracking loop that waits for the mouse-up. The window is made key
			// within the app first (the app itself is not activated), or the
			// click would only bring it forward
			if (![w isKeyWindow] && [w canBecomeKeyWindow])
				[w makeKeyWindow];
			NSTimeInterval now = [[NSProcessInfo processInfo] systemUptime];
			NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:p modifierFlags:0 timestamp:now windowNumber:[w windowNumber] context:nil eventNumber:0 clickCount:1 pressure:1];
			NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:p modifierFlags:0 timestamp:now + 0.05 windowNumber:[w windowNumber] context:nil eventNumber:0 clickCount:1 pressure:0];
			[NSApp postEvent:down atStart:NO];
			[NSApp postEvent:up atStart:NO];
			if ([cmd isEqualToString:@"dclick"]) {
				// the second click of a double click
				[NSApp postEvent:[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:p modifierFlags:0 timestamp:now + 0.1 windowNumber:[w windowNumber] context:nil eventNumber:0 clickCount:2 pressure:1] atStart:NO];
				[NSApp postEvent:[NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:p modifierFlags:0 timestamp:now + 0.15 windowNumber:[w windowNumber] context:nil eventNumber:0 clickCount:2 pressure:0] atStart:NO];
			}
		}
		NSView *frame = [[w contentView] superview] ?: [w contentView];
		sLastHit = [frame hitTest:[frame convertPoint:p fromView:nil]];
		Log(@"%@ %@ in %@, hits %@ (app %@, window %@)", cmd, NSStringFromPoint(p), NSStringFromClass([w class]), [frame hitTest:[frame convertPoint:p fromView:nil]], [NSApp isActive] ? @"active" : @"inactive", [w isKeyWindow] ? @"key" : @"not key");
	} else if ([cmd isEqualToString:@"selrow"] || [cmd isEqualToString:@"openrow"]) {
		// synthetic clicks do not select table rows (the table's tracking asks
		// the hardware): selects row N of the table under the last click, or
		// the first table, and sends its action
		NSView *v = sLastHit;
		while (v && ![v isKindOfClass:[NSTableView class]])
			v = [v superview];
		if (!v) {
			NSMutableArray *todo = [NSMutableArray array];
			for (NSWindow *w in Windows())
				if ([w contentView])
					[todo addObject:[w contentView]];
			while ([todo count] && !v) {
				NSView *x = todo[0];
				[todo removeObjectAtIndex:0];
				if ([x isKindOfClass:[NSTableView class]])
					v = x;
				[todo addObjectsFromArray:[x subviews]];
			}
		}
		NSTableView *t = (NSTableView *)v;
		[t selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)[arg integerValue]] byExtendingSelection:NO];
		SEL a = [cmd isEqualToString:@"openrow"] ? [t doubleAction] : [t action];   // openrow: a double click
		if (a)
			[NSApp sendAction:a to:[t target] from:t];
		Log(@"selrow %@ in %@", arg, t ? NSStringFromClass([t class]) : @"(no table)");
	} else if ([cmd isEqualToString:@"tables"]) {
		// every table and outline view: rows and selection
		NSMutableArray *todo = [NSMutableArray array];
		for (NSWindow *w in Windows())
			if ([w contentView])
				[todo addObject:[w contentView]];
		while ([todo count]) {
			NSView *v = [todo lastObject];
			[todo removeLastObject];
			if ([v isKindOfClass:[NSTableView class]]) {
				NSTableView *t = (NSTableView *)v;
				Log(@"table %@ %p rows %ld selected %ld action %@ target %@", NSStringFromClass([t class]), t, (long)[t numberOfRows],
					(long)[t selectedRow], NSStringFromSelector([t action]), [t target]);
			}
			[todo addObjectsFromArray:[v subviews]];
		}
	} else if ([cmd isEqualToString:@"lfr"]) {
		// logs the next N line fragment rects text containers hand out
		static int left;
		static IMP orig;
		left = [arg intValue];
		SEL s = @selector(lineFragmentRectForProposedRect:atIndex:writingDirection:remainingRect:);
		Method m = class_getInstanceMethod([NSTextContainer class], s);
		if (!orig) {
			orig = method_getImplementation(m);
			method_setImplementation(m, imp_implementationWithBlock(^NSRect(NSTextContainer *tc, NSRect r, NSUInteger i, NSWritingDirection d, NSRect *rem) {
				NSRect o = ((NSRect(*)(id, SEL, NSRect, NSUInteger, NSWritingDirection, NSRect *))orig)(tc, s, r, i, d, rem);
				if (left > 0) {
					left--;
					Log(@"lfr %@ %@ i=%lu -> %@ rem %@", NSStringFromClass([tc class]), NSStringFromRect(r), (unsigned long)i,
						NSStringFromRect(o), rem ? NSStringFromRect(*rem) : @"-");
				}
				return o;
			}));
			SEL s2 = NSSelectorFromString(@"_layoutLineFragmentStartingWithGlyphAtIndex:characterIndex:atPoint:renderingContext:");
			Method m2 = class_getInstanceMethod([NSATSTypesetter class], s2);
			IMP o2 = method_getImplementation(m2);
			method_setImplementation(m2, imp_implementationWithBlock(^long(id ts, NSUInteger *g, NSUInteger *ci, NSPoint *p, id ctx) {
				NSUInteger g0 = g ? *g : 99999, c0 = ci ? *ci : 99999;
				NSPoint p0 = p ? *p : NSZeroPoint;
				long r = ((long(*)(id, SEL, NSUInteger *, NSUInteger *, NSPoint *, id))o2)(ts, s2, g, ci, p, ctx);
				if (left > 0)
					Log(@"line g %lu->%lu c %lu->%lu p %@->%@ ret %ld (%p %p %p)", (unsigned long)g0, (unsigned long)(g ? *g : 0), (unsigned long)c0,
						(unsigned long)(ci ? *ci : 0), NSStringFromPoint(p0), NSStringFromPoint(p ? *p : NSZeroPoint), r, g, ci, p);
				return r;
			}));
			SEL s3 = @selector(getLineFragmentRect:usedRect:remainingRect:forStartingGlyphAtIndex:proposedRect:lineSpacing:paragraphSpacingBefore:paragraphSpacingAfter:);
			Class tc = NSClassFromString(@"HSExtendedTypesetterATS");
			Method m3 = tc ? class_getInstanceMethod(tc, s3) : NULL;
			if (m3) {
				IMP o3 = method_getImplementation(m3);
				method_setImplementation(m3, imp_implementationWithBlock(^(id ts, NSRect *lf, NSRect *u, NSRect *rem, NSUInteger g, NSRect pr, CGFloat ls, CGFloat b, CGFloat a) {
					if (left > 0)
						Log(@"glfr in g %lu pr %@ %p %p %p", (unsigned long)g, NSStringFromRect(pr), lf, u, rem);
					((void(*)(id, SEL, NSRect *, NSRect *, NSRect *, NSUInteger, NSRect, CGFloat, CGFloat, CGFloat))o3)(ts, s3, lf, u, rem, g, pr, ls, b, a);
					if (left > 0)
						Log(@"glfr g %lu pr %@ ls %g %g %g -> lf %@ used %@ rem %@", (unsigned long)g, NSStringFromRect(pr), ls, b, a,
							lf ? NSStringFromRect(*lf) : @"-", u ? NSStringFromRect(*u) : @"-", rem ? NSStringFromRect(*rem) : @"-");
				}));
			}
		}
	} else if ([cmd isEqualToString:@"main"]) {
		// the last clicked (or first) window answers as main and key from here on, as if
		// the app were active (it is never activated, so AppKit will not make it either)
		static NSWindow *sMain;
		sMain = [sLastHit window] ?: Windows().firstObject;
		static BOOL done;
		if (!done) {
			done = YES;
			for (NSString *sn in @[@"isMainWindow", @"isKeyWindow"]) {
				SEL sel = NSSelectorFromString(sn);
				Method m = class_getInstanceMethod([NSWindow class], sel);
				IMP o = method_getImplementation(m);
				method_setImplementation(m, imp_implementationWithBlock(^BOOL(NSWindow *w) {
					return w == sMain || ((BOOL (*)(id, SEL))o)(w, sel);
				}));
			}
		}
		void (*flush)(void) = dlsym(RTLD_DEFAULT, "xl_msgcache_flush");   // the runtime caches IMPs
		if (flush)
			flush();
		[sMain makeFirstResponder:[sMain firstResponder]];
		[[sMain toolbar] validateVisibleItems];
		Log(@"main %@", [sMain title]);
	} else if ([cmd isEqualToString:@"boxes"]) {
		NSMutableArray *todo = [NSMutableArray array];
		for (NSWindow *w in Windows())
			[todo addObject:[w contentView]];
		while ([todo count]) {
			NSView *v = [todo lastObject];
			[todo removeLastObject];
			if ([v isKindOfClass:[NSBox class]]) {
				NSBox *b = (NSBox *)v;
				Log(@"box %p title '%@' position %ld type %ld border %ld titleRect %@", b, [b title], (long)[b titlePosition],
					(long)[b boxType], (long)[b borderType], NSStringFromRect([b titleRect]));
			}
			[todo addObjectsFromArray:[v subviews]];
		}
	} else if ([cmd isEqualToString:@"toolbar"]) {
		// each window's toolbar items: enabled, action, target
		for (NSWindow *w in Windows())
			for (NSToolbarItem *it in [[w toolbar] items])
				Log(@"toolbar %@ '%@' enabled %d action %@ target %@ view %@ first responder %@ key %d", [it itemIdentifier], [it label],
					[it isEnabled], NSStringFromSelector([it action]), [it target], [[it view] class], [w firstResponder], [w isKeyWindow]);
	} else if ([cmd isEqualToString:@"ftrace"]) {
		// logs every translated function entered from here on (1) or stops (0)
		int *v = dlsym(RTLD_DEFAULT, "xl_trace_on");
		if (v)
			*v = [arg intValue];
		Log(@"ftrace %@%@", arg, v ? @"" : @" (no runtime)");
	} else if ([cmd isEqualToString:@"trace"]) {
		// sets the translated runtime's verbosity from here on
		int *v = dlsym(RTLD_DEFAULT, "xl_verbose");
		if (v)
			*v = [arg intValue];
		Log(@"trace %@%@", arg, v ? @"" : @" (no runtime)");
	} else if ([cmd isEqualToString:@"players"]) {
		for (NSWindow *w in Windows())
			Players([[[w contentView] superview] ?: [w contentView] layer]);
		Log(@"players done");
	} else if ([cmd isEqualToString:@"keys"]) {
		Keys(arg);
		Log(@"keys %@", arg);
	} else if ([cmd isEqualToString:@"key"]) {
		Key(arg);
	} else if ([cmd isEqualToString:@"shot"]) {
		Shot(arg);
	} else if ([cmd isEqualToString:@"views"]) {
		for (NSWindow *w in Windows()) {
			Log(@"window %@ %@ \"%@\"", NSStringFromClass([w class]), NSStringFromRect([w frame]), [w title]);
			Dump([w contentView], 1);
		}
	} else if ([cmd isEqualToString:@"wshot"]) {
		// the app's frontmost window as the window server shows it (OpenGL content included)
		NSWindow *w = [Windows() firstObject];
		if (w) {
			unsetenv("DYLD_INSERT_LIBRARIES");
			NSString *c = [NSString stringWithFormat:@"/usr/sbin/screencapture -x -o -l %ld '%@'", (long)[w windowNumber], arg];
			system([c UTF8String]);
			Log(@"wshot %@ (window %ld)", arg, (long)[w windowNumber]);
		} else
			Log(@"wshot: no window");
	} else if ([cmd isEqualToString:@"windows"]) {
		for (NSWindow *w in Windows())
			Log(@"window %@ %@ \"%@\"%@ #%ld", NSStringFromClass([w class]), NSStringFromRect([w frame]), [w title], w == [NSApp modalWindow] ? @" modal" : @"", (long)[w windowNumber]);
	}
	Next();
}

static void Next(void)
{
	if ([sSteps count] == 0)
		return;
	NSString *line = sSteps[0];
	[sSteps removeObjectAtIndex:0];
	Later(^{
		@try {
			Run(line);
		} @catch (NSException *e) {
			Log(@"exception in '%@': %@\n%@", line, e, [[e callStackSymbols] componentsJoinedByString:@"\n"]);
			Next();
		}
	});
}

// The app under test usually runs in the background (often with the screen
// locked), where a window spends a click on activating the app unless the
// view under it accepts first mouse; let every view take it, as the
// Classroom's MBFirstMouseView does.
static BOOL AcceptsFirstMouse(id self, SEL _cmd, NSEvent *anEvent)
{
	return YES;
}

// WB_SKIP_AUTOMATION=1: the Typing Speed Gauge login-item methods talk to
// System Events through AppleScript, which blocks on the Automation consent
// prompt until someone answers it; answer "not a login item" and do nothing.
static BOOL NotLoginItem(id self, SEL _cmd)
{
	return NO;
}

static void SkipAutomation(void)
{
	Class c = NSClassFromString(@"MBUtilities");
	for (NSString *name in @[@"isTypingSpeedGaugeLoginItem", @"makeTypingSpeedGaugeLoginItem", @"deleteTypingSpeedGaugeLoginItem"]) {
		SEL sel = NSSelectorFromString(name);
		Method m = class_getInstanceMethod(c, sel) ?: class_getClassMethod(c, sel);
		if (m)
			method_setImplementation(m, (IMP)NotLoginItem);   // also fine for the void ones
		Log(@"%@ %@", name, m ? @"skipped" : @"not found");
	}
}

// tracking loops ask the hardware whether the button is still down: while a
// synthetic mouse-down is being handled, it is
static NSUInteger PressedMouseButtons(id self, SEL _cmd)
{
	NSEventType t = [[NSApp currentEvent] type];
	return t == NSEventTypeLeftMouseDown || t == NSEventTypeLeftMouseDragged ? 1 : 0;
}

__attribute__((constructor)) static void Start(void)
{
	const char *steps = getenv("WB_DRIVE");
	if (steps == NULL)
		return;
	method_setImplementation(class_getClassMethod([NSEvent class], @selector(pressedMouseButtons)), (IMP)PressedMouseButtons);
	// clicks reach windows that are not key (the app is never activated):
	// every class with its own -acceptsFirstMouse: accepts it
	unsigned nc = 0;
	Class *cl = objc_copyClassList(&nc);
	for (unsigned i = 0; i < nc; i++) {
		unsigned nm = 0;
		Method *ms = class_copyMethodList(cl[i], &nm);
		for (unsigned k = 0; k < nm; k++)
			if (method_getName(ms[k]) == @selector(acceptsFirstMouse:))
				method_setImplementation(ms[k], (IMP)AcceptsFirstMouse);
		free(ms);
	}
	free(cl);
	if (getenv("WB_SKIP_AUTOMATION"))
		[[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationWillFinishLaunchingNotification object:nil queue:nil usingBlock:^(NSNotification *n) { SkipAutomation(); }];
	sSteps = [[NSMutableArray alloc] init];
	for (NSString *s in [[NSString stringWithUTF8String:steps] componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@";\n"]])
		if ([[s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] length] != 0)
			[sSteps addObject:s];
	// Run loop timers in common modes keep firing inside modal sessions.
	NSTimer *t = [NSTimer timerWithTimeInterval:0.1 repeats:NO block:^(NSTimer *aTimer) { Next(); }];
	[[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
}
