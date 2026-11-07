// Gestalt, strings, numbers, math, time, processes and launching, Core
// Foundation strings and bundles, help, low memory.
#import <AppKit/AppKit.h>
#include "ppcrt.h"
#include "hmap.h"
#include <math.h>
#include <time.h>

uint32_t qd_random_seed = 1;
void res_flush_all(void);

// ---- Gestalt ------------------------------------------------------------------------------------

static void sh_Gestalt(PPC *c)
{
	uint32_t sel = A(0), out = A(1), v;
	switch (sel) {
	case 'sysv': v = 0x1049; break;
	case 'sys1': v = 10; break;
	case 'sys2': v = 4; break;
	case 'sys3': v = 9; break;
	case 'qd  ': v = 0x0230; break;
	case 'qdrw': v = 0x3f; break;
	case 'appr': v = 0x3; break;          // Appearance present
	case 'apvr': v = 0x0114; break;
	case 'wind': v = 0x1f; break;
	case 'menu': v = 0x3; break;          // present, Aqua layout
	case 'cfrg': v = 1; break;
	case 'drag': v = 0x7; break;
	case 'icon': v = 0xf; break;
	case 'tsmv': v = 0x0150; break;
	case 'proc': v = 0x0139; break;
	case 'cput': v = 0x0139; break;
	case 'sysa': v = 2; break;            // PowerPC
	case 'ram ': case 'lram': v = 512u << 20; break;
	case 'fpu ': v = 3; break;
	case 'help': v = 1; break;
	case 'os  ': v = 0x7ff; break;
	case 'fs  ': v = 0x1fff; break;
	case 'qtim': v = 0x07008000; break;
	case 'snd ': v = 0x7fff; break;
	case 'disp': v = 7; break;
	case 'mach': v = 406; break;
	case 'aete': case 'evnt': v = 0; break;
	case 'ascr': v = 0x01380000; break;   // AppleScript
	case 'ics ': v = 0x01000000; break;
	case 'alis': v = 3; break;
	case 'tabl': v = 0; break;
	case 'osl ': v = 1; break;
	case 'carb': v = 0x0160; break;       // CarbonLib 1.6
	case 'cbon': v = 0x0160; break;
	case 'ttxt': v = 0; break;
	case 'txnv': v = 0x01300000; break;
	case 'nav ': v = 0x7; break;
	case 'thds': v = 1; break;
	case 'sysu': v = 0; break;
	default:
		if (ppc_verbose)
			ppc_log("Gestalt '%.4s': undefined", (char *)&(uint32_t){__builtin_bswap32(sel)});
		RET(-5551);
		return;
	}
	if (out)
		ST32(out, v);
	RET(0);
}

// ---- strings -------------------------------------------------------------------------------------

static void sh_NumToString(PPC *c)
{
	char b[32];
	snprintf(b, sizeof b, "%d", (int32_t)A(0));
	c2p(b, A(1));
}
static void sh_StringToNum(PPC *c)
{
	char b[260];
	p2c(A(0), b, sizeof b);
	ST32(A(1), (uint32_t)(int32_t)strtol(b, NULL, 10));
}
static int mac_cmp(const uint8_t *a, int la, const uint8_t *b, int lb, int caseSens)
{
	NSString *x = mac_ns(a, la), *y = mac_ns(b, lb);
	NSStringCompareOptions o = caseSens ? 0 : NSCaseInsensitiveSearch;
	return (int)[x compare:y options:o];
}
static void sh_EqualString(PPC *c)
{
	uint32_t a = A(0), b = A(1);
	RET(mac_cmp(G(a + 1), LD8(a), G(b + 1), LD8(b), A(2) & 0xff) == 0);
}
static void sh_IdenticalString(PPC *c)
{
	uint32_t a = A(0), b = A(1);
	RET(mac_cmp(G(a + 1), LD8(a), G(b + 1), LD8(b), 1) != 0);
}
static void sh_IdenticalText(PPC *c) { RET(mac_cmp(G(A(0)), (int16_t)A(2), G(A(1)), (int16_t)A(3), 1) != 0); }
static void sh_CompareText(PPC *c)
{
	NSString *x = mac_ns(G(A(0)), (int16_t)A(2)), *y = mac_ns(G(A(1)), (int16_t)A(3));
	RET((int32_t)[x localizedCompare:y]);
}
static void upper(uint32_t p, int n)
{
	NSString *s = mac_ns(G(p), n).uppercaseString;
	NSData *d = [s dataUsingEncoding:NSMacOSRomanStringEncoding allowLossyConversion:YES];
	if (d.length == (NSUInteger)n)
		memcpy(G(p), d.bytes, n);
}
static void sh_UpperString(PPC *c) { upper(A(0) + 1, LD8(A(0))); }
static void sh_UppercaseText(PPC *c) { upper(A(0), (int16_t)A(1)); }
static void sh_CopyCStringToPascal(PPC *c)
{
	char *s = G(A(0));
	size_t n = strnlen(s, 255);
	memmove(G(A(1) + 1), s, n);
	ST8(A(1), n);
}
static void sh_CopyPascalStringToC(PPC *c)
{
	int n = LD8(A(0));
	memmove(G(A(1)), G(A(0) + 1), n);
	ST8(A(1) + n, 0);
}

// StyledLineBreak(textPtr, textLen, textStart, textEnd, flags, Fixed *textWidth, long *textOffset)
static void sh_StyledLineBreak(PPC *c)
{
	extern double qd_text_width(struct Port *p, const uint8_t *s, int n);
	extern struct Port *qd_port;
	const uint8_t *t = G(A(0));
	int start = (int)A(2), end = (int)A(3);
	uint32_t wp = A(5), op = A(6);
	double width = (int32_t)LD32(wp) / 65536.0;
	int lastbreak = -1, i;
	for (i = start; i < end; i++) {
		if (t[i] == 13) {
			ST32(op, i + 1);
			ST32(wp, 0);
			RET(0);   // smBreakWord
			return;
		}
		double w = qd_text_width(qd_port, t + start, i + 1 - start);
		if (w > width) {
			if (lastbreak >= 0) {
				ST32(op, lastbreak);
				RET(0);
			} else {
				ST32(op, i > start ? i : start + 1);
				RET(1);   // smBreakChar
			}
			return;
		}
		if (t[i] == ' ')
			lastbreak = i + 1;
	}
	double w = qd_text_width(qd_port, t + start, end - start);
	ST32(wp, (uint32_t)(int32_t)lround((width - w) * 65536.0));
	ST32(op, end);
	RET(2);   // smBreakOverflow
}

static void sh_VisibleLength(PPC *c)
{
	const uint8_t *t = G(A(0));
	int n = (int)A(1);
	while (n > 0 && (t[n - 1] == ' ' || t[n - 1] == 13 || t[n - 1] == 9))
		n--;
	RET(n);
}

// ---- numbers -------------------------------------------------------------------------------------

static void sh_Long2Fix(PPC *c) { RET(A(0) << 16); }
static void sh_BitTst(PPC *c) { int32_t n = (int32_t)A(1); RET((LD8(A(0) + n / 8) >> (7 - n % 8)) & 1); }
static void sh_Random(PPC *c)
{
	uint64_t s = (uint64_t)(qd_random_seed ? qd_random_seed : 1) * 16807 % 2147483647;
	qd_random_seed = (uint32_t)s;
	int32_t r = (int32_t)(s & 0xffff);
	if (r == 0x8000)
		r = 0;
	RET((uint32_t)(int32_t)(int16_t)r);
}

// floating point arguments arrive in f1.., a double occupying two integer slots
static void sh_sin(PPC *c) { FRET(sin(c->f[1].d)); }
static void sh_cos(PPC *c) { FRET(cos(c->f[1].d)); }
static void sh_sqrt(PPC *c) { FRET(sqrt(c->f[1].d)); }
static void sh_floor(PPC *c) { FRET(floor(c->f[1].d)); }
static void sh_ceil(PPC *c) { FRET(ceil(c->f[1].d)); }
static void sh_log10(PPC *c) { FRET(log10(c->f[1].d)); }
static void sh_pow(PPC *c) { FRET(pow(c->f[1].d, c->f[2].d)); }
static void sh_nan(PPC *c) { FRET(NAN); }

// extended80: sign/exponent (16 bits, bias 16383), 64-bit mantissa with the integer bit
static void d_to_x80(double d, uint32_t a)
{
	memset(G(a), 0, 10);
	if (d == 0) {
		if (signbit(d))
			ST16(a, 0x8000);
		return;
	}
	int e;
	double m = frexp(fabs(d), &e);   // m in [0.5, 1)
	uint64_t mant = (uint64_t)ldexp(m, 64);
	ST16(a, (d < 0 ? 0x8000 : 0) | (uint16_t)(e - 1 + 16383));
	ST64(a + 2, mant);
}
static double x80_to_d(uint32_t a)
{
	uint16_t se = (uint16_t)LD16(a);
	uint64_t mant = LD64(a + 2);
	int e = (se & 0x7fff);
	if (!e && !mant)
		return (se & 0x8000) ? -0.0 : 0.0;
	if (e == 0x7fff)
		return (mant << 1) ? NAN : ((se & 0x8000) ? -INFINITY : INFINITY);
	double d = ldexp((double)mant, e - 16383 - 63);
	return (se & 0x8000) ? -d : d;
}
static void sh_x80tod(PPC *c) { FRET(x80_to_d(A(0))); }

// decimal: sgn (1), unused (1), exp (2), sig: length (1) + 36 digits
static void sh_num2dec(PPC *c)
{
	// num2dec(const decform *f, double x, decimal *d): f in r3, x in f1 (its GPR slots r4, r5), d in r6
	uint32_t f = A(0), d = A(3);
	double x = c->f[1].d;
	int style = LD8(f), digits = (int16_t)LD16(f + 2);
	memset(G(d), 0, 42);
	ST8(d, x < 0 ? 1 : 0);
	x = fabs(x);
	char buf[64];
	if (isnan(x)) {
		ST8(d + 4, 1);
		ST8(d + 5, 'N');
		return;
	}
	if (isinf(x)) {
		ST8(d + 4, 1);
		ST8(d + 5, 'I');
		return;
	}
	if (style == 1) {   // FIXEDDECIMAL: digits after the point
		if (digits < 0)
			digits = 0;
		snprintf(buf, sizeof buf, "%.*f", digits > 20 ? 20 : digits, x);
		char *dot = strchr(buf, '.');
		int frac = dot ? (int)strlen(dot + 1) : 0;
		if (dot)
			memmove(dot, dot + 1, strlen(dot));
		char *s = buf;
		while (*s == '0' && s[1])
			s++;
		int n = (int)strlen(s);
		if (n > 36)
			n = 36;
		ST8(d + 4, n);
		memcpy(G(d + 5), s, n);
		ST16(d + 2, (uint16_t)(int16_t)-frac);
	} else {
		if (digits < 1)
			digits = 1;
		if (digits > 17)
			digits = 17;
		snprintf(buf, sizeof buf, "%.*e", digits - 1, x);
		char *e = strchr(buf, 'e');
		int exp = atoi(e + 1);
		*e = 0;
		char sig[40];
		int n = 0;
		for (char *s = buf; *s; s++)
			if (*s != '.')
				sig[n++] = *s;
		ST8(d + 4, n);
		memcpy(G(d + 5), sig, n);
		ST16(d + 2, (uint16_t)(int16_t)(exp - (n - 1)));
	}
}
static double dec_value(uint32_t d)
{
	int n = LD8(d + 4);
	char buf[64];
	if (n > 36)
		n = 36;
	if (n && LD8(d + 5) == 'N')
		return NAN;
	if (n && LD8(d + 5) == 'I')
		return LD8(d) ? -INFINITY : INFINITY;
	memcpy(buf, G(d + 5), n);
	snprintf(buf + n, sizeof buf - n, "e%d", (int16_t)LD16(d + 2));
	double v = strtod(buf, NULL);
	return LD8(d) ? -v : v;
}
static void sh_dec2num(PPC *c) { FRET(dec_value(A(0))); }
static void sh_dec2str(PPC *c)
{
	// dec2str(const decform *f, const decimal *d, char *s)
	uint32_t f = A(0), d = A(1), s = A(2);
	double v = dec_value(d);
	int style = LD8(f), digits = (int16_t)LD16(f + 2);
	char buf[80];
	if (style == 1)
		snprintf(buf, sizeof buf, "%.*f", digits < 0 ? 0 : digits > 30 ? 30 : digits, v);
	else
		snprintf(buf, sizeof buf, "%.*e", digits < 1 ? 0 : digits - 1, v);
	strcpy(G(s), buf);
}
// StringToFormatRec(inString, partsTable, NumFormatString *): the format kept as its text
static void sh_StringToFormatRec(PPC *c)
{
	uint32_t out = A(2);
	int n = LD8(A(0));
	memset(G(out), 0, 256);
	ST8(out, n);
	memcpy(G(out + 1), G(A(0) + 1), n);
	RET(0);
}
// StringToExtended(source, formatRec, partsTable, extended80 *)
static void sh_StringToExtended(PPC *c)
{
	char b[260];
	p2c(A(0), b, sizeof b);
	char clean[260];
	int k = 0;
	for (char *s = b; *s; s++)
		if (*s != ',' && *s != '$' && *s != ' ')
			clean[k++] = *s;
	clean[k] = 0;
	char *end;
	double v = strtod(clean, &end);
	d_to_x80(v, A(3));
	RET(end == clean ? -1 : 0);
}

// ---- time ----------------------------------------------------------------------------------------

static uint32_t mac_now(void)
{
	time_t t = time(NULL);
	struct tm lt;
	localtime_r(&t, &lt);
	return (uint32_t)(t + lt.tm_gmtoff + 2082844800u);
}
static void sh_GetDateTime(PPC *c) { ST32(A(0), mac_now()); }
static void sh_SecondsToDate(PPC *c)
{
	time_t t = (time_t)A(0) - 2082844800u;
	struct tm g;
	gmtime_r(&t, &g);
	uint32_t d = A(1);
	ST16(d, g.tm_year + 1900);
	ST16(d + 2, g.tm_mon + 1);
	ST16(d + 4, g.tm_mday);
	ST16(d + 6, g.tm_hour);
	ST16(d + 8, g.tm_min);
	ST16(d + 10, g.tm_sec);
	ST16(d + 12, g.tm_wday + 1);
}

// ---- processes ------------------------------------------------------------------------------------

static void sh_GetCurrentProcess(PPC *c) { ST32(A(0), 0); ST32(A(0) + 4, 2); RET(0); }
static void sh_GetNextProcess(PPC *c)
{
	uint32_t p = A(0);
	if (LD32(p) == 0 && LD32(p + 4) == 0) {
		ST32(p + 4, 2);
		RET(0);
	} else
		RET(-600);   // procNotFound
}
static uint32_t app_spec_g;
static void sh_GetProcessInformation(PPC *c)
{
	uint32_t info = A(1);
	extern int fs_make_spec_for(const char *path, uint32_t spec);
	if (!app_spec_g) {
		app_spec_g = gcalloc(70);
		NSString *exe = NSBundle.mainBundle.infoDictionary[@"CFBundleName"] ?: @"Application";
		NSString *p = [@(ppc_app_dir) stringByAppendingPathComponent:exe];
		fs_make_spec_for(p.fileSystemRepresentation, app_spec_g);
	}
	if (LD32(info + 4)) {
		NSString *nm = NSBundle.mainBundle.infoDictionary[@"CFBundleName"] ?: @"Application";
		ns_pstr(nm, LD32(info + 4));
	}
	ST32(info + 8, 0);
	ST32(info + 12, 2);
	ST32(info + 16, 'APPL');
	NSString *sig = NSBundle.mainBundle.infoDictionary[@"CFBundleSignature"] ?: @"????";
	const char *s4 = sig.UTF8String;
	ST32(info + 20, (uint32_t)s4[0] << 24 | (uint32_t)s4[1] << 16 | (uint32_t)s4[2] << 8 | (uint32_t)s4[3]);
	ST32(info + 24, 0x5800);   // processMode
	ST32(info + 28, 0);
	ST32(info + 32, 32u << 20);
	ST32(info + 36, 16u << 20);
	if (LD32(info) >= 60 && LD32(info + 56))
		memcpy(G(LD32(info + 56)), G(app_spec_g), 70);
	RET(0);
}
static void sh_SetFrontProcess(PPC *c) { [NSApp activateIgnoringOtherApps:YES]; RET(0); }

static void open_path_with(NSString *app, NSArray *docs)
{
	NSString *resolved = app.stringByResolvingSymlinksInPath;
	NSWorkspace *ws = NSWorkspace.sharedWorkspace;
	NSURL *appURL = [NSURL fileURLWithPath:resolved];
	NSWorkspaceOpenConfiguration *cfg = [NSWorkspaceOpenConfiguration configuration];
	NSMutableArray *urls = [NSMutableArray array];
	for (NSString *d in docs)
		[urls addObject:[NSURL fileURLWithPath:d]];
	if (urls.count)
		[ws openURLs:urls withApplicationAtURL:appURL configuration:cfg completionHandler:nil];
	else
		[ws openApplicationAtURL:appURL configuration:cfg completionHandler:nil];
}

static void sh_LaunchApplication(PPC *c)
{
	extern const char *fsspec_path(uint32_t spec, char *out, size_t n);
	uint32_t pb = A(0);
	char p[1024];
	if (!fsspec_path(LD32(pb + 16), p, sizeof p)) {
		RET(-43);
		return;
	}
	open_path_with(@(p), nil);
	RET(0);
}
static void sh_LSInit(PPC *c) { RET(0); }
static void sh_LSTerm(PPC *c) { RET(0); }
static void sh_LSOpenFromRefSpec(PPC *c)
{
	extern const char *fsref_path(uint32_t ref, char *out, size_t n);
	uint32_t spec = A(0);
	char p[1024];
	NSMutableArray *docs = [NSMutableArray array];
	for (uint32_t i = 0; i < LD32(spec + 4); i++)
		if (fsref_path(LD32(spec + 8) + 80 * i, p, sizeof p))
			[docs addObject:@(p)];
	if (LD32(spec) && fsref_path(LD32(spec), p, sizeof p))
		open_path_with(@(p), docs);
	else
		for (NSString *d in docs)
			[NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:d]];
	RET(0);
}
static void sh_ExitToShell(PPC *c)
{
	res_flush_all();
	exit(0);
}

// ---- Core Foundation: strings and bundles as tokens ------------------------------------------------

enum { TAG_CF = 'cfob' };
static uint32_t cf_tok(CFTypeRef o)
{
	if (!o)
		return 0;
	return tok_new((void *)o, 16, TAG_CF);
}
CFTypeRef cf_obj(uint32_t t) { return t ? tok_get(t, TAG_CF) : NULL; }
NSString *cf_string(uint32_t t)
{
	CFTypeRef o = cf_obj(t);
	return o && CFGetTypeID(o) == CFStringGetTypeID() ? (NSString *)o : nil;
}
uint32_t cf_make_string(NSString *s) { return cf_tok(CFBridgingRetain([s copy])); }

static HMap const_strings;
static void sh___CFStringMakeConstantString(PPC *c)
{
	uint32_t t = (uint32_t)(uintptr_t)hm_get(&const_strings, A(0));
	if (!t) {
		NSString *s = [NSString stringWithCString:(char *)G(A(0)) encoding:NSMacOSRomanStringEncoding] ?: @"";
		t = cf_tok(CFBridgingRetain(s));
		hm_put(&const_strings, A(0), (void *)(uintptr_t)t);
	}
	RET(t);
}
static NSStringEncoding ns_enc(uint32_t e) { return e == 0x08000100 ? NSUTF8StringEncoding : e == 0x0600 ? NSASCIIStringEncoding : NSMacOSRomanStringEncoding; }
static void sh_CFStringCreateWithCString(PPC *c)
{
	NSString *s = [NSString stringWithCString:(char *)G(A(1)) encoding:ns_enc(A(2))] ?: @"";
	RET(cf_tok(CFBridgingRetain(s)));
}
static void sh_CFStringCreateWithPascalString(PPC *c)
{
	NSString *s = [[[NSString alloc] initWithBytes:G(A(1) + 1) length:LD8(A(1)) encoding:ns_enc(A(2))] autorelease] ?: @"";
	RET(cf_tok(CFBridgingRetain(s)));
}
static void sh_CFStringCreateWithBytes(PPC *c)
{
	NSString *s = [[[NSString alloc] initWithBytes:G(A(1)) length:A(2) encoding:ns_enc(A(3))] autorelease] ?: @"";
	RET(cf_tok(CFBridgingRetain(s)));
}
static void sh_CFStringGetLength(PPC *c) { RET(cf_string(A(0)).length); }
static void sh_CFStringGetCharacters(PPC *c)
{
	// CFStringGetCharacters(str, CFRange (loc, len), UniChar *buffer)
	NSString *s = cf_string(A(0));
	uint32_t loc = A(1), len = A(2), buf = A(3);
	for (uint32_t i = 0; i < len && loc + i < s.length; i++)
		ST16(buf + 2 * i, [s characterAtIndex:loc + i]);
}
static void sh_CFGetTypeID(PPC *c) { CFTypeRef o = cf_obj(A(0)); RET(o ? CFGetTypeID(o) : 0); }
static void sh_CFStringGetTypeID(PPC *c) { RET(CFStringGetTypeID()); }
static void sh_CFRelease(PPC *c)
{
	CFTypeRef o = cf_obj(A(0));
	if (!o)
		return;
	if (CFGetRetainCount(o) <= 1) {
		// constant strings stay
		for (uint32_t i = 0; i < const_strings.cap; i++)
			if (const_strings.k[i] && const_strings.k[i] != 0xffffffffu && (uint32_t)(uintptr_t)const_strings.v[i] == A(0))
				return;
		CFRelease(o);
		tok_free(A(0));
	} else
		CFRelease(o);
}
static void sh_CFURLCreateWithFileSystemPath(PPC *c)
{
	NSString *s = cf_string(A(1));
	if (!s) {
		RET(0);
		return;
	}
	RET(cf_tok(CFBridgingRetain([NSURL fileURLWithPath:s])));
}
static void sh_CFBundleCreate(PPC *c) { RET(0); }
static void sh_CFBundleLoadExecutable(PPC *c) { RET(0); }
static void sh_CFBundleGetFunctionPointerForName(PPC *c) { RET(0); }

// Code Fragment Manager: no other fragments
static void sh_GetSharedLibrary(PPC *c) { RET(-2804); }
static void sh_FindSymbol(PPC *c) { RET(-2802); }
static void sh_CloseConnection(PPC *c) { RET(0); }

// Apple Help: the wizards' help book is HTML next to them
static void sh_AHGotoPage(PPC *c)
{
	// AHGotoPage(bookname, path, anchor)
	NSString *path = cf_string(A(1));
	NSString *dir = [@(ppc_app_dir) stringByAppendingPathComponent:@".World Book.wz/Contents/Resources/WorldBookWizard.help"];
	NSString *page = path.length ? [dir stringByAppendingPathComponent:path] : nil;
	if (!page || ![NSFileManager.defaultManager fileExistsAtPath:page]) {
		NSArray *l = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil];
		NSString *app = [(NSString *)(NSBundle.mainBundle.infoDictionary[@"CFBundleName"] ?: @"") lowercaseString];
		for (NSString *f in l) {
			NSString *base = [[f.stringByDeletingPathExtension stringByReplacingOccurrencesOfString:@"_" withString:@" "] lowercaseString];
			if ([app isEqualToString:base])
				page = [dir stringByAppendingPathComponent:f];
		}
	}
	if (page)
		[NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:page]];
	RET(page ? 0 : -50);
}

// ---- low memory and the rest -------------------------------------------------------------------------

int hilite_mode = 0x80;   // the hiliteBit (7) cleared: the next invert highlights
static void sh_LMGetSysFontFam(PPC *c) { RET(0); }
static void sh_LMGetSysFontSize(PPC *c) { RET(12); }
static void sh_LMGetHiliteMode(PPC *c) { RET(hilite_mode); }
static void sh_LMSetHiliteMode(PPC *c) { hilite_mode = A(0) & 0xff; }
static void sh_nop(PPC *c) { (void)c; }
static void sh_zero(PPC *c) { RET(0); }
static void sh_CreateTextEncoding(PPC *c) { RET((A(2) & 0x3f) << 26 | (A(1) & 0x3ff) << 16 | (A(0) & 0xffff)); }
static void sh_GetSysDirection(PPC *c) { RET(0); }

static const ShimDef miscshims[] = {
	S(Gestalt), S(NumToString), S(StringToNum), S(EqualString), S(IdenticalString), S(IdenticalText), S(CompareText),
	S(UpperString), S(UppercaseText), S(CopyCStringToPascal), S(CopyPascalStringToC), S(StyledLineBreak),
	S(VisibleLength), S(Long2Fix), S(BitTst), S(Random), S(sin), S(cos), S(sqrt), S(floor), S(ceil), S(log10),
	S(pow), S(nan), S(x80tod), S(num2dec), S(dec2num), S(dec2str), S(StringToFormatRec), S(StringToExtended),
	S(GetDateTime), S(SecondsToDate), S(GetCurrentProcess), S(GetNextProcess), S(GetProcessInformation),
	S(SetFrontProcess), S(LaunchApplication), S(LSInit), S(LSTerm), S(LSOpenFromRefSpec), S(ExitToShell),
	S(__CFStringMakeConstantString), S(CFStringCreateWithCString), S(CFStringCreateWithPascalString),
	S(CFStringCreateWithBytes), S(CFStringGetLength), S(CFStringGetCharacters), S(CFGetTypeID), S(CFStringGetTypeID),
	S(CFRelease), S(CFURLCreateWithFileSystemPath), S(CFBundleCreate), S(CFBundleLoadExecutable),
	S(CFBundleGetFunctionPointerForName), S(GetSharedLibrary), S(FindSymbol), S(CloseConnection), S(AHGotoPage),
	S(LMGetSysFontFam), S(LMGetSysFontSize), S(LMGetHiliteMode), S(LMSetHiliteMode), {"LMSetSysFontFam", sh_nop},
	{"LMSetSysFontSize", sh_nop}, {"LMSetLastSPExtra", sh_nop}, {"SetA5", sh_zero}, {"SetCurrentA5", sh_zero},
	S(CreateTextEncoding), S(GetSysDirection), {"TEFeatureFlag", sh_zero},
	{"NewAEIdleUPP", sh_nop}, {"DisposeAEIdleUPP", sh_nop}, {"NewModalFilterUPP", sh_nop}, {"DisposeModalFilterUPP", sh_nop},
	{"NewControlActionUPP", sh_nop}, {"DisposeControlActionUPP", sh_nop}, {"NewControlColorUPP", sh_nop},
	{"DisposeControlColorUPP", sh_nop}, {"NewControlDefUPP", sh_nop}, {"NewTEClickLoopUPP", sh_nop},
	{"DisposeTEClickLoopUPP", sh_nop}, {"NewNavEventUPP", sh_nop}, {"DisposeNavEventUPP", sh_nop},
	{"NewNavObjectFilterUPP", sh_nop}, {"DisposeNavObjectFilterUPP", sh_nop}, {"NewNavPreviewUPP", sh_nop},
	{"DisposeNavPreviewUPP", sh_nop}, {"NewAEEventHandlerUPP", sh_nop}, {"NewOSLAccessorUPP", sh_nop},
	{"NewOSLCompareUPP", sh_nop}, {"NewOSLCountUPP", sh_nop}, {"NewOSLDisposeTokenUPP", sh_nop},
	{"NewDragReceiveHandlerUPP", sh_nop}, {"NewDragTrackingHandlerUPP", sh_nop},
};
REGISTER(miscshims)
