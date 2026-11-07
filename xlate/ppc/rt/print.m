// Carbon Printing Manager: pages drawn with QuickDraw into page-sized ports,
// collected into a PDF and printed through the standard print panel.
#import <AppKit/AppKit.h>
#import <PDFKit/PDFKit.h>
#include "win.h"

void ev_drop_mouseups(void);

typedef struct {
	int landscape;
	double scale;
} PageFormat;

typedef struct {
	uint32_t first, last, copies;
} Settings;

typedef struct {
	CFMutableDataRef pdf;
	CGContextRef cg;
	Port *page;
	int pages;
	int error;
} Session;

enum { T_SESSION = 'XLps', T_PF = 'XLpf', T_PS = 'XLpt' };

static Session *SES(uint32_t t) { return tok_get(t, T_SESSION); }
static PageFormat *PF(uint32_t t) { return tok_get(t, T_PF); }
static Settings *PS(uint32_t t) { return tok_get(t, T_PS); }

static int paper_w(PageFormat *f) { return f && f->landscape ? 792 : 612; }
static int paper_h(PageFormat *f) { return f && f->landscape ? 612 : 792; }

// the page in its own coordinates (0, 0 at the imageable origin) and the paper around it
static QRect page_rect(PageFormat *f) { return (QRect){0, 0, (int16_t)(paper_h(f) - 36), (int16_t)(paper_w(f) - 36)}; }
static QRect paper_rect(PageFormat *f) { return (QRect){-18, -18, (int16_t)(paper_h(f) - 18), (int16_t)(paper_w(f) - 18)}; }

static uint32_t new_pf(void) { PageFormat *f = calloc(1, sizeof *f); f->scale = 1; return tok_new(f, 16, T_PF); }
static uint32_t new_ps(void) { Settings *s = calloc(1, sizeof *s); s->first = 1; s->last = 0x7fffffff; s->copies = 1; return tok_new(s, 16, T_PS); }

static void sh_PMCreateSession(PPC *c) { ST32(A(0), tok_new(calloc(1, sizeof(Session)), 16, T_SESSION)); RET(0); }
static void sh_PMCreatePageFormat(PPC *c) { ST32(A(0), new_pf()); RET(0); }
static void sh_PMCreatePrintSettings(PPC *c) { ST32(A(0), new_ps()); RET(0); }
static void sh_PMRelease(PPC *c) { (void)c; RET(0); }   // kept: the objects are small
static void sh_PMRetain(PPC *c) { (void)c; RET(0); }
static void sh_PMok(PPC *c) { (void)c; RET(0); }
static void sh_PMValidate(PPC *c) { if (A(2)) ST8(A(2), 0); RET(0); }   // (session, obj, Boolean *changed)
static void sh_PMValidateOld(PPC *c) { if (A(1)) ST8(A(1), 0); RET(0); }  // (obj, Boolean *changed)

static void sh_PMSessionPageSetupDialog(PPC *c)
{
	// (session, pageFormat, Boolean *accepted)
	PageFormat *f = PF(A(1));
	NSPrintInfo *pi = [[NSPrintInfo sharedPrintInfo] copy];
	pi.orientation = f && f->landscape ? NSPaperOrientationLandscape : NSPaperOrientationPortrait;
	win_flush_all();
	NSInteger r = [[NSPageLayout pageLayout] runModalWithPrintInfo:pi];
	ev_drop_mouseups();
	if (r == NSModalResponseOK && f)
		f->landscape = pi.orientation == NSPaperOrientationLandscape;
	[pi release];
	if (A(2))
		ST8(A(2), r == NSModalResponseOK);
	RET(0);
}
static void sh_PMPageSetupDialog(PPC *c)
{
	uint32_t a[3] = {0, A(0), A(1)};
	c->r[3] = a[0];
	c->r[4] = a[1];
	c->r[5] = a[2];
	sh_PMSessionPageSetupDialog(c);
}
// the print panel comes at the end, with the pages to preview
static void sh_PMSessionPrintDialog(PPC *c) { if (A(3)) ST8(A(3), 1); RET(0); }
static void sh_PMPrintDialog(PPC *c) { if (A(2)) ST8(A(2), 1); RET(0); }

static void begin_document(Session *s)
{
	s->pdf = CFDataCreateMutable(NULL, 0);
	CGDataConsumerRef dc = CGDataConsumerCreateWithCFData(s->pdf);
	s->cg = CGPDFContextCreate(dc, NULL, NULL);
	CGDataConsumerRelease(dc);
	s->pages = 0;
	s->error = 0;
}

static PageFormat *cur_pf;

static void begin_page(Session *s, PageFormat *f)
{
	cur_pf = f;
	QRect b = paper_rect(f);
	if (!s->page)
		s->page = port_new(0, 0, b, 1);
	else {
		uint32_t *px = G(s->page->pix);
		for (int i = 0; i < s->page->rowBytes / 4 * (b.bottom - b.top); i++)
			px[i] = PIXV(255, 255, 255);
	}
	s->page->portRect = page_rect(f);
}

static void end_page(Session *s, PageFormat *f)
{
	if (!s->cg || !s->page)
		return;
	Port *p = s->page;
	int w = p->bounds.right - p->bounds.left, h = p->bounds.bottom - p->bounds.top;
	CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
	CGDataProviderRef dp = CGDataProviderCreateWithData(NULL, G(p->pix), (size_t)p->rowBytes * h, NULL);
	CGImageRef img = CGImageCreate(w, h, 8, 32, p->rowBytes, cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Big, dp, NULL,
		false, kCGRenderingIntentDefault);
	CGRect box = CGRectMake(0, 0, paper_w(f), paper_h(f));
	CGContextBeginPage(s->cg, &box);
	CGContextSetInterpolationQuality(s->cg, kCGInterpolationHigh);
	CGContextDrawImage(s->cg, box, img);
	CGContextEndPage(s->cg);
	CGImageRelease(img);
	CGDataProviderRelease(dp);
	CGColorSpaceRelease(cs);
	s->pages++;
}

static void end_document(Session *s)
{
	if (!s->cg)
		return;
	CGPDFContextClose(s->cg);
	CGContextRelease(s->cg);
	s->cg = NULL;
	if (s->pages) {
		PDFDocument *doc = [[PDFDocument alloc] initWithData:(NSData *)s->pdf];
		NSPrintInfo *pi = [[NSPrintInfo sharedPrintInfo] copy];
		pi.orientation = cur_pf && cur_pf->landscape ? NSPaperOrientationLandscape : NSPaperOrientationPortrait;
		NSPrintOperation *op = [doc printOperationForPrintInfo:pi scalingMode:kPDFPrintPageScaleToFit autoRotate:YES];
		op.showsPrintPanel = YES;
		op.showsProgressPanel = YES;
		win_flush_all();
		[op runOperation];
		ev_drop_mouseups();
		[pi release];
		[doc release];
	}
	CFRelease(s->pdf);
	s->pdf = NULL;
}

static void sh_PMSessionBeginDocument(PPC *c) { Session *s = SES(A(0)); if (s) begin_document(s); RET(0); }
static void sh_PMSessionEndDocument(PPC *c) { Session *s = SES(A(0)); if (s) end_document(s); RET(0); }
static void sh_PMSessionBeginPage(PPC *c) { Session *s = SES(A(0)); if (s) begin_page(s, PF(A(1))); RET(0); }
static void sh_PMSessionEndPage(PPC *c) { Session *s = SES(A(0)); if (s) end_page(s, cur_pf); RET(0); }
static void sh_PMSessionGetGraphicsContext(PPC *c)
{
	// (session, CFStringRef kind, void **context): a QuickDraw port
	Session *s = SES(A(0));
	if (A(2))
		ST32(A(2), s && s->page ? s->page->tok : 0);
	RET(s && s->page ? 0 : -30871);
}
static void sh_PMSessionError(PPC *c) { Session *s = SES(A(0)); RET(s ? s->error : 0); }

// the session-less API: one implicit session
static uint32_t implicit;
static Session *IMPL(void)
{
	if (!implicit)
		implicit = tok_new(calloc(1, sizeof(Session)), 16, T_SESSION);
	return SES(implicit);
}
static void sh_PMNewPageFormat(PPC *c) { ST32(A(0), new_pf()); RET(0); }
static void sh_PMNewPrintSettings(PPC *c) { ST32(A(0), new_ps()); RET(0); }
static void sh_PMBeginDocument(PPC *c)
{
	// (settings, pageFormat, PMPrintContext *)
	begin_document(IMPL());
	cur_pf = PF(A(1));
	ST32(A(2), implicit);
	RET(0);
}
static void sh_PMEndDocument(PPC *c) { (void)c; end_document(IMPL()); RET(0); }
static void sh_PMBeginPage(PPC *c) { (void)c; begin_page(IMPL(), cur_pf); RET(0); }
static void sh_PMEndPage(PPC *c) { (void)c; end_page(IMPL(), cur_pf); RET(0); }
static void sh_PMGetGrafPtr(PPC *c) { Session *s = IMPL(); ST32(A(1), s->page ? s->page->tok : 0); RET(0); }
static void sh_PMError(PPC *c) { (void)c; RET(0); }

static void sh_PMGetFirstPage(PPC *c) { Settings *s = PS(A(0)); ST32(A(1), s ? s->first : 1); RET(0); }
static void sh_PMGetLastPage(PPC *c) { Settings *s = PS(A(0)); ST32(A(1), s ? s->last : 0x7fffffff); RET(0); }
static void sh_PMSetFirstPage(PPC *c) { Settings *s = PS(A(0)); if (s) s->first = A(1); RET(0); }
static void sh_PMSetLastPage(PPC *c) { Settings *s = PS(A(0)); if (s) s->last = A(1); RET(0); }
static void sh_PMGetCopies(PPC *c) { Settings *s = PS(A(0)); ST32(A(1), s ? s->copies : 1); RET(0); }
static void sh_PMSetCopies(PPC *c) { Settings *s = PS(A(0)); if (s) s->copies = A(1); RET(0); }

static void put_rect_d(uint32_t a, QRect r)
{
	// PMRect: four doubles (top, left, bottom, right)
	double v[4] = {r.top, r.left, r.bottom, r.right};
	for (int i = 0; i < 4; i++) {
		uint64_t u;
		memcpy(&u, &v[i], 8);
		ST32(a + 8 * i, (uint32_t)(u >> 32));
		ST32(a + 8 * i + 4, (uint32_t)u);
	}
}
static void sh_PMGetAdjustedPageRect(PPC *c) { put_rect_d(A(1), page_rect(PF(A(0)))); RET(0); }
static void sh_PMGetAdjustedPaperRect(PPC *c) { put_rect_d(A(1), paper_rect(PF(A(0)))); RET(0); }
static void sh_PMGetOrientation(PPC *c) { PageFormat *f = PF(A(0)); ST16(A(1), f && f->landscape ? 2 : 1); RET(0); }
static void sh_PMSetOrientation(PPC *c) { PageFormat *f = PF(A(0)); if (f) f->landscape = (int16_t)A(1) == 2; RET(0); }

// flattened objects: a handle with the format or settings
static void sh_PMFlattenPageFormat(PPC *c)
{
	PageFormat *f = PF(A(0));
	PageFormat z = {0, 1};
	ST32(A(1), NewHandleFrom(f ? f : &z, sizeof z));
	RET(0);
}
static void sh_PMUnflattenPageFormat(PPC *c)
{
	uint32_t t = new_pf();
	if (A(0) && is_handle(A(0)) && HSize(A(0)) >= sizeof(PageFormat))
		memcpy(PF(t), G(HP(A(0))), sizeof(PageFormat));
	ST32(A(1), t);
	RET(0);
}
static void sh_PMFlattenPrintSettings(PPC *c)
{
	Settings *s = PS(A(0));
	Settings z = {1, 0x7fffffff, 1};
	ST32(A(1), NewHandleFrom(s ? s : &z, sizeof z));
	RET(0);
}
static void sh_PMUnflattenPrintSettings(PPC *c)
{
	uint32_t t = new_ps();
	if (A(0) && is_handle(A(0)) && HSize(A(0)) >= sizeof(Settings))
		memcpy(PS(t), G(HP(A(0))), sizeof(Settings));
	ST32(A(1), t);
	RET(0);
}

// a TPrint record: iPrVersion, prInfo (iDev, iVRes, iHRes, rPage), rPaper, ...
static uint32_t old_record(PageFormat *f)
{
	uint32_t h = NewHandleClearG(120);
	uint32_t p = HP(h);
	ST16(p, 3);
	ST16(p + 4, 72);
	ST16(p + 6, 72);
	PUTRECT(p + 8, page_rect(f));
	PUTRECT(p + 16, paper_rect(f));
	return h;
}
static void sh_PMSessionMakeOldPrintRecord(PPC *c) { ST32(A(3), old_record(PF(A(2)))); RET(0); }
static void sh_PMMakeOldPrintRecord(PPC *c) { ST32(A(2), old_record(PF(A(1)))); RET(0); }
static void sh_PMSessionConvertOldPrintRecord(PPC *c)
{
	// (session, Handle, &settings, &pageFormat)
	if (A(2))
		ST32(A(2), new_ps());
	if (A(3))
		ST32(A(3), new_pf());
	RET(0);
}
static void sh_PMConvertOldPrintRecord(PPC *c)
{
	if (A(1))
		ST32(A(1), new_ps());
	if (A(2))
		ST32(A(2), new_pf());
	RET(0);
}

static const ShimDef printshims[] = {
	S(PMCreateSession), S(PMCreatePageFormat), S(PMCreatePrintSettings), S(PMRelease), S(PMRetain),
	{"PMSessionDefaultPageFormat", sh_PMok}, {"PMSessionDefaultPrintSettings", sh_PMok},
	{"PMSessionValidatePageFormat", sh_PMValidate}, {"PMSessionValidatePrintSettings", sh_PMValidate},
	{"PMDefaultPageFormat", sh_PMok}, {"PMDefaultPrintSettings", sh_PMok},
	{"PMValidatePageFormat", sh_PMValidateOld}, {"PMValidatePrintSettings", sh_PMValidateOld},
	{"PMBegin", sh_PMok}, {"PMEnd", sh_PMok}, {"PMDisposePageFormat", sh_PMok}, {"PMDisposePrintSettings", sh_PMok},
	S(PMSessionPageSetupDialog), S(PMPageSetupDialog), S(PMSessionPrintDialog), S(PMPrintDialog),
	S(PMSessionBeginDocument), S(PMSessionEndDocument), S(PMSessionBeginPage), S(PMSessionEndPage),
	S(PMSessionGetGraphicsContext), S(PMSessionError), S(PMNewPageFormat), S(PMNewPrintSettings),
	S(PMBeginDocument), S(PMEndDocument), S(PMBeginPage), S(PMEndPage), S(PMGetGrafPtr), S(PMError),
	S(PMGetFirstPage), S(PMGetLastPage), S(PMSetFirstPage), S(PMSetLastPage), S(PMGetCopies), S(PMSetCopies),
	S(PMGetAdjustedPageRect), S(PMGetAdjustedPaperRect), S(PMGetOrientation), S(PMSetOrientation),
	S(PMFlattenPageFormat), S(PMUnflattenPageFormat), S(PMFlattenPrintSettings), S(PMUnflattenPrintSettings),
	S(PMSessionMakeOldPrintRecord), S(PMMakeOldPrintRecord), S(PMSessionConvertOldPrintRecord),
	S(PMConvertOldPrintRecord),
};
REGISTER(printshims)
