// Resource Manager: resource forks parsed in memory, resources as guest
// handles, written back to the fork when changed. File 0 is a small System file
// made here (system cursors, patterns, international resources).
#import <Foundation/Foundation.h>
#include "ppcrt.h"
#include "hmap.h"
#include <sys/stat.h>

typedef struct Res {
	uint32_t type;
	int16_t id;
	uint8_t attrs;
	uint8_t name[256];
	uint8_t *data;         // the bytes in the file (or written)
	uint32_t len;
	uint32_t h;            // loaded handle
	int changed;
	struct RFile *file;
} Res;

typedef struct RFile {
	int16_t ref;
	char path[1024];
	int writable, dirty;
	int datafork;          // resources in the data fork (FSOpenResourceFile with the data fork's name)
	Res **res;
	int n, cap;
	uint16_t attrs;
	struct RFile *next;    // the chain: newer files first
} RFile;

static RFile *chain;       // most recently opened first
static RFile *cur;
static int16_t res_err, next_ref = 100;
static int res_load = 1;
static HMap by_handle;     // handle -> Res
static RFile *sysfile, *appfile;

void mem_set_resource_flag(uint32_t h, int on);
const char *fsspec_path(uint32_t spec, char *out, size_t n);
const char *fsref_path(uint32_t ref, char *out, size_t n);
int fs_make_spec_for(const char *path, uint32_t spec);

static Res *add_res(RFile *f, uint32_t type, int16_t id, const uint8_t *name, uint8_t attrs, const void *data, uint32_t len)
{
	if (f->n == f->cap) {
		f->cap = f->cap ? f->cap * 2 : 64;
		f->res = realloc(f->res, f->cap * sizeof *f->res);
	}
	Res *r = calloc(1, sizeof *r);
	r->type = type;
	r->id = id;
	r->attrs = attrs;
	if (name)
		memcpy(r->name, name, name[0] + 1);
	r->data = malloc(len ? len : 1);
	memcpy(r->data, data, len);
	r->len = len;
	r->file = f;
	f->res[f->n++] = r;
	return r;
}

static int parse_fork(RFile *f, const uint8_t *d, size_t n)
{
	if (n < 16)
		return n == 0 ? 0 : -1;
	uint32_t doff = __builtin_bswap32(*(uint32_t *)d), moff = __builtin_bswap32(*(uint32_t *)(d + 4));
	uint32_t mlen = __builtin_bswap32(*(uint32_t *)(d + 12));
	if (moff + mlen > n || moff + 30 > n)
		return -1;
	const uint8_t *m = d + moff;
#define B16(p) ((uint16_t)((p)[0] << 8 | (p)[1]))
#define B32(p) ((uint32_t)((p)[0] << 24 | (p)[1] << 16 | (p)[2] << 8 | (p)[3]))
	f->attrs = B16(m + 22);
	uint16_t tl = B16(m + 24), nl = B16(m + 26);
	int ntypes = (int16_t)B16(m + tl) + 1;
	for (int i = 0; i < ntypes; i++) {
		const uint8_t *t = m + tl + 2 + 8 * i;
		uint32_t type = B32(t);
		int cnt = B16(t + 4) + 1;
		uint16_t rl = B16(t + 6);
		for (int k = 0; k < cnt; k++) {
			const uint8_t *e = m + tl + rl + 12 * k;
			int16_t id = (int16_t)B16(e);
			uint16_t no = B16(e + 2);
			uint8_t attrs = e[4];
			uint32_t off = B32(e + 4) & 0xffffff;
			if (doff + off + 4 > n)
				continue;
			uint32_t len = B32(d + doff + off);
			if (doff + off + 4 + len > n)
				len = (uint32_t)(n - doff - off - 4);
			uint8_t name[256] = {0};
			if (no != 0xffff && moff + nl + no < n)
				memcpy(name, m + nl + no, m[nl + no] + 1);
			add_res(f, type, id, name, attrs, d + doff + off + 4, len);
		}
	}
	return 0;
}

static RFile *find_file(int16_t ref)
{
	for (RFile *f = chain; f; f = f->next)
		if (f->ref == ref)
			return f;
	return NULL;
}

static Res *find_in(RFile *f, uint32_t type, int16_t id)
{
	for (int i = 0; i < f->n; i++)
		if (f->res[i]->type == type && f->res[i]->id == id)
			return f->res[i];
	return NULL;
}

static Res *find_named_in(RFile *f, uint32_t type, const uint8_t *name)
{
	for (int i = 0; i < f->n; i++)
		if (f->res[i]->type == type && f->res[i]->name[0] == name[0] &&
			!strncasecmp((const char *)f->res[i]->name + 1, (const char *)name + 1, name[0]))
			return f->res[i];
	return NULL;
}

static uint32_t load(Res *r)
{
	if (r->h && is_handle(r->h) && HP(r->h))
		return r->h;
	r->h = NewHandleFrom(r->data, r->len);
	mem_set_resource_flag(r->h, 1);
	hm_put(&by_handle, r->h, r);
	return r->h;
}

// search from the current file down the chain
static Res *search(uint32_t type, int16_t id, int one)
{
	for (RFile *f = cur; f; f = f->next) {
		Res *r = find_in(f, type, id);
		if (r)
			return r;
		if (one)
			break;
	}
	if (!one && cur != sysfile && sysfile)
		return find_in(sysfile, type, id);
	return NULL;
}

uint32_t res_get(uint32_t type, int16_t id, int one)
{
	Res *r = search(type, id, one);
	if (!r) {
		res_err = -192;   // resNotFound
		return 0;
	}
	res_err = 0;
	return load(r);
}

// for the host: the bytes of a resource without making a handle
const uint8_t *res_bytes(uint32_t type, int16_t id, uint32_t *len)
{
	Res *r = search(type, id, 0);
	if (!r)
		return NULL;
	*len = r->len;
	return r->data;
}

// ---- writing --------------------------------------------------------------------------------

static void sync_from_handle(Res *r)
{
	if (r->h && is_handle(r->h) && HP(r->h)) {
		uint32_t n = HSize(r->h);
		r->data = realloc(r->data, n ? n : 1);
		memcpy(r->data, G(HP(r->h)), n);
		r->len = n;
	}
}

static int write_file(RFile *f)
{
	if (!f->writable || !f->path[0])
		return -61;
	for (int i = 0; i < f->n; i++)
		if (f->res[i]->changed) {
			sync_from_handle(f->res[i]);
			f->res[i]->changed = 0;
		}
	NSMutableData *data = [NSMutableData data];
	NSMutableData *names = [NSMutableData data];
	// the types
	NSMutableArray *types = [NSMutableArray array];
	for (int i = 0; i < f->n; i++)
		if (![types containsObject:@(f->res[i]->type)])
			[types addObject:@(f->res[i]->type)];
	NSMutableData *tlist = [NSMutableData data], *rlist = [NSMutableData data];
	uint8_t b[16];
	uint16_t nt = (uint16_t)(types.count - 1);
	b[0] = nt >> 8;
	b[1] = (uint8_t)nt;
	[tlist appendBytes:b length:2];
	uint32_t rl_base = 2 + 8 * (uint32_t)types.count;
	for (NSNumber *tn in types) {
		uint32_t t = tn.unsignedIntValue;
		int cnt = 0;
		uint32_t rl_off = rl_base + (uint32_t)rlist.length;
		for (int i = 0; i < f->n; i++) {
			Res *r = f->res[i];
			if (r->type != t)
				continue;
			cnt++;
			uint32_t off = (uint32_t)data.length;
			uint8_t lb[4] = {r->len >> 24, r->len >> 16, r->len >> 8, (uint8_t)r->len};
			[data appendBytes:lb length:4];
			[data appendBytes:r->data length:r->len];
			uint16_t no = 0xffff;
			if (r->name[0]) {
				no = (uint16_t)names.length;
				[names appendBytes:r->name length:r->name[0] + 1];
			}
			uint8_t e[12] = {(uint8_t)(r->id >> 8), (uint8_t)r->id, no >> 8, (uint8_t)no, r->attrs & ~2,
				(uint8_t)(off >> 16), (uint8_t)(off >> 8), (uint8_t)off, 0, 0, 0, 0};
			[rlist appendBytes:e length:12];
		}
		uint8_t te[8] = {t >> 24, t >> 16, t >> 8, (uint8_t)t, (uint8_t)((cnt - 1) >> 8), (uint8_t)(cnt - 1),
			(uint8_t)(rl_off >> 8), (uint8_t)rl_off};
		[tlist appendBytes:te length:8];
	}
	uint32_t doff = 256, dlen = (uint32_t)data.length;
	uint32_t moff = doff + dlen;
	uint16_t tl_off = 28, nl_off = (uint16_t)(28 + tlist.length + rlist.length);
	uint32_t mlen = nl_off + (uint32_t)names.length;
	NSMutableData *out = [NSMutableData dataWithLength:256];
	uint8_t *h = out.mutableBytes;
	uint32_t hv[4] = {__builtin_bswap32(doff), __builtin_bswap32(moff), __builtin_bswap32(dlen), __builtin_bswap32(mlen)};
	memcpy(h, hv, 16);
	[out appendData:data];
	NSMutableData *map = [NSMutableData dataWithLength:28];
	uint8_t *mp = map.mutableBytes;
	memcpy(mp, hv, 16);
	mp[22] = f->attrs >> 8;
	mp[23] = (uint8_t)f->attrs;
	mp[24] = 0;
	mp[25] = (uint8_t)tl_off;
	mp[26] = nl_off >> 8;
	mp[27] = (uint8_t)nl_off;
	[map appendData:tlist];
	[map appendData:rlist];
	[map appendData:names];
	[out appendData:map];
	NSString *rp = f->datafork ? @(f->path) : [@(f->path) stringByAppendingString:@"/..namedfork/rsrc"];
	if (![out writeToFile:rp atomically:NO]) {
		ppc_log("cannot write the resource fork of %s", f->path);
		return -34;
	}
	f->dirty = 0;
	return 0;
}

// ---- opening ------------------------------------------------------------------------------------

static RFile *open_path2(const char *path, int perm, int16_t *err, int datafork)
{
	// already open?
	for (RFile *f = chain; f; f = f->next)
		if (!strcmp(f->path, path)) {
			*err = 0;
			return f;
		}
	NSString *rp = datafork ? @(path) : [@(path) stringByAppendingString:@"/..namedfork/rsrc"];
	NSData *d = [NSData dataWithContentsOfFile:rp];
	struct stat st;
	if (stat(path, &st) != 0) {
		*err = -43;   // fnfErr
		return NULL;
	}
	if (!d || d.length == 0) {
		*err = -39;   // eofErr: no resource fork
		return NULL;
	}
	RFile *f = calloc(1, sizeof *f);
	snprintf(f->path, sizeof f->path, "%s", path);
	f->writable = perm != 1;   // fsRdPerm
	f->datafork = datafork;
	if (parse_fork(f, d.bytes, d.length) != 0) {
		free(f);
		*err = -199;   // mapReadErr
		return NULL;
	}
	f->ref = next_ref++;
	f->next = chain;
	chain = f;
	cur = f;
	*err = 0;
	return f;
}

static RFile *open_path(const char *path, int perm, int16_t *err)
{
	return open_path2(path, perm, err, 0);
}

static void close_file(RFile *f)
{
	if (!f || f == sysfile || f == appfile)
		return;
	if (f->dirty)
		write_file(f);
	for (RFile **p = &chain; *p; p = &(*p)->next)
		if (*p == f) {
			*p = f->next;
			break;
		}
	for (int i = 0; i < f->n; i++) {
		Res *r = f->res[i];
		if (r->h) {
			hm_del(&by_handle, r->h);
			DisposeHandleG(r->h);
		}
		free(r->data);
		free(r);
	}
	free(f->res);
	if (cur == f)
		cur = chain;
	free(f);
}

static void make_system(void)
{
	sysfile = calloc(1, sizeof *sysfile);
	sysfile->ref = 0;
	snprintf(sysfile->path, sizeof sysfile->path, "");
	// system cursors: marked so SetCursor picks the Cocoa cursor (see qd.m)
	const char *cur_marks[] = {"iBem", "cros", "plus", "watc"};
	for (int i = 0; i < 4; i++) {
		uint8_t cdata[68] = {0};
		cdata[0] = 0xff;
		memcpy(cdata + 1, "SYS", 3);
		memcpy(cdata + 4, cur_marks[i], 4);
		cdata[64] = 0;
		cdata[65] = 8;
		cdata[66] = 0;
		cdata[67] = 8;
		add_res(sysfile, 'CURS', (int16_t)(i + 1), NULL, 0, cdata, 68);
	}
	// itl0: number and time formats (U.S.)
	uint8_t itl0[42] = {'.', ',', ';', '$', 0, 0, 0, 0, 0xf6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
	itl0[10] = 0;   // dateOrder mdy
	itl0[11] = 0x40;
	itl0[12] = '/';
	add_res(sysfile, 'itl0', 0, NULL, 0, itl0, sizeof itl0);
}

// write every changed file (at exit)
void res_flush_all(void)
{
	for (RFile *f = chain; f; f = f->next) {
		int any = f->dirty;
		for (int i = 0; i < f->n && !any; i++)
			any = f->res[i]->changed;
		if (any && f->writable)
			write_file(f);
	}
}

void res_init(const char *app_rsrc)
{
	make_system();
	NSData *d = [NSData dataWithContentsOfFile:@(app_rsrc)];
	appfile = calloc(1, sizeof *appfile);
	appfile->ref = 1;
	snprintf(appfile->path, sizeof appfile->path, "");
	if (d)
		parse_fork(appfile, d.bytes, d.length);
	else
		ppc_log("no resources: %s", app_rsrc);
	appfile->next = sysfile;
	chain = appfile;
	cur = appfile;
	sysfile->next = NULL;
}

// ---- shims ------------------------------------------------------------------------------------------

static void sh_CurResFile(PPC *c) { RET(cur ? cur->ref : 0); }
static void sh_UseResFile(PPC *c)
{
	RFile *f = (int16_t)A(0) == 0 ? sysfile : find_file((int16_t)A(0));
	if (f) {
		cur = f;
		res_err = 0;
	} else
		res_err = -193;   // resFNotFound
}
static void sh_ResError(PPC *c) { RET((int32_t)res_err); }
static void sh_SetResLoad(PPC *c) { res_load = A(0) & 0xff; }
static void sh_LMGetResLoad(PPC *c) { RET(res_load); }
static void sh_GetResource(PPC *c) { RET(res_get(A(0), (int16_t)A(1), 0)); }
static void sh_Get1Resource(PPC *c) { RET(res_get(A(0), (int16_t)A(1), 1)); }
static void named(PPC *c, int one)
{
	uint8_t name[256];
	memcpy(name, G(A(1)), LD8(A(1)) + 1);
	for (RFile *f = cur; f; f = f->next) {
		Res *r = find_named_in(f, A(0), name);
		if (r) {
			res_err = 0;
			RET(load(r));
			return;
		}
		if (one)
			break;
	}
	res_err = -192;
	RET(0);
}
static void sh_GetNamedResource(PPC *c) { named(c, 0); }
static void sh_Get1NamedResource(PPC *c) { named(c, 1); }
static void sh_CountResources(PPC *c)
{
	int n = 0;
	for (RFile *f = cur; f; f = f->next)
		for (int i = 0; i < f->n; i++)
			n += f->res[i]->type == A(0);
	RET(n);
}
static void sh_GetIndResource(PPC *c)
{
	int k = (int16_t)A(1);
	for (RFile *f = cur; f; f = f->next)
		for (int i = 0; i < f->n; i++)
			if (f->res[i]->type == A(0) && --k == 0) {
				res_err = 0;
				RET(load(f->res[i]));
				return;
			}
	res_err = -192;
	RET(0);
}
static void sh_ReleaseResource(PPC *c)
{
	Res *r = hm_get(&by_handle, A(0));
	if (!r) {
		res_err = -192;
		return;
	}
	if (r->changed) {
		res_err = 0;
		return;   // keep changed resources until written
	}
	hm_del(&by_handle, r->h);
	DisposeHandleG(r->h);
	r->h = 0;
	res_err = 0;
}
static void sh_DetachResource(PPC *c)
{
	Res *r = hm_get(&by_handle, A(0));
	if (r) {
		hm_del(&by_handle, r->h);
		mem_set_resource_flag(r->h, 0);
		r->h = 0;
	}
	res_err = 0;
}
static void sh_GetResInfo(PPC *c)
{
	Res *r = hm_get(&by_handle, A(0));
	if (!r) {
		res_err = -192;
		return;
	}
	if (A(1))
		ST16(A(1), r->id);
	if (A(2))
		ST32(A(2), r->type);
	if (A(3))
		memcpy(G(A(3)), r->name, r->name[0] + 1);
	res_err = 0;
}
static void sh_SetResInfo(PPC *c)
{
	Res *r = hm_get(&by_handle, A(0));
	if (!r) {
		res_err = -192;
		return;
	}
	r->id = (int16_t)A(1);
	if (A(2))
		memcpy(r->name, G(A(2)), LD8(A(2)) + 1);
	r->file->dirty = 1;
	res_err = 0;
}
static void sh_GetResAttrs(PPC *c) { Res *r = hm_get(&by_handle, A(0)); RET(r ? r->attrs : 0); res_err = r ? 0 : -192; }
static void sh_SetResAttrs(PPC *c)
{
	Res *r = hm_get(&by_handle, A(0));
	if (r) {
		r->attrs = (uint8_t)A(1);
		r->file->dirty = 1;
	}
	res_err = r ? 0 : -192;
}
static void sh_AddResource(PPC *c)
{
	// AddResource(h, type, id, name): to the current file
	if (!cur || cur == sysfile || cur == appfile) {
		res_err = -194;   // addResFailed
		return;
	}
	uint8_t name[256] = {0};
	if (A(3))
		memcpy(name, G(A(3)), LD8(A(3)) + 1);
	uint32_t h = A(0);
	Res *old = find_in(cur, A(1), (int16_t)A(2));
	(void)old;
	Res *r = add_res(cur, A(1), (int16_t)A(2), name, 0, G(HP(h)), HSize(h));
	r->h = h;
	r->changed = 1;
	mem_set_resource_flag(h, 1);
	hm_put(&by_handle, h, r);
	cur->dirty = 1;
	res_err = 0;
}
static void sh_ChangedResource(PPC *c)
{
	Res *r = hm_get(&by_handle, A(0));
	if (r) {
		r->changed = 1;
		r->file->dirty = 1;
	}
	res_err = r ? 0 : -192;
}
static void sh_RemoveResource(PPC *c)
{
	Res *r = hm_get(&by_handle, A(0));
	if (!r) {
		res_err = -192;
		return;
	}
	RFile *f = r->file;
	for (int i = 0; i < f->n; i++)
		if (f->res[i] == r) {
			memmove(f->res + i, f->res + i + 1, (f->n - i - 1) * sizeof *f->res);
			f->n--;
			break;
		}
	hm_del(&by_handle, r->h);
	mem_set_resource_flag(r->h, 0);
	free(r->data);
	free(r);
	f->dirty = 1;
	res_err = 0;
}
static void sh_WriteResource(PPC *c)
{
	Res *r = hm_get(&by_handle, A(0));
	if (r && r->changed) {
		sync_from_handle(r);
		res_err = (int16_t)write_file(r->file);
	} else
		res_err = 0;
}
static void sh_UpdateResFile(PPC *c)
{
	RFile *f = find_file((int16_t)A(0));
	res_err = f && f->dirty ? (int16_t)write_file(f) : 0;
}
static void sh_CloseResFile(PPC *c)
{
	close_file(find_file((int16_t)A(0)));
	res_err = 0;
}

static void open_common(PPC *c, const char *path, int perm)
{
	int16_t err = 0;
	RFile *f = path ? open_path(path, perm, &err) : NULL;
	res_err = f ? 0 : (err ? err : -43);
	RET(f ? f->ref : -1);
}
static void sh_FSpOpenResFile(PPC *c)
{
	char p[1024];
	open_common(c, fsspec_path(A(0), p, sizeof p), (int8_t)A(1));
}
static void sh_HOpenResFile(PPC *c)
{
	// HOpenResFile(vRefNum, dirID, fileName, permission)
	extern const char *fs_path3(int16_t vref, int32_t dir, uint32_t name, char *out, size_t n);
	char p[1024];
	open_common(c, fs_path3((int16_t)A(0), (int32_t)A(1), A(2), p, sizeof p), (int8_t)A(3));
}
static void sh_FSOpenResourceFile(PPC *c)
{
	// FSOpenResourceFile(const FSRef *, forkNameLength, forkName, permissions, SInt16 *refNum)
	char p[1024];
	const char *path = fsref_path(A(0), p, sizeof p);
	int16_t err = 0;
	RFile *f = path ? open_path2(path, (int8_t)A(3), &err, A(1) == 0) : NULL;
	if (f)
		ST16(A(4), f->ref);
	res_err = f ? 0 : (err ? err : -43);
	RET((int32_t)res_err);
}
static void sh_FSpCreateResFile(PPC *c)
{
	char p[1024];
	const char *path = fsspec_path(A(0), p, sizeof p);
	if (!path) {
		res_err = -43;
		return;
	}
	extern void fs_set_type(const char *path, uint32_t type, uint32_t creator);
	FILE *fp = fopen(path, "ab");
	if (fp)
		fclose(fp);
	fs_set_type(path, A(2), A(1));
	RFile tmp = {0};
	snprintf(tmp.path, sizeof tmp.path, "%s", path);
	tmp.writable = 1;
	// an empty map
	NSString *rp = [@(path) stringByAppendingString:@"/..namedfork/rsrc"];
	NSData *d = [NSData dataWithContentsOfFile:rp];
	if (!d.length)
		write_file(&tmp);
	res_err = 0;
}

// strings
static void sh_GetString(PPC *c) { RET(res_get('STR ', (int16_t)A(0), 0)); }
static void sh_GetIndString(PPC *c)
{
	// GetIndString(Str255 out, strListID, index)
	uint32_t out = A(0);
	ST8(out, 0);
	uint32_t h = res_get('STR#', (int16_t)A(1), 0);
	int idx = (int16_t)A(2);
	if (!h || idx < 1)
		return;
	uint32_t p = HP(h), n = LD16(p);
	if ((uint32_t)idx > n)
		return;
	p += 2;
	for (int i = 1; i < idx; i++)
		p += 1 + LD8(p);
	memcpy(G(out), G(p), LD8(p) + 1);
}
static void sh_GetPicture(PPC *c) { RET(res_get('PICT', (int16_t)A(0), 0)); }
static void sh_GetCursor(PPC *c) { RET(res_get('CURS', (int16_t)A(0), 0)); }
static void sh_GetIntlResource(PPC *c) { RET(res_get(A(0) == 0 ? 'itl0' : A(0) == 1 ? 'itl1' : A(0) == 2 ? 'itl2' : 'itl4', 0, 0)); }

static const ShimDef resshims[] = {
	S(CurResFile), S(UseResFile), S(ResError), S(SetResLoad), S(LMGetResLoad), S(GetResource), S(Get1Resource),
	S(GetNamedResource), S(Get1NamedResource), S(CountResources), S(GetIndResource), S(ReleaseResource),
	S(DetachResource), S(GetResInfo), S(SetResInfo), S(GetResAttrs), S(SetResAttrs), S(AddResource),
	S(ChangedResource), S(RemoveResource), S(WriteResource), S(UpdateResFile), S(CloseResFile), S(FSpOpenResFile),
	S(HOpenResFile), S(FSOpenResourceFile), S(FSpCreateResFile), S(GetString), S(GetIndString), S(GetPicture),
	S(GetCursor), S(GetIntlResource),
};
REGISTER(resshims)
