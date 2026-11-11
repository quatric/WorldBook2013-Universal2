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
#define GL_SILENCE_DEPRECATION
#import <OpenGL/gl.h>
#import <AVFoundation/AVFoundation.h>
#import <WebKit/WebKit.h>
#import <ImageIO/ImageIO.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <objc/message.h>


static NSMutableArray *sSteps;
static NSView *sLastHit;     // the view the last `mouse` landed on


// tst:///<file> and stm://TST/<file> serve a file the way the encyclopedia's protocols do: a plain
// response with no type, then all the data at once
static void Log(NSString *aFormat, ...);

@interface TstProtocol : NSURLProtocol
@end
@implementation TstProtocol
static NSMutableDictionary *TstMap;   // URL -> file (tstmap step)
+ (BOOL)canInitWithRequest:(NSURLRequest *)r { return [[[r URL] scheme] isEqualToString:@"tst"] || [[[r URL] host] isEqualToString:@"TST"] || TstMap[[[r URL] absoluteString]]; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)r { return r; }
- (void)startLoading
{
	NSString *mapped = TstMap[[[[self request] URL] absoluteString]];
	NSData *d = [NSData dataWithContentsOfFile:mapped ?: [[[self request] URL] path]];
	Log(@"tst start %@ thread %@", [[[self request] URL] lastPathComponent], [NSThread isMainThread] ? @"main" : [NSThread currentThread]);
	NSURLResponse *res = [[NSURLResponse alloc] initWithURL:[[self request] URL] MIMEType:nil expectedContentLength:-1 textEncodingName:nil];
	[[self client] URLProtocol:self didReceiveResponse:res cacheStoragePolicy:NSURLCacheStorageNotAllowed];
	[[self client] URLProtocol:self didLoadData:d ?: [NSData data]];
	[[self client] URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end

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
		BOOL found = MenuIn([NSApp mainMenu], arg);
		Log(@"menu %@: %@", arg, found ? @"ok" : @"NOT FOUND");
		if (!found)   // the titles there are, for the next try
			for (NSMenuItem *top in [[NSApp mainMenu] itemArray])
				Log(@"  menu %@: %@", [top title], [[[top submenu] itemArray] valueForKey:@"title"]);
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
				Log(@"box %p frame %@ title '%@' position %ld type %ld border %ld titleRect %@", b, NSStringFromRect([b frame]), [b title], (long)[b titlePosition],
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
	} else if ([cmd isEqualToString:@"tbclick"]) {
		// tbclick <label>: performs the toolbar item with that label (key window first)
		BOOL found = NO;
		for (NSWindow *w in Windows())
			for (NSToolbarItem *it in [[w toolbar] items])
				if (!found && [[it label] isEqualToString:arg]) {
					found = YES;
					[NSApp sendAction:[it action] to:[it target] from:it];
				}
		Log(@"tbclick %@: %@", arg, found ? @"ok" : @"not found");
	} else if ([cmd isEqualToString:@"kvc"]) {
		// kvc <view class> <key>...: the values of the first such view in the windows
		NSArray *w = [arg componentsSeparatedByString:@" "];
		NSMutableArray *todo = [NSMutableArray array];
		for (NSWindow *win in Windows())
			[todo addObject:[win contentView]];
		while ([todo count]) {
			NSView *v = [todo lastObject];
			[todo removeLastObject];
			if ([NSStringFromClass([v class]) isEqualToString:w[0]]) {
				for (NSString *k in [w subarrayWithRange:NSMakeRange(1, w.count - 1)]) {
					id val = nil;
					// key/sub1,sub2: an array's elements, each with those keys
					NSArray *ks = [k componentsSeparatedByString:@"/"];
					@try { val = [v valueForKey:ks[0]]; } @catch (id e) { val = e; }
					if (ks.count > 1 && [val isKindOfClass:[NSArray class]]) {
						Log(@"kvc %@.%@: %lu", w[0], ks[0], (unsigned long)[val count]);
						for (id el in val) {
							NSMutableString *s = [NSMutableString stringWithFormat:@"  %@", NSStringFromClass([el class])];
							if ([ks[1] isEqualToString:@"*"]) {
								Log(@"%@ %@", s, [[el description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "]);
								continue;
							}
							for (NSString *sk in [ks[1] componentsSeparatedByString:@","]) {
								id sv;
								@try { sv = [el valueForKeyPath:sk]; } @catch (id e) { sv = @"?"; }
								[s appendFormat:@" %@=%@", sk, sv];
							}
							Log(@"%@", s);
						}
					} else
						Log(@"kvc %@.%@ = %@", w[0], k, val);
				}
				break;
			}
			[todo addObjectsFromArray:[v subviews]];
		}
	} else if ([cmd isEqualToString:@"webdump"]) {
		// webdump [bytes]: every web view's frames, their URLs and the start of their source
		NSMutableArray *todo = [NSMutableArray array];
		for (NSWindow *w in Windows())
			[todo addObject:[w contentView]];
		NSUInteger n = [arg integerValue] ?: 600;
		while ([todo count]) {
			NSView *v = [todo lastObject];
			[todo removeLastObject];
			if ([v isKindOfClass:[WebView class]]) {
				NSMutableArray *frames = [NSMutableArray arrayWithObject:[(WebView *)v mainFrame]];
				while ([frames count]) {
					WebFrame *f = frames[0];
					[frames removeObjectAtIndex:0];
					[frames addObjectsFromArray:[f childFrames]];
					NSData *d = [[f dataSource] data];
					NSString *s = d ? [[NSString alloc] initWithData:[d subdataWithRange:NSMakeRange(0, MIN(n, d.length))] encoding:NSISOLatin1StringEncoding] : @"(none)";
					NSMutableString *hex = [NSMutableString string];
					for (NSUInteger i = 0; i < MIN(48u, d.length); i++)
						[hex appendFormat:@"%02x", ((const uint8_t *)d.bytes)[i]];
					Log(@"web frame %@ %@ %lu bytes, mime %@: %@\n%@", [f name], [[[f dataSource] request] URL], (unsigned long)d.length,
						[[[f dataSource] response] MIMEType], hex, [s stringByReplacingOccurrencesOfString:@"\0" withString:@"."]);
				}
			}
			[todo addObjectsFromArray:[v subviews]];
		}
	} else if ([cmd isEqualToString:@"weburl"]) {
		// weburl <url>: loads the URL into the first web view's main frame
		NSMutableArray *todo = [NSMutableArray array];
		for (NSWindow *w in Windows())
			[todo addObject:[w contentView]];
		BOOL done = NO;
		while ([todo count] && !done) {
			NSView *v = [todo lastObject];
			[todo removeLastObject];
			if ([v isKindOfClass:[WebView class]]) {
				[[(WebView *)v mainFrame] loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:arg]]];
				done = YES;
			}
			[todo addObjectsFromArray:[v subviews]];
		}
		Log(@"weburl %@: %@", arg, done ? @"loading" : @"no web view");
	} else if ([cmd isEqualToString:@"imgtest"]) {
		// imgtest <file>: decodes a picture file in this process with ImageIO and NSImage
		NSData *d = [NSData dataWithContentsOfFile:arg];
		CGImageSourceRef src = d ? CGImageSourceCreateWithData((__bridge CFDataRef)d, NULL) : NULL;
		CGImageRef img = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
		Log(@"imgtest %@: %lu bytes, source %@ status %d type %@, image %zux%zu", arg, (unsigned long)d.length,
			src ? @"yes" : @"no", src ? (int)CGImageSourceGetStatus(src) : -99, src ? (__bridge NSString *)CGImageSourceGetType(src) : @"-",
			img ? CGImageGetWidth(img) : 0, img ? CGImageGetHeight(img) : 0);
		NSImage *ni = [[NSImage alloc] initWithData:d];
		NSBitmapImageRep *br = [NSBitmapImageRep imageRepWithData:d];
		Log(@"imgtest NSImage %@ valid %d, bitmap rep %ldx%ld", NSStringFromSize(ni.size), ni.isValid, (long)br.pixelsWide, (long)br.pixelsHigh);
		if (img) CGImageRelease(img);
		if (src) CFRelease(src);
	} else if ([cmd isEqualToString:@"webhtml"]) {
		// webhtml <file>: loads the HTML file's text into the first web view, with its folder as base URL
		NSString *html = [NSString stringWithContentsOfFile:arg encoding:NSUTF8StringEncoding error:nil];
		NSMutableArray *todo = [NSMutableArray array];
		for (NSWindow *w in Windows())
			[todo addObject:[w contentView]];
		BOOL done = NO;
		while ([todo count] && !done) {
			NSView *v = [todo lastObject];
			[todo removeLastObject];
			if ([v isKindOfClass:[WebView class]]) {
				[[(WebView *)v mainFrame] loadHTMLString:html baseURL:[NSURL fileURLWithPath:[arg stringByDeletingLastPathComponent] isDirectory:YES]];
				done = YES;
			}
			[todo addObjectsFromArray:[v subviews]];
		}
		Log(@"webhtml %@: %@", arg, done ? @"loading" : @"no web view");
	} else if ([cmd isEqualToString:@"webjs"] || [cmd isEqualToString:@"webjsf"]) {
		// webjs <script>: runs the script in every web view's main frame and logs the result
		// (webjsf <file>: the script in a file, since steps split at semicolons and newlines)
		if ([cmd isEqualToString:@"webjsf"])
			arg = [NSString stringWithContentsOfFile:arg encoding:NSUTF8StringEncoding error:nil];
		NSMutableArray *todo = [NSMutableArray array];
		for (NSWindow *w in Windows())
			[todo addObject:[w contentView]];
		while ([todo count]) {
			NSView *v = [todo lastObject];
			[todo removeLastObject];
			if ([v isKindOfClass:[WebView class]])
				Log(@"webjs %@", [(WebView *)v stringByEvaluatingJavaScriptFromString:arg]);
			[todo addObjectsFromArray:[v subviews]];
		}
	} else if ([cmd isEqualToString:@"websub"]) {
		// websub: the subresources WebKit holds for each web view's main frame
		NSMutableArray *todo = [NSMutableArray array];
		for (NSWindow *w in Windows())
			[todo addObject:[w contentView]];
		while ([todo count]) {
			NSView *v = [todo lastObject];
			[todo removeLastObject];
			if ([v isKindOfClass:[WebView class]])
				for (WebResource *r in [[[(WebView *)v mainFrame] dataSource] subresources]) {
					NSData *d = [r data];
					const unsigned char *b = [d bytes];
					Log(@"websub %@ %@ %lu bytes %02x%02x%02x%02x", [r URL], [r MIMEType], (unsigned long)d.length,
						d.length > 3 ? b[0] : 0, d.length > 3 ? b[1] : 0, d.length > 3 ? b[2] : 0, d.length > 3 ? b[3] : 0);
				}
			[todo addObjectsFromArray:[v subviews]];
		}
	} else if ([cmd isEqualToString:@"weberr"]) {
		// weberr <class>: logs the errors passed to that class's frame and resource load delegate failure methods
		Class c = NSClassFromString(arg);
		SEL sels[] = {@selector(webView:didFailLoadWithError:forFrame:), @selector(webView:didFailProvisionalLoadWithError:forFrame:),
			@selector(webView:resource:didFailLoadingWithError:fromDataSource:)};
		for (int i = 0; i < 3; i++) {
			Method m = class_getInstanceMethod(c, sels[i]);
			if (!m) { Log(@"weberr %@ lacks %@", arg, NSStringFromSelector(sels[i])); continue; }
			SEL sel = sels[i];
			if (i < 2) {
				void (*orig)(id, SEL, id, id, id) = (void *)method_getImplementation(m);
				method_setImplementation(m, imp_implementationWithBlock(^(id self, id wv, NSError *e, WebFrame *f) {
					Log(@"%@ %@ frame %@: %@", NSStringFromSelector(sel), [[[f provisionalDataSource] ?: [f dataSource] request] URL], [f name], e);
					orig(self, sel, wv, e, f);
				}));
			} else {
				void (*orig)(id, SEL, id, id, id, id) = (void *)method_getImplementation(m);
				method_setImplementation(m, imp_implementationWithBlock(^(id self, id wv, id ident, NSError *e, WebDataSource *ds) {
					Log(@"resource failed: %@", e);
					orig(self, sel, wv, ident, e, ds);
				}));
			}
			Log(@"weberr hooked %@", NSStringFromSelector(sel));
		}
	} else if ([cmd isEqualToString:@"tstmap"]) {
		// tstmap <url> <file>: the test protocol serves the file for that URL
		NSArray *w = [arg componentsSeparatedByString:@" "];
		if (!TstMap) TstMap = [NSMutableDictionary dictionary];
		TstMap[w[0]] = w[1];
		[NSURLProtocol registerClass:[TstProtocol class]];
		Log(@"tstmap %@", w[0]);
	} else if ([cmd isEqualToString:@"tstproto"]) {
		[NSURLProtocol registerClass:[TstProtocol class]];
		Log(@"tstproto registered");
	} else if ([cmd isEqualToString:@"webres"]) {
		// webres: logs resource load failures and finishes of every web view's resource load delegate
		NSMutableArray *todo = [NSMutableArray array];
		for (NSWindow *w in Windows())
			[todo addObject:[w contentView]];
		while ([todo count]) {
			NSView *v = [todo lastObject];
			[todo removeLastObject];
			if ([v isKindOfClass:[WebView class]]) {
				id d = [(WebView *)v resourceLoadDelegate];
				Class c = [d class];
				Log(@"webres delegate %@", c ? NSStringFromClass(c) : @"(none)");
				if (c) {
					class_addMethod(c, @selector(webView:resource:didFailLoadingWithError:fromDataSource:), imp_implementationWithBlock(^(id self, WebView *wv, id ident, NSError *e, WebDataSource *ds) {
						Log(@"resource FAILED %@: %@", [[ds request] URL], e);
					}), "v@:@@@@");
					class_addMethod(c, @selector(webView:resource:didFinishLoadingFromDataSource:), imp_implementationWithBlock(^(id self, WebView *wv, id ident, WebDataSource *ds) {
						Log(@"resource finished %@", [[ds request] URL]);
					}), "v@:@@@");
				}
			}
			[todo addObjectsFromArray:[v subviews]];
		}
	} else if ([cmd isEqualToString:@"webfail"]) {
		// webfail <class>: logs the errors of its frame load delegate methods
		Class c = NSClassFromString(arg);
		for (NSString *s in @[@"webView:didFailProvisionalLoadWithError:forFrame:", @"webView:didFailLoadWithError:forFrame:"]) {
			Method m = c ? class_getInstanceMethod(c, NSSelectorFromString(s)) : NULL;
			if (!m)
				continue;
			IMP orig = method_getImplementation(m);
			SEL sel = NSSelectorFromString(s);
			method_setImplementation(m, imp_implementationWithBlock(^(id self, WebView *wv, NSError *e, WebFrame *f) {
				Log(@"%@ %@ (url %@)", s, e, [[[f provisionalDataSource] ?: [f dataSource] request] URL]);
				((void (*)(id, SEL, id, id, id))orig)(self, sel, wv, e, f);
			}));
		}
		Log(@"webfail %@: %@", arg, c ? @"hooked" : @"no class");
	} else if ([cmd isEqualToString:@"gltrace"]) {
		// logs the guest's OpenGL calls with their argument words (1) or stops (0)
		int *v = dlsym(RTLD_DEFAULT, "xl_gl_trace");
		if (v)
			*v = [arg intValue];
		Log(@"gltrace %@%@", arg, v ? @"" : @" (no runtime)");
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
	} else if ([cmd isEqualToString:@"glshot"]) {
		// glshot <file>: the first OpenGL view, drawn now and read back from its
		// context (works while the window server cannot capture, display asleep)
		NSMutableArray *todo = [NSMutableArray array];
		for (NSWindow *w in Windows())
			[todo addObject:[w contentView]];
		NSOpenGLView *gv = nil;
		while ([todo count] && !gv) {
			NSView *v = [todo lastObject];
			[todo removeLastObject];
			if ([v respondsToSelector:@selector(openGLContext)] && [(id)v openGLContext])
				gv = (NSOpenGLView *)v;
			else if ([NSStringFromClass([v class]) containsString:@"GL"]) {
				NSMutableString *chain = [NSMutableString string];
				for (Class c = [v class]; c; c = class_getSuperclass(c))
					[chain appendFormat:@" %@", NSStringFromClass(c)];
				Log(@"glshot: %@ has no context:%@", v, chain);
			}
			[todo addObjectsFromArray:[v subviews]];
		}
		if (!gv) {
			Log(@"glshot: no OpenGL view");
		} else {
			NSOpenGLContext *ctx = [gv openGLContext];
			NSSize px = [gv convertSizeToBacking:[gv bounds].size];
			GLint vp[4];
			[ctx makeCurrentContext];
			glGetIntegerv(GL_VIEWPORT, vp);
			int W = vp[2] > 0 ? vp[2] : (int)px.width, H = vp[3] > 0 ? vp[3] : (int)px.height;
			NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:W pixelsHigh:H bitsPerSample:8
				samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:W * 4 bitsPerPixel:32];
			glReadBuffer(GL_FRONT);
			glPixelStorei(GL_PACK_ALIGNMENT, 1);
			unsigned char *b = [rep bitmapData];
			glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, b);
			unsigned char *row = malloc(W * 4);
			for (int y = 0; y < H / 2; y++) {
				memcpy(row, b + y * W * 4, W * 4);
				memcpy(b + y * W * 4, b + (H - 1 - y) * W * 4, W * 4);
				memcpy(b + (H - 1 - y) * W * 4, row, W * 4);
			}
			free(row);
			for (int i = 0; i < W * H; i++)
				b[i * 4 + 3] = 255;
			[[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:arg atomically:YES];
			Log(@"glshot %@ %dx%d gl error %x", arg, W, H, glGetError());
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
	} else if ([cmd isEqualToString:@"tracemedia"]) {
		// tracemedia: logs the used rect of each home screen photo's texture and the
		// rect -rectForMedia: puts it in
		Class c = NSClassFromString(@"GLHomeScreenView");
		Method m = c ? class_getInstanceMethod(c, @selector(rectForMedia:)) : NULL;
		if (!m) {
			Log(@"tracemedia: no GLHomeScreenView");
		} else {
			__block NSRect (*orig)(id, SEL, id) = (NSRect (*)(id, SEL, id))method_getImplementation(m);
			method_setImplementation(m, imp_implementationWithBlock(^NSRect(id self, id media) {
				NSRect r = orig(self, @selector(rectForMedia:), media);
				id cache = [media respondsToSelector:@selector(mediaCache)] ? [media performSelector:@selector(mediaCache)] : nil;
				NSRect used = NSZeroRect;
				if ([cache respondsToSelector:@selector(usedRect)])
					used = ((NSRect (*)(id, SEL))objc_msgSend)(cache, @selector(usedRect));
				id eff = [cache respondsToSelector:@selector(effect)] ? [cache performSelector:@selector(effect)] : nil;
				Log(@"media %p %@ cache %p used %@ -> rect %@ effect %@ flags %lx", media, [media respondsToSelector:@selector(mediaTitle)] ? [media performSelector:@selector(mediaTitle)] : @"", cache, NSStringFromRect(used), NSStringFromRect(r), eff ? NSStringFromClass([eff class]) : @"none", [cache respondsToSelector:@selector(flags)] ? (long)((long (*)(id, SEL))objc_msgSend)(cache, @selector(flags)) : -1L);
				return r;
			}));
			Log(@"tracemedia: hooked");
			{
				SEL ms = NSSelectorFromString(@"moveCellWithInfo:toFrame:invalidateCursors:");
				int nc = objc_getClassList(NULL, 0);
				Class *all = (Class *)malloc(sizeof(Class) * nc);
				nc = objc_getClassList(all, nc);
				for (int k = 0; k < nc; k++) {
					Method mv = class_getInstanceMethod(all[k], ms);
					if (!mv || class_getInstanceMethod(class_getSuperclass(all[k]), ms) == mv)
						continue;
					IMP mo = method_getImplementation(mv);
					static NSMutableDictionary *seen;
					seen = [NSMutableDictionary dictionary];
					Log(@"tracemedia: hooking move in %s", class_getName(all[k]));
					method_setImplementation(mv, imp_implementationWithBlock(^(id self, id info, NSRect f, BOOL inv) {
						NSNumber *key = @((uintptr_t)info);
						int n = [seen[key] intValue];
						seen[key] = @(n + 1);
						if (n == 0 || n % 60 == 0)
							Log(@"move %p %@ #%d to %@", info, NSStringFromClass([info class]), n, NSStringFromRect(f));
						((void (*)(id, SEL, id, NSRect, BOOL))mo)(self, ms, info, f, inv);
					}));
				}
				free(all);
			}
			// which of the media methods run at all
			static int sCalls[4];
			NSArray *names = @[@"startNewMediaCell", @"startNewMedia:", @"animateMedia:", @"renderMedia:"];
			for (int i = 0; i < 4; i++) {
				SEL sel = NSSelectorFromString(names[i]);
				Method mm = class_getInstanceMethod(c, sel);
				if (i == 2 || i == 3)
					continue;
				if (!mm)
					continue;
				BOOL hasArg = [names[i] hasSuffix:@":"];
				IMP o = method_getImplementation(mm);
				int idx = i;
				if (hasArg)
					method_setImplementation(mm, imp_implementationWithBlock(^(id self, id a) {
						if (sCalls[idx]++ % 200 == 0)
							Log(@"call %@ #%d arg %@", names[idx], sCalls[idx], a ? NSStringFromClass([a class]) : @"nil");
						((void (*)(id, SEL, id))o)(self, sel, a);
					}));
				else
					method_setImplementation(mm, imp_implementationWithBlock(^(id self) {
						if (sCalls[idx]++ % 200 == 0)
							Log(@"call %@ #%d", names[idx], sCalls[idx]);
						((void (*)(id, SEL))o)(self, sel);
					}));
			}
		}
	} else if ([cmd isEqualToString:@"ivars"]) {
		// ivars <class>: the instance variables and methods the runtime knows for a class
		Class c = NSClassFromString(arg);
		for (; c; c = class_getSuperclass(c)) {
			unsigned n = 0;
			Ivar *iv = class_copyIvarList(c, &n);
			NSMutableString *s = [NSMutableString stringWithFormat:@"%s ivars:", class_getName(c)];
			for (unsigned i = 0; i < n; i++)
				[s appendFormat:@" %s(%s)", ivar_getName(iv[i]), ivar_getTypeEncoding(iv[i]) ?: ""];
			free(iv);
			Method *ms = class_copyMethodList(c, &n);
			[s appendFormat:@" | methods(%u):", n];
			for (unsigned i = 0; i < n && i < 80; i++)
				[s appendFormat:@" %s", sel_getName(method_getName(ms[i]))];
			free(ms);
			Log(@"%@", s);
		}
	} else if ([cmd isEqualToString:@"hshot"]) {
		// hshot <file>: the home screen window as the window server shows it
		NSWindow *w = nil;
		for (NSWindow *c in Windows())
			if ([[c title] isEqualToString:@"World Book Home Screen"])
				w = c;
		if (w) {
			unsetenv("DYLD_INSERT_LIBRARIES");
			NSString *c = [NSString stringWithFormat:@"/usr/sbin/screencapture -x -o -l %ld '%@'", (long)[w windowNumber], arg];
			system([c UTF8String]);
			Log(@"hshot %@ (window %ld)", arg, (long)[w windowNumber]);
		} else
			Log(@"hshot: no home screen window");
	} else if ([cmd isEqualToString:@"hframe"] || [cmd isEqualToString:@"hgl"]) {
		// hframe x y w h: moves and sizes the home screen window, as the window
		// server does when a display changes; hgl: its OpenGL view's state
		NSWindow *w = nil;
		for (NSWindow *c in Windows())
			if ([[c title] isEqualToString:@"World Book Home Screen"])
				w = c;
		NSView *v = [w contentView];
		if ([cmd isEqualToString:@"hframe"]) {
			NSArray *a = [arg componentsSeparatedByString:@" "];
			[w setFrame:NSMakeRect([a[0] doubleValue], [a[1] doubleValue], [a[2] doubleValue], [a[3] doubleValue]) display:YES];
		}
		NSOpenGLContext *ctx = [v isKindOfClass:[NSOpenGLView class]] ? [(NSOpenGLView *)v openGLContext] : nil;
		GLint vp[4] = {0}, dims[2] = {0};
		if (ctx) {
			[ctx makeCurrentContext];
			glGetIntegerv(GL_VIEWPORT, vp);
			CGLGetParameter([ctx CGLContextObj], kCGLCPSurfaceBackingSize, dims);
		}
		Log(@"%@ window %@ view %@ backing %@ best %d viewport %d %d %d %d surface %dx%d scale %g", cmd, NSStringFromRect([w frame]),
			NSStringFromRect([v frame]), NSStringFromRect([v convertRectToBacking:[v bounds]]),
			[v respondsToSelector:@selector(wantsBestResolutionOpenGLSurface)] ? (int)[(NSOpenGLView *)v wantsBestResolutionOpenGLSurface] : -1,
			vp[0], vp[1], vp[2], vp[3], dims[0], dims[1], [w backingScaleFactor]);
	} else if ([cmd isEqualToString:@"windows"]) {
		for (NSWindow *w in Windows())
			Log(@"window %@ %@ \"%@\"%@ #%ld style %lx content %@", NSStringFromClass([w class]), NSStringFromRect([w frame]), [w title], w == [NSApp modalWindow] ? @" modal" : @"", (long)[w windowNumber], (unsigned long)[w styleMask], NSStringFromRect([[w contentView] frame]));
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
