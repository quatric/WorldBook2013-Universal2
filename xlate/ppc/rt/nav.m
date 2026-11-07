// Navigation Services as NSOpenPanel, NSSavePanel and NSAlert.
#import <AppKit/AppKit.h>
#include "win.h"

void ae_make_path_list(uint32_t desc, NSArray<NSString *> *paths, uint32_t type);
void ae_dispose(uint32_t d);
NSString *cf_string(uint32_t t);
uint32_t cf_make_string(NSString *s);
void fs_set_type(const char *path, uint32_t type, uint32_t creator);
void ev_drop_mouseups(void);

enum { kNavCBUserAction = 12, kNavCBTerminate = 3, kNavCBStart = 2 };
enum { actNone = 0, actCancel = 1, actOpen = 2, actSaveAs = 3, actSaveChanges = 6, actDontSave = 7, actDiscard = 8 };

typedef struct {
	uint32_t tok;
	int kind;                // 0 get, 1 put, 2 ask save changes
	uint32_t event_proc, client;
	NSString *title, *message, *name, *client_name, *action_label;
	uint32_t type, creator;
	int action;
	NSArray<NSString *> *paths;
	NSString *dir;
	int multiple;
	int ask_action;
} NavD;

static NavD *D(uint32_t t) { return tok_get(t, 'XLnv'); }

static void sh_NavLoad(PPC *c) { (void)c; RET(0); }
static void sh_NavUnload(PPC *c) { (void)c; RET(0); }

static void sh_NavGetDefaultDialogCreationOptions(PPC *c)
{
	uint32_t o = A(0);
	memset(G(o), 0, 66);
	ST32(o + 2, 0x0c);   // kNavDefaultNavDlogOptions
	ST16(o + 6, 0xffff);
	ST16(o + 8, 0xffff);
	ST32(o + 42, 0);     // kWindowModalityAppModal
	RET(0);
}
static void sh_NavGetDefaultDialogOptions(PPC *c)
{
	uint32_t o = A(0);
	memset(G(o), 0, 2048);
	ST32(o + 2, 0x0c);
	ST16(o + 6, 0xffff);
	ST16(o + 8, 0xffff);
	NSString *n = NSProcessInfo.processInfo.processName;
	ns_pstr(n, o + 10);
	RET(0);
}

static NavD *from_creation(uint32_t o, int kind)
{
	NavD *d = calloc(1, sizeof *d);
	d->kind = kind;
	if (o) {
		d->multiple = (LD32(o + 2) & 0x40) != 0;   // kNavAllowMultipleFiles
		d->client_name = cf_string(LD32(o + 10));
		d->title = cf_string(LD32(o + 14));
		d->action_label = cf_string(LD32(o + 18));
		d->name = cf_string(LD32(o + 26));
		d->message = cf_string(LD32(o + 30));
	}
	d->tok = tok_new(d, 16, 'XLnv');
	return d;
}

static void sh_NavCreateGetFileDialog(PPC *c)
{
	// (options, typeList, eventProc, previewProc, filterProc, clientData, &dialog)
	NavD *d = from_creation(A(0), 0);
	d->event_proc = A(2);
	d->client = A(5);
	ST32(A(6), d->tok);
	RET(0);
}
static void sh_NavCreatePutFileDialog(PPC *c)
{
	// (options, fileType, fileCreator, eventProc, clientData, &dialog)
	NavD *d = from_creation(A(0), 1);
	d->type = A(1);
	d->creator = A(2);
	d->event_proc = A(3);
	d->client = A(4);
	ST32(A(5), d->tok);
	RET(0);
}
static void sh_NavCreateAskSaveChangesDialog(PPC *c)
{
	// (options, action, eventProc, clientData, &dialog)
	NavD *d = from_creation(A(0), 2);
	d->ask_action = (int)A(1);
	d->event_proc = A(2);
	d->client = A(3);
	ST32(A(4), d->tok);
	RET(0);
}

static NSString *doc_name(NavD *d)
{
	return d->name.length ? d->name : (d->client_name.length ? d->client_name : @"this document");
}

static int run_ask(NavD *d, int discard)
{
	NSAlert *a = [NSAlert new];
	if (discard) {
		a.messageText = [NSString stringWithFormat:@"Do you want to discard the changes you made to “%@”?", doc_name(d)];
		a.informativeText = @"Your changes will be lost.";
		[a addButtonWithTitle:@"Discard"];
		[a addButtonWithTitle:@"Cancel"].keyEquivalent = @"\033";
	} else {
		a.messageText = d->message.length ? d->message
			: [NSString stringWithFormat:@"Do you want to save the changes you made to “%@”?", doc_name(d)];
		a.informativeText = @"Your changes will be lost if you don’t save them.";
		[a addButtonWithTitle:@"Save"];
		[a addButtonWithTitle:@"Cancel"].keyEquivalent = @"\033";
		NSButton *dont = [a addButtonWithTitle:@"Don’t Save"];
		dont.keyEquivalent = @"d";
		dont.keyEquivalentModifierMask = NSEventModifierFlagCommand;
	}
	win_flush_all();
	NSInteger r = [a runModal] - NSAlertFirstButtonReturn;
	ev_drop_mouseups();
	return (int)r;   // 0 save/discard, 1 cancel, 2 don't save
}

static void run(NavD *d)
{
	win_flush_all();
	d->paths = nil;
	d->action = actCancel;
	// scripted test runs: PPC_NAV_FILE answers open and save dialogs with that path
	const char *auto_file = getenv("PPC_SCRIPT") ? getenv("PPC_NAV_FILE") : NULL;
	if (auto_file && d->kind != 2) {
		NSString *p = @(auto_file);
		d->paths = @[p];
		d->dir = p.stringByDeletingLastPathComponent;
		d->name = p.lastPathComponent;
		d->action = d->kind == 0 ? actOpen : actSaveAs;
		ppc_log("nav: answered with %s", auto_file);
		return;
	}
	if (d->kind == 0) {
		NSOpenPanel *p = [NSOpenPanel openPanel];
		p.canChooseFiles = YES;
		p.canChooseDirectories = NO;
		p.allowsMultipleSelection = d->multiple;
		if (d->title)
			p.title = d->title;
		if (d->message)
			p.message = d->message;
		if (d->action_label)
			p.prompt = d->action_label;
		if ([p runModal] == NSModalResponseOK) {
			NSMutableArray *a = [NSMutableArray array];
			for (NSURL *u in p.URLs)
				[a addObject:u.path];
			d->paths = a;
			d->action = actOpen;
		}
	} else if (d->kind == 1) {
		NSSavePanel *p = [NSSavePanel savePanel];
		if (d->title)
			p.title = d->title;
		if (d->message)
			p.message = d->message;
		if (d->name)
			p.nameFieldStringValue = d->name;
		p.extensionHidden = NO;
		p.allowsOtherFileTypes = YES;
		if ([p runModal] == NSModalResponseOK) {
			d->paths = @[p.URL.path];
			d->dir = p.URL.path.stringByDeletingLastPathComponent;
			d->name = p.URL.lastPathComponent;
			d->action = actSaveAs;
		}
	} else {
		int r = run_ask(d, 0);
		d->action = r == 0 ? actSaveChanges : r == 2 ? actDontSave : actCancel;
	}
	ev_drop_mouseups();
}

static void callback(NavD *d, uint32_t msg)
{
	if (!d->event_proc)
		return;
	uint32_t rec = gcalloc(256);
	ST32(rec + 2, d->tok);
	ST32(rec + 32, (uint32_t)d->action);
	ppc_cb3(d->event_proc, msg, rec, d->client);
	gfree(rec);
}

static void sh_NavDialogRun(PPC *c)
{
	NavD *d = D(A(0));
	if (!d)
		return RET(-50);
	callback(d, kNavCBStart);
	run(d);
	callback(d, kNavCBUserAction);
	callback(d, kNavCBTerminate);
	RET(0);
}
static void sh_NavDialogGetUserAction(PPC *c) { NavD *d = D(A(0)); RET(d ? d->action : 0); }

static void fill_reply(NavD *d, uint32_t r, int old_api)
{
	memset(G(r), 0, 256);
	ST16(r, 0);
	int ok = d->paths.count > 0;
	ST8(r + 2, ok);
	if (ok && d->kind == 1) {
		ST8(r + 3, [NSFileManager.defaultManager fileExistsAtPath:d->paths[0]]);
		if (old_api)
			ae_make_path_list(r + 6, d->paths, 'fss ');
		else
			ae_make_path_list(r + 6, @[d->dir], 'fsrf');
		ST32(r + 24, cf_make_string(d->name));
	} else if (ok) {
		ae_make_path_list(r + 6, d->paths, old_api ? 'fss ' : 'fss ');
	} else {
		ST32(r + 6, 'null');
		ST32(r + 10, 0);
	}
	ST16(r + 14, 0);
}

static void sh_NavDialogGetReply(PPC *c)
{
	NavD *d = D(A(0));
	if (!d)
		return RET(-50);
	fill_reply(d, A(1), 0);
	RET(d->paths.count ? 0 : userCanceledErr);
}
static void sh_NavDisposeReply(PPC *c)
{
	uint32_t r = A(0);
	ae_dispose(r + 6);
	RET(0);
}
static void sh_NavDialogDispose(PPC *c)
{
	NavD *d = D(A(0));
	if (!d)
		return;
	tok_free(d->tok);
	free(d);
}
static void sh_NavCompleteSave(PPC *c) { (void)c; RET(0); }

// the old API
static NavD *from_options(uint32_t o, int kind)
{
	NavD *d = calloc(1, sizeof *d);
	d->kind = kind;
	if (o) {
		d->multiple = (LD32(o + 2) & 0x40) != 0;
		if (LD8(o + 10))
			d->client_name = pstr_ns(o + 10);
		if (LD8(o + 266))
			d->title = pstr_ns(o + 266);
		if (LD8(o + 522))
			d->action_label = pstr_ns(o + 522);
		if (LD8(o + 1034))
			d->name = pstr_ns(o + 1034);
		if (LD8(o + 1290))
			d->message = pstr_ns(o + 1290);
	}
	d->tok = tok_new(d, 16, 'XLnv');
	return d;
}

static void sh_NavGetFile(PPC *c)
{
	// NavGetFile(defaultLocation, reply, options, eventProc, previewProc, filterProc, typeList, ud)
	NavD *d = from_options(A(2), 0);
	run(d);
	fill_reply(d, A(1), 1);
	int ok = d->paths.count > 0;
	tok_free(d->tok);
	free(d);
	RET(ok ? 0 : userCanceledErr);
}
static void sh_NavPutFile(PPC *c)
{
	// NavPutFile(defaultLocation, reply, options, eventProc, fileType, fileCreator, ud)
	NavD *d = from_options(A(2), 1);
	d->type = A(4);
	d->creator = A(5);
	run(d);
	fill_reply(d, A(1), 1);
	int ok = d->paths.count > 0;
	tok_free(d->tok);
	free(d);
	RET(ok ? 0 : userCanceledErr);
}
static void sh_NavAskSaveChanges(PPC *c)
{
	// NavAskSaveChanges(options, action, &reply, eventProc, ud)
	NavD *d = from_options(A(0), 2);
	int r = run_ask(d, 0);
	ST32(A(2), r == 0 ? 1 : r == 2 ? 3 : 2);
	tok_free(d->tok);
	free(d);
	RET(0);
}
static void sh_NavAskDiscardChanges(PPC *c)
{
	// NavAskDiscardChanges(options, &reply, eventProc, ud)
	NavD *d = from_options(A(0), 2);
	int r = run_ask(d, 1);
	ST32(A(1), r == 0 ? 1 : 2);
	tok_free(d->tok);
	free(d);
	RET(0);
}

static const ShimDef navshims[] = {
	S(NavLoad), S(NavUnload), S(NavGetDefaultDialogCreationOptions), S(NavGetDefaultDialogOptions),
	S(NavCreateGetFileDialog), S(NavCreatePutFileDialog), S(NavCreateAskSaveChangesDialog), S(NavDialogRun),
	S(NavDialogGetUserAction), S(NavDialogGetReply), S(NavDisposeReply), S(NavDialogDispose), S(NavCompleteSave),
	S(NavGetFile), S(NavPutFile), S(NavAskSaveChanges), S(NavAskDiscardChanges),
};
REGISTER(navshims)
