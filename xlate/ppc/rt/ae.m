// Apple Event Manager: descriptors, lists, records and events kept on the
// host. A guest AEDesc is {descriptorType, dataHandle}; the data handle of a
// simple descriptor holds its bytes, that of a list, record or event is a
// token for the host container.
#import <Foundation/Foundation.h>
#include "win.h"
#include "hmap.h"

const char *fsspec_path(uint32_t spec, char *out, size_t n);
int fs_make_spec_for(const char *path, uint32_t spec);
int fs_make_ref_for(const char *path, uint32_t ref);
const char *fsref_path(uint32_t ref, char *out, size_t n);


@interface AEItem : NSObject {
@public
	uint32_t key, type;
	NSData *data;                 // simple
	NSMutableArray<AEItem *> *kids;   // list, record or event
	NSMutableArray<AEItem *> *attrs;  // event attributes
}
@end
@implementation AEItem
@end

static HMap containers;   // data handle -> AEItem (retained via the set)
static NSMutableSet *alive;

static int is_container(uint32_t t) { return t == 'list' || t == 'reco' || t == 'aevt'; }

static AEItem *item(uint32_t key, uint32_t type, const void *d, uint32_t n)
{
	AEItem *it = [AEItem new];
	it->key = key;
	it->type = type;
	if (is_container(type))
		it->kids = [NSMutableArray array];
	else
		it->data = [NSData dataWithBytes:d length:n];
	return it;
}

// a guest AEDesc from a host item (copied)
static void put_desc(uint32_t desc, AEItem *it)
{
	ST32(desc, it->type);
	if (it->type == 'null') {
		ST32(desc + 4, 0);
		return;
	}
	if (is_container(it->type)) {
		AEItem *cp = [AEItem new];
		cp->key = it->key;
		cp->type = it->type;
		cp->kids = [NSMutableArray arrayWithArray:it->kids];
		cp->attrs = it->attrs ? [NSMutableArray arrayWithArray:it->attrs] : nil;
		uint32_t h = NewHandleClearG(4);
		if (!alive)
			alive = [NSMutableSet set];
		[alive addObject:cp];
		hm_put(&containers, h, (__bridge void *)cp);
		ST32(desc + 4, h);
		return;
	}
	ST32(desc + 4, NewHandleFrom(it->data.bytes, (uint32_t)it->data.length));
}

// a host item from a guest AEDesc (containers by reference)
static AEItem *get_desc(uint32_t desc)
{
	if (!desc)
		return nil;
	uint32_t type = LD32(desc), h = LD32(desc + 4);
	if (is_container(type)) {
		AEItem *it = (__bridge AEItem *)hm_get(&containers, h);
		return it;
	}
	AEItem *it = [AEItem new];
	it->type = type;
	it->data = h && is_handle(h) ? [NSData dataWithBytes:G(HP(h)) length:HSize(h)] : [NSData data];
	return it;
}

static AEItem *find(NSArray<AEItem *> *a, uint32_t key)
{
	for (AEItem *it in a)
		if (it->key == key)
			return it;
	return nil;
}

// ---- coercion -----------------------------------------------------------------------------------------

static AEItem *coerce(AEItem *it, uint32_t to)
{
	if (!it)
		return nil;
	if (to == '****' || to == it->type)
		return it;
	uint32_t from = it->type;
	char path[1024];
	const char *p = NULL;
	if (from == 'alis' && it->data.length > 8) {
		size_t n = it->data.length - 8;
		if (n >= sizeof path)
			n = sizeof path - 1;
		memcpy(path, (const char *)it->data.bytes + 8, n);
		path[n] = 0;
		p = path;
	} else if (from == 'fss ' && it->data.length >= 70) {
		uint32_t tmp = gcalloc(72);
		memcpy(G(tmp), it->data.bytes, 70);
		p = fsspec_path(tmp, path, sizeof path);
		gfree(tmp);
	} else if (from == 'fsrf' && it->data.length >= 80) {
		uint32_t tmp = gcalloc(80);
		memcpy(G(tmp), it->data.bytes, 80);
		p = fsref_path(tmp, path, sizeof path);
		gfree(tmp);
	} else if (from == 'furl' || from == 'utf8') {
		NSString *s = [[NSString alloc] initWithData:it->data encoding:NSUTF8StringEncoding];
		if (from == 'furl')
			s = [NSURL URLWithString:s].path;
		if (s && (to == 'TEXT' || to == 'utf8')) {
			NSData *d = [s dataUsingEncoding:to == 'TEXT' ? NSMacOSRomanStringEncoding : NSUTF8StringEncoding allowLossyConversion:YES];
			return item(it->key, to, d.bytes, (uint32_t)d.length);
		}
		if (s)
			snprintf(path, sizeof path, "%s", s.fileSystemRepresentation), p = path;
	}
	if (p && (to == 'fss ' || to == 'fsrf' || to == 'alis' || to == 'TEXT')) {
		if (to == 'TEXT')
			return item(it->key, to, p, (uint32_t)strlen(p));
		uint32_t tmp = gcalloc(1100);
		uint32_t n = 0;
		if (to == 'fss ') {
			fs_make_spec_for(p, tmp);
			n = 70;
		} else if (to == 'fsrf') {
			fs_make_ref_for(p, tmp);
			n = 80;
		} else {
			n = 8 + (uint32_t)strlen(p);
			ST16(tmp + 4, (uint16_t)n);
			memcpy(G(tmp + 8), p, strlen(p));
		}
		AEItem *r = item(it->key, to, G(tmp), n);
		gfree(tmp);
		return r;
	}
	// numbers
	if (it->data.length <= 8 && (to == 'long' || to == 'shor' || to == 'magn' || to == 'bool' || to == 'doub' || to == 'TEXT')) {
		const uint8_t *b = it->data.bytes;
		double v;
		switch (from) {
		case 'long': case 'magn': case 'enum': case 'type': if (it->data.length < 4) return nil; v = (int32_t)(b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3]); break;
		case 'shor': if (it->data.length < 2) return nil; v = (int16_t)(b[0] << 8 | b[1]); break;
		case 'bool': if (it->data.length < 1) return nil; v = b[0]; break;
		case 'true': v = 1; break;
		case 'fals': v = 0; break;
		default: return nil;
		}
		uint8_t o[8];
		switch (to) {
		case 'long': case 'magn': { uint32_t x = (uint32_t)(int32_t)v; o[0] = x >> 24; o[1] = x >> 16; o[2] = x >> 8; o[3] = x; return item(it->key, to, o, 4); }
		case 'shor': { uint16_t x = (uint16_t)(int16_t)v; o[0] = x >> 8; o[1] = x; return item(it->key, to, o, 2); }
		case 'bool': o[0] = v != 0; return item(it->key, to, o, 1);
		case 'TEXT': { char s[32]; snprintf(s, sizeof s, "%g", v); return item(it->key, to, s, (uint32_t)strlen(s)); }
		default: return nil;
		}
	}
	if (from == 'TEXT' && to == 'utf8') {
		NSString *s = mac_ns(it->data.bytes, it->data.length);
		NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
		return item(it->key, to, d.bytes, (uint32_t)d.length);
	}
	return nil;
}

// ---- descriptors ------------------------------------------------------------------------------------------

static void sh_AECreateDesc(PPC *c)
{
	// AECreateDesc(type, ptr, size, AEDesc *)
	uint32_t type = A(0);
	if (is_container(type)) {
		put_desc(A(3), item(0, type, NULL, 0));
		return RET_OK(c);
	}
	put_desc(A(3), item(0, type, A(1) ? G(A(1)) : "", A(1) ? A(2) : 0));
	RET(0);
}
static void sh_AEDisposeDesc(PPC *c)
{
	uint32_t d = A(0);
	if (!d)
		return RET_OK(c);
	uint32_t type = LD32(d), h = LD32(d + 4);
	if (h && is_container(type)) {
		AEItem *it = (__bridge AEItem *)hm_get(&containers, h);
		if (it) {
			hm_del(&containers, h);
			[alive removeObject:it];
		}
	}
	if (h && is_handle(h))
		DisposeHandleG(h);
	ST32(d, 'null');
	ST32(d + 4, 0);
	RET(0);
}
static void sh_AEDuplicateDesc(PPC *c)
{
	AEItem *it = get_desc(A(0));
	if (!it) {
		ST32(A(1), 'null');
		ST32(A(1) + 4, 0);
		return RET_OK(c);
	}
	put_desc(A(1), it);
	RET(0);
}
static void sh_AECoerceDesc(PPC *c)
{
	AEItem *it = coerce(get_desc(A(0)), A(1));
	if (!it) {
		ST32(A(2), 'null');
		ST32(A(2) + 4, 0);
		RET(errAECoercionFail);
		return;
	}
	put_desc(A(2), it);
	RET(0);
}
static void sh_AEGetDescDataSize(PPC *c) { AEItem *it = get_desc(A(0)); RET(it && it->data ? (uint32_t)it->data.length : 0); }
static void sh_AEGetDescData(PPC *c)
{
	AEItem *it = get_desc(A(0));
	if (!it || !it->data)
		return RET_ERR(c, errAENotAEDesc);
	uint32_t n = (uint32_t)it->data.length < A(2) ? (uint32_t)it->data.length : A(2);
	memcpy(G(A(1)), it->data.bytes, n);
	RET(0);
}

// ---- lists and records -------------------------------------------------------------------------------------

static void sh_AECreateList(PPC *c)
{
	// AECreateList(factoringPtr, factoredSize, isRecord, AEDescList *)
	put_desc(A(3), item(0, (A(2) & 0xff) ? 'reco' : 'list', NULL, 0));
	RET(0);
}
static void sh_AECountItems(PPC *c)
{
	AEItem *it = get_desc(A(0));
	if (!it || !it->kids)
		return RET_ERR(c, errAEWrongDataType);
	ST32(A(1), (uint32_t)it->kids.count);
	RET(0);
}
static void sh_AEGetNthDesc(PPC *c)
{
	// AEGetNthDesc(list, index, desiredType, AEKeyword *, AEDesc *)
	AEItem *l = get_desc(A(0));
	int32_t i = (int32_t)A(1);
	if (!l || !l->kids || i < 1 || i > (int32_t)l->kids.count)
		return RET_ERR(c, errAEBadListItem);
	AEItem *it = coerce(l->kids[i - 1], A(2));
	if (!it)
		return RET_ERR(c, errAECoercionFail);
	if (A(3))
		ST32(A(3), l->kids[i - 1]->key);
	put_desc(A(4), it);
	RET(0);
}
static int get_ptr(PPC *c, AEItem *src, uint32_t want, uint32_t typeOut, uint32_t ptr, uint32_t max, uint32_t actual)
{
	AEItem *it = coerce(src, want);
	if (!it || !it->data)
		return errAECoercionFail;
	if (typeOut)
		ST32(typeOut, it->type);
	uint32_t n = (uint32_t)it->data.length;
	if (actual)
		ST32(actual, n);
	if (ptr)
		memcpy(G(ptr), it->data.bytes, n < max ? n : max);
	(void)c;
	return 0;
}
static void sh_AEGetNthPtr(PPC *c)
{
	// AEGetNthPtr(list, index, desiredType, &keyword, &typeCode, dataPtr, maxSize, &actualSize)
	AEItem *l = get_desc(A(0));
	int32_t i = (int32_t)A(1);
	if (!l || !l->kids || i < 1 || i > (int32_t)l->kids.count)
		return RET_ERR(c, errAEBadListItem);
	if (A(3))
		ST32(A(3), l->kids[i - 1]->key);
	RET(get_ptr(c, l->kids[i - 1], A(2), A(4), A(5), A(6), A(7)));
}
static void sh_AEPutDesc(PPC *c)
{
	// AEPutDesc(list, index, desc): index 0 appends
	AEItem *l = get_desc(A(0));
	AEItem *it = get_desc(A(2));
	if (!l || !l->kids || !it)
		return RET_ERR(c, errAEWrongDataType);
	int32_t i = (int32_t)A(1);
	AEItem *cp = it->kids ? it : item(0, it->type, it->data.bytes, (uint32_t)it->data.length);
	if (i <= 0 || i > (int32_t)l->kids.count)
		[l->kids addObject:cp];
	else
		l->kids[i - 1] = cp;
	RET(0);
}
static void sh_AEPutPtr(PPC *c)
{
	AEItem *l = get_desc(A(0));
	if (!l || !l->kids)
		return RET_ERR(c, errAEWrongDataType);
	int32_t i = (int32_t)A(1);
	AEItem *it = item(0, A(2), G(A(3)), A(4));
	if (i <= 0 || i > (int32_t)l->kids.count)
		[l->kids addObject:it];
	else
		l->kids[i - 1] = it;
	RET(0);
}

// ---- events -----------------------------------------------------------------------------------------------

static void put_key(AEItem *ev, uint32_t key, AEItem *it)
{
	AEItem *cp = it->kids ? it : item(key, it->type, it->data.bytes, (uint32_t)it->data.length);
	cp->key = key;
	for (NSUInteger i = 0; i < ev->kids.count; i++)
		if (ev->kids[i]->key == key) {
			ev->kids[i] = cp;
			return;
		}
	[ev->kids addObject:cp];
}

static void sh_AEGetParamDesc(PPC *c)
{
	// AEGetParamDesc(event, keyword, desiredType, AEDesc *)
	AEItem *ev = get_desc(A(0));
	AEItem *p = ev && ev->kids ? find(ev->kids, A(1)) : nil;
	if (!p) {
		ST32(A(3), 'null');
		ST32(A(3) + 4, 0);
		return RET_ERR(c, errAEDescNotFound);
	}
	AEItem *it = coerce(p, A(2));
	if (!it)
		return RET_ERR(c, errAECoercionFail);
	put_desc(A(3), it);
	RET(0);
}
static void sh_AEGetParamPtr(PPC *c)
{
	// AEGetParamPtr(event, keyword, desiredType, &typeCode, dataPtr, maxSize, &actualSize)
	AEItem *ev = get_desc(A(0));
	AEItem *p = ev && ev->kids ? find(ev->kids, A(1)) : nil;
	if (!p)
		return RET_ERR(c, errAEDescNotFound);
	RET(get_ptr(c, p, A(2), A(3), A(4), A(5), A(6)));
}
static void sh_AEPutParamDesc(PPC *c)
{
	AEItem *ev = get_desc(A(0)), *it = get_desc(A(2));
	if (!ev || !ev->kids || !it)
		return RET_ERR(c, errAEWrongDataType);
	put_key(ev, A(1), it);
	RET(0);
}
static void sh_AEPutParamPtr(PPC *c)
{
	// AEPutParamPtr(event, keyword, type, ptr, size)
	AEItem *ev = get_desc(A(0));
	if (!ev || !ev->kids)
		return RET_ERR(c, errAEWrongDataType);
	put_key(ev, A(1), item(A(1), A(2), A(3) ? G(A(3)) : "", A(4)));
	RET(0);
}
static void sh_AEGetAttributePtr(PPC *c)
{
	// AEGetAttributePtr(event, keyword, desiredType, &typeCode, dataPtr, maxSize, &actualSize)
	AEItem *ev = get_desc(A(0));
	AEItem *p = ev && ev->attrs ? find(ev->attrs, A(1)) : nil;
	if (!p)
		return RET_ERR(c, errAEDescNotFound);
	RET(get_ptr(c, p, A(2), A(3), A(4), A(5), A(6)));
}
static void sh_AEGetAttributeDesc(PPC *c)
{
	AEItem *ev = get_desc(A(0));
	AEItem *p = ev && ev->attrs ? find(ev->attrs, A(1)) : nil;
	if (!p)
		return RET_ERR(c, errAEDescNotFound);
	put_desc(A(3), p);
	RET(0);
}

static AEItem *new_event(uint32_t cls, uint32_t eid)
{
	AEItem *ev = item(0, 'aevt', NULL, 0);
	ev->attrs = [NSMutableArray array];
	uint8_t b[4];
	b[0] = cls >> 24; b[1] = cls >> 16; b[2] = cls >> 8; b[3] = cls;
	[ev->attrs addObject:item('evcl', 'type', b, 4)];
	b[0] = eid >> 24; b[1] = eid >> 16; b[2] = eid >> 8; b[3] = eid;
	[ev->attrs addObject:item('evid', 'type', b, 4)];
	return ev;
}

static void sh_AECreateAppleEvent(PPC *c)
{
	// AECreateAppleEvent(class, id, target, returnID, transactionID, AppleEvent *)
	AEItem *ev = new_event(A(0), A(1));
	AEItem *t = get_desc(A(2));
	if (t) {
		AEItem *cp = t->kids ? t : item('addr', t->type, t->data.bytes, (uint32_t)t->data.length);
		cp->key = 'addr';
		[ev->attrs addObject:cp];
	}
	put_desc(A(5), ev);
	RET(0);
}

typedef struct { uint32_t cls, eid, handler, refcon; } Handler;
static Handler handlers[64];
static int nhandlers;

static void sh_AEInstallEventHandler(PPC *c)
{
	// AEInstallEventHandler(class, id, handler, refcon, isSysHandler)
	for (int i = 0; i < nhandlers; i++)
		if (handlers[i].cls == A(0) && handlers[i].eid == A(1)) {
			handlers[i].handler = A(2);
			handlers[i].refcon = A(3);
			return RET_OK(c);
		}
	if (nhandlers < 64)
		handlers[nhandlers++] = (Handler){A(0), A(1), A(2), A(3)};
	RET(0);
}
static void sh_AERemoveEventHandler(PPC *c)
{
	for (int i = 0; i < nhandlers; i++)
		if (handlers[i].cls == A(0) && handlers[i].eid == A(1)) {
			handlers[i] = handlers[--nhandlers];
			break;
		}
	RET(0);
}

static uint32_t current_event;

static int dispatch(AEItem *ev, uint32_t cls, uint32_t eid)
{
	Handler *h = NULL;
	for (int i = 0; i < nhandlers; i++)
		if ((handlers[i].cls == cls || handlers[i].cls == '****') && (handlers[i].eid == eid || handlers[i].eid == '****')) {
			h = &handlers[i];
			if (handlers[i].cls == cls && handlers[i].eid == eid)
				break;
		}
	if (!h) {
		ppc_log("AE %c%c%c%c/%c%c%c%c: no handler\n", cls >> 24, cls >> 16, cls >> 8, cls, eid >> 24, eid >> 16, eid >> 8, eid);
		return errAEEventNotHandled;
	}
	uint32_t evd = gcalloc(8), rep = gcalloc(8);
	put_desc(evd, ev);
	put_desc(rep, item(0, 'aevt', NULL, 0));
	uint32_t save = current_event;
	current_event = evd;
	int r = (int16_t)ppc_cb3(h->handler, evd, rep, h->refcon);
	current_event = save;
	ppc_cpu->r[3] = 0;
	// dispose both
	uint32_t hs[2] = {LD32(evd + 4), LD32(rep + 4)};
	for (int i = 0; i < 2; i++) {
		AEItem *it = (__bridge AEItem *)hm_get(&containers, hs[i]);
		if (it) {
			hm_del(&containers, hs[i]);
			[alive removeObject:it];
		}
		if (hs[i] && is_handle(hs[i]))
			DisposeHandleG(hs[i]);
	}
	gfree(evd);
	gfree(rep);
	return r;
}

// documents to open, from the Finder (application:openFiles:)
static NSMutableArray<NSString *> *pending_docs;

void ae_open_documents(NSArray<NSString *> *paths)
{
	if (!pending_docs)
		pending_docs = [NSMutableArray array];
	[pending_docs addObjectsFromArray:paths];
	Ev e = {0};
	e.what = 23;
	e.message = 'aevt';
	e.where = (QPoint){(int16_t)('odoc' >> 16), (int16_t)('odoc' & 0xffff)};
	ev_post(e);
}

static void sh_AEProcessAppleEvent(PPC *c)
{
	uint32_t er = A(0);
	uint32_t cls = LD32(er + 2);
	QPoint w = LDPT(er + 10);
	uint32_t eid = (uint32_t)(uint16_t)w.v << 16 | (uint16_t)w.h;
	AEItem *ev = new_event(cls, eid);
	if (eid == 'odoc' && pending_docs.count) {
		AEItem *list = item('----', 'list', NULL, 0);
		for (NSString *p in pending_docs) {
			uint32_t tmp = gcalloc(80);
			fs_make_spec_for(p.fileSystemRepresentation, tmp);
			[list->kids addObject:item(0, 'fss ', G(tmp), 70)];
			gfree(tmp);
		}
		[pending_docs removeAllObjects];
		[ev->kids addObject:list];
	}
	int r = dispatch(ev, cls, eid);
	if (eid == 'quit' && r == errAEEventNotHandled)
		exit(0);
	RET(r == errAEEventNotHandled ? r : 0);
}
static void sh_AEGetTheCurrentEvent(PPC *c)
{
	if (current_event) {
		ST32(A(0), LD32(current_event));
		ST32(A(0) + 4, LD32(current_event + 4));
	} else {
		ST32(A(0), 'null');
		ST32(A(0) + 4, 0);
	}
	RET(0);
}
static void sh_AESend(PPC *c)
{
	// AESend(event, reply, sendMode, priority, timeout, idle, filter)
	AEItem *ev = get_desc(A(0));
	AEItem *cl = ev ? find(ev->attrs, 'evcl') : nil, *id = ev ? find(ev->attrs, 'evid') : nil;
	AEItem *addr = ev ? find(ev->attrs, 'addr') : nil;
	uint32_t cls = cl && cl->data.length >= 4 ? OSReadBigInt32(cl->data.bytes, 0) : 0;
	uint32_t eid = id && id->data.length >= 4 ? OSReadBigInt32(id->data.bytes, 0) : 0;
	if (A(1))
		put_desc(A(1), item(0, 'aevt', NULL, 0));
	// to ourselves (kCurrentProcess)
	if (addr && addr->type == 'psn ' && addr->data.length >= 8 && OSReadBigInt32(addr->data.bytes, 4) == 2) {
		RET(dispatch(ev, cls, eid) == errAEEventNotHandled ? errAEEventNotHandled : 0);
		return;
	}
	ppc_log("AESend %c%c%c%c/%c%c%c%c to another application: dropped\n", cls >> 24, cls >> 16, cls >> 8, cls, eid >> 24,
		eid >> 16, eid >> 8, eid);
	RET(0);
}
static void sh_AEInteractWithUser(PPC *c) { (void)c; RET(0); }
static void sh_AEManagerInfo(PPC *c) { if (A(1)) ST32(A(1), 0); RET(0); }
static void sh_AEObjectInit(PPC *c) { (void)c; RET(0); }
static void sh_AESetObjectCallbacks(PPC *c) { (void)c; RET(0); }
static void sh_AEInstallObjectAccessor(PPC *c) { (void)c; RET(0); }
static void sh_AEResolve(PPC *c)
{
	if (A(2)) {
		ST32(A(2), 'null');
		ST32(A(2) + 4, 0);
	}
	RET(errAENoSuchObject);
}
static void sh_CreateOffsetDescriptor(PPC *c)
{
	uint8_t b[4];
	uint32_t v = A(0);
	b[0] = v >> 24; b[1] = v >> 16; b[2] = v >> 8; b[3] = v;
	put_desc(A(1), item(0, 'long', b, 4));
	RET(0);
}
static void sh_CreateObjSpecifier(PPC *c)
{
	// CreateObjSpecifier(desiredClass, container, keyForm, keyData, disposeInputs, &result)
	AEItem *r = item(0, 'reco', NULL, 0);
	uint8_t b[4];
	uint32_t v = A(0);
	b[0] = v >> 24; b[1] = v >> 16; b[2] = v >> 8; b[3] = v;
	[r->kids addObject:item('want', 'type', b, 4)];
	v = A(2);
	b[0] = v >> 24; b[1] = v >> 16; b[2] = v >> 8; b[3] = v;
	[r->kids addObject:item('form', 'enum', b, 4)];
	AEItem *k = get_desc(A(3));
	if (k)
		put_key(r, 'seld', k);
	AEItem *ct = get_desc(A(1));
	if (ct)
		put_key(r, 'from', ct);
	r->type = 'obj ';
	// an object specifier as a record whose type is 'obj '
	AEItem *rec = [AEItem new];
	rec->type = 'reco';
	rec->kids = r->kids;
	put_desc(A(5), rec);
	ST32(A(5), 'obj ');
	RET(0);
}

// an AEDescList of FSSpecs ('fss ') or FSRefs ('fsrf') for host paths
void ae_make_path_list(uint32_t desc, NSArray<NSString *> *paths, uint32_t type)
{
	AEItem *list = item(0, 'list', NULL, 0);
	for (NSString *p in paths) {
		uint32_t tmp = gcalloc(96);
		if (type == 'fsrf')
			fs_make_ref_for(p.fileSystemRepresentation, tmp);
		else
			fs_make_spec_for(p.fileSystemRepresentation, tmp);
		[list->kids addObject:item(0, type, G(tmp), type == 'fsrf' ? 80 : 70)];
		gfree(tmp);
	}
	put_desc(desc, list);
}

void ae_dispose(uint32_t d)
{
	uint32_t type = LD32(d), h = LD32(d + 4);
	if (h && is_container(type)) {
		AEItem *it = (__bridge AEItem *)hm_get(&containers, h);
		if (it) {
			hm_del(&containers, h);
			[alive removeObject:it];
		}
	}
	if (h && is_handle(h))
		DisposeHandleG(h);
	ST32(d, 'null');
	ST32(d + 4, 0);
}

static const ShimDef aeshims[] = {
	S(AECreateDesc), S(AEDisposeDesc), S(AEDuplicateDesc), S(AECoerceDesc), S(AEGetDescDataSize), S(AEGetDescData),
	S(AECreateList), S(AECountItems), S(AEGetNthDesc), S(AEGetNthPtr), S(AEPutDesc), S(AEPutPtr),
	S(AEGetParamDesc), S(AEGetParamPtr), S(AEPutParamDesc), S(AEPutParamPtr), S(AEGetAttributePtr),
	S(AEGetAttributeDesc), S(AECreateAppleEvent), S(AEInstallEventHandler), S(AERemoveEventHandler),
	S(AEProcessAppleEvent), S(AEGetTheCurrentEvent), S(AESend), S(AEInteractWithUser), S(AEManagerInfo),
	S(AEObjectInit), S(AESetObjectCallbacks), S(AEInstallObjectAccessor), S(AEResolve), S(CreateOffsetDescriptor),
	S(CreateObjSpecifier),
};
REGISTER(aeshims)
