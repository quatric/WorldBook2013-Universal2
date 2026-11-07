// Scrap Manager over the general pasteboard.
//
// TEXT goes to the pasteboard as a string; other flavors (styl, PICT) are kept
// here and stay valid while the pasteboard has not changed since we wrote it.
#import <AppKit/AppKit.h>
#include "ppcrt.h"

static NSMutableDictionary<NSNumber *, NSData *> *priv;
static NSInteger priv_count = -1;

static void claim(void)
{
	NSPasteboard *pb = NSPasteboard.generalPasteboard;
	if (priv_count != pb.changeCount) {
		[pb clearContents];
		priv = [NSMutableDictionary new];
		priv_count = pb.changeCount;
	}
}

void scrap_clear(void)
{
	NSPasteboard *pb = NSPasteboard.generalPasteboard;
	[pb clearContents];
	priv = [NSMutableDictionary new];
	priv_count = pb.changeCount;
}

void scrap_put(uint32_t type, const void *d, uint32_t n)
{
	claim();
	NSPasteboard *pb = NSPasteboard.generalPasteboard;
	if (type == 'TEXT') {
		NSString *s = mac_ns(d, n);
		s = [s stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
		if (s)
			[pb setString:s forType:NSPasteboardTypeString];
		priv_count = pb.changeCount;
	}
	priv[@(type)] = [NSData dataWithBytes:d length:n];
}

static NSData *flavor(uint32_t type)
{
	NSPasteboard *pb = NSPasteboard.generalPasteboard;
	if (priv && priv_count == pb.changeCount) {
		NSData *d = priv[@(type)];
		if (d)
			return d;
	}
	if (type == 'TEXT') {
		NSString *s = [pb stringForType:NSPasteboardTypeString];
		if (!s)
			return nil;
		s = [[s stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\r"] stringByReplacingOccurrencesOfString:@"\n" withString:@"\r"];
		return [s dataUsingEncoding:NSMacOSRomanStringEncoding allowLossyConversion:YES];
	}
	return nil;
}

int scrap_get(uint32_t type, void **out, uint32_t *n)
{
	NSData *d = flavor(type);
	if (!d)
		return 0;
	*n = (uint32_t)d.length;
	*out = malloc(d.length + 1);
	memcpy(*out, d.bytes, d.length);
	return 1;
}

static void sh_ClearCurrentScrap(PPC *c) { (void)c; scrap_clear(); RET(0); }
static void sh_GetCurrentScrap(PPC *c) { ST32(A(0), 'XLsc'); RET(0); }
static void sh_GetScrapFlavorFlags(PPC *c)
{
	if (A(2))
		ST32(A(2), 0);
	RET(flavor(A(1)) ? 0 : -102);   // noTypeErr
}
static void sh_GetScrapFlavorSize(PPC *c)
{
	NSData *d = flavor(A(1));
	if (A(2))
		ST32(A(2), d ? (uint32_t)d.length : 0);
	RET(d ? 0 : -102);
}
static void sh_GetScrapFlavorData(PPC *c)
{
	// GetScrapFlavorData(scrap, flavor, Size *ioSize, void *dest)
	NSData *d = flavor(A(1));
	if (!d) {
		ST32(A(2), 0);
		RET(-102);
		return;
	}
	uint32_t want = LD32(A(2));
	uint32_t n = (uint32_t)d.length < want ? (uint32_t)d.length : want;
	memcpy(G(A(3)), d.bytes, n);
	ST32(A(2), n);
	RET(0);
}
static void sh_PutScrapFlavor(PPC *c)
{
	// PutScrapFlavor(scrap, flavor, flags, size, data)
	if (A(4) || !A(3))
		scrap_put(A(1), A(4) ? G(A(4)) : "", A(3));
	RET(0);
}
static void sh_ZeroScrap(PPC *c) { (void)c; scrap_clear(); RET(0); }

static const ShimDef scrapshims[] = {
	S(ClearCurrentScrap), S(GetCurrentScrap), S(GetScrapFlavorFlags), S(GetScrapFlavorSize), S(GetScrapFlavorData),
	S(PutScrapFlavor), S(ZeroScrap),
};
REGISTER(scrapshims)
