// The NSMapTable / NSHashTable C functions with guest keys and values.
//
// Keys and values are 32-bit guest words: object handles, guest pointers or
// integers. The callback structs arrive by value, as copies of the tagged
// blocks data.m makes for the Foundation callbacks; object keys compare with
// -isEqual: and -hash on their host objects, anything else by identity.
#import <Foundation/Foundation.h>
#include "rt.h"

#define A(i) xl_arg(c, i)

@interface XLGEntry : NSObject {
@public
	uint32_t key, value;
}
@end
@implementation XLGEntry
@end

@interface XLGTable : NSObject {
@public
	uint32_t kflags, vflags;
	NSMapTable *map;       // key -> XLGEntry
}
@end

@implementation XLGTable
- (instancetype)initWithKeyFlags:(uint32_t)kf valueFlags:(uint32_t)vf
{
	if ((self = [super init])) {
		kflags = kf;
		vflags = vf;
		map = (kf & XL_CB_OBJECT) ? [[NSMapTable strongToStrongObjectsMapTable] retain]
			: [[NSMapTable mapTableWithKeyOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality
				valueOptions:NSPointerFunctionsStrongMemory] retain];
	}
	return self;
}

static void drop(uint32_t flags, uint32_t w)
{
	if (!w)
		return;
	if ((flags & (XL_CB_OBJECT | XL_CB_RETAIN)) == (XL_CB_OBJECT | XL_CB_RETAIN))
		[(id)xl_p(w) release];
	else if (flags & XL_CB_FREE)
		xl_free(w);
}

static void keep(uint32_t flags, uint32_t w)
{
	if (w && (flags & (XL_CB_OBJECT | XL_CB_RETAIN)) == (XL_CB_OBJECT | XL_CB_RETAIN))
		[(id)xl_p(w) retain];
}

- (id)mapKey:(uint32_t)k
{
	if (kflags & XL_CB_OBJECT)
		return k ? (id)xl_p(k) : nil;
	return (id)(void *)((uint64_t)k | (1ULL << 40));    // never NULL, never an object
}

- (XLGEntry *)entry:(uint32_t)k
{
	id mk = [self mapKey:k];
	return mk ? [map objectForKey:mk] : nil;
}

- (void)put:(uint32_t)k value:(uint32_t)v
{
	id mk = [self mapKey:k];
	if (!mk)
		return;
	XLGEntry *e = [map objectForKey:mk];
	if (e) {
		keep(vflags, v);
		drop(vflags, e->value);
		e->value = v;
		return;
	}
	e = [[XLGEntry new] autorelease];
	keep(kflags, k);
	keep(vflags, v);
	e->key = k;
	e->value = v;
	[map setObject:e forKey:mk];
}

- (void)remove:(uint32_t)k
{
	id mk = [self mapKey:k];
	XLGEntry *e = mk ? [map objectForKey:mk] : nil;
	if (!e)
		return;
	[e retain];
	[map removeObjectForKey:mk];
	drop(kflags, e->key);
	drop(vflags, e->value);
	[e release];
}

- (void)reset
{
	for (XLGEntry *e in [[map objectEnumerator] allObjects]) {
		drop(kflags, e->key);
		drop(vflags, e->value);
	}
	[map removeAllObjects];
}

- (void)dealloc
{
	[self reset];
	[map release];
	[super dealloc];
}
@end

static XLGTable *T(uint32_t h)
{
	return h ? (XLGTable *)xl_p(h) : nil;
}

// a callbacks struct at guest address a: its flags if it is a tagged copy
static uint32_t cb_flags(uint32_t a)
{
	uint32_t *w = (uint32_t *)GP(a);
	return w[0] == XL_CB_MAGIC ? w[1] : 0;
}

static uint32_t new_table(uint32_t kf, uint32_t vf)
{
	XLGTable *t = [[XLGTable alloc] initWithKeyFlags:kf valueFlags:vf];
	return xl_h(t);
}

// ---- map tables ------------------------------------------------------------------------------
// NSCreateMapTable(NSMapTableKeyCallBacks (6 words), NSMapTableValueCallBacks (3 words), capacity)
void xl_sh_NSCreateMapTable(XLCPU *c)
{
	uint32_t a = c->r[ESP] + 4;
	xl_ret(c, new_table(cb_flags(a), cb_flags(a + 24)));
}

void xl_sh_NSCreateMapTableWithZone(XLCPU *c) { xl_sh_NSCreateMapTable(c); }

void xl_sh_NSFreeMapTable(XLCPU *c)
{
	[T(A(0)) release];
	xl_ret(c, 0);
}

void xl_sh_NSResetMapTable(XLCPU *c)
{
	[T(A(0)) reset];
	xl_ret(c, 0);
}

void xl_sh_NSMapGet(XLCPU *c)
{
	XLGEntry *e = [T(A(0)) entry:A(1)];
	xl_ret(c, e ? e->value : 0);
}

void xl_sh_NSMapMember(XLCPU *c)
{
	XLGEntry *e = [T(A(0)) entry:A(1)];
	if (e) {
		if (A(2))
			*(uint32_t *)GP(A(2)) = e->key;
		if (A(3))
			*(uint32_t *)GP(A(3)) = e->value;
	}
	xl_ret(c, e ? 1 : 0);
}

void xl_sh_NSMapInsert(XLCPU *c)
{
	[T(A(0)) put:A(1) value:A(2)];
	xl_ret(c, 0);
}

void xl_sh_NSMapInsertKnownAbsent(XLCPU *c) { xl_sh_NSMapInsert(c); }

// returns the key already present, or NULL after inserting
void xl_sh_NSMapInsertIfAbsent(XLCPU *c)
{
	XLGTable *t = T(A(0));
	XLGEntry *e = [t entry:A(1)];
	if (e) {
		xl_ret(c, e->key);
		return;
	}
	[t put:A(1) value:A(2)];
	xl_ret(c, 0);
}

void xl_sh_NSMapRemove(XLCPU *c)
{
	[T(A(0)) remove:A(1)];
	xl_ret(c, 0);
}

void xl_sh_NSCountMapTable(XLCPU *c) { xl_ret(c, (uint32_t)[T(A(0))->map count]); }

static NSArray *entries(XLGTable *t)
{
	return t ? [[t->map objectEnumerator] allObjects] : @[];
}

void xl_sh_NSAllMapTableValues(XLCPU *c)
{
	XLGTable *t = T(A(0));
	NSMutableArray *a = [NSMutableArray array];
	for (XLGEntry *e in entries(t))
		if (e->value && (t->vflags & XL_CB_OBJECT))
			[a addObject:(id)xl_p(e->value)];
	xl_ret(c, xl_hobj(a));
}

void xl_sh_NSAllMapTableKeys(XLCPU *c)
{
	XLGTable *t = T(A(0));
	NSMutableArray *a = [NSMutableArray array];
	for (XLGEntry *e in entries(t))
		if (e->key && (t->kflags & XL_CB_OBJECT))
			[a addObject:(id)xl_p(e->key)];
	xl_ret(c, xl_hobj(a));
}

// NSMapEnumerator (3 words, returned through a hidden pointer the callee pops):
// table, index, snapshot of the entries
void xl_sh_NSEnumerateMapTable(XLCPU *c)
{
	uint32_t sret = A(0);
	XLGTable *t = T(A(1));
	NSArray *snap = [entries(t) retain];
	uint32_t *e = (uint32_t *)GP(sret);
	e[0] = A(1);
	e[1] = 0;
	e[2] = xl_h(snap);
	c->r[EAX] = sret;
	c->r[ESP] += 8;
}

void xl_sh_NSNextMapEnumeratorPair(XLCPU *c)
{
	uint32_t *e = (uint32_t *)GP(A(0));
	NSArray *snap = e[2] ? (NSArray *)xl_p(e[2]) : nil;
	if (!snap || e[1] >= [snap count]) {
		xl_ret(c, 0);
		return;
	}
	XLGEntry *en = snap[e[1]++];
	if (A(1))
		*(uint32_t *)GP(A(1)) = en->key;
	if (A(2))
		*(uint32_t *)GP(A(2)) = en->value;
	xl_ret(c, 1);
}

void xl_sh_NSEndMapTableEnumeration(XLCPU *c)
{
	uint32_t *e = (uint32_t *)GP(A(0));
	if (e[2])
		[(NSArray *)xl_p(e[2]) release];
	e[2] = 0;
	xl_ret(c, 0);
}

// ---- hash tables: maps whose values are their keys ------------------------------------------
// NSCreateHashTable(NSHashTableCallBacks (5 words), capacity)
void xl_sh_NSCreateHashTable(XLCPU *c)
{
	uint32_t f = cb_flags(c->r[ESP] + 4);
	xl_ret(c, new_table(f, f & ~(XL_CB_RETAIN | XL_CB_FREE)));
}

void xl_sh_NSCreateHashTableWithZone(XLCPU *c) { xl_sh_NSCreateHashTable(c); }

void xl_sh_NSFreeHashTable(XLCPU *c) { xl_sh_NSFreeMapTable(c); }
void xl_sh_NSResetHashTable(XLCPU *c) { xl_sh_NSResetMapTable(c); }

void xl_sh_NSHashGet(XLCPU *c)
{
	XLGEntry *e = [T(A(0)) entry:A(1)];
	xl_ret(c, e ? e->key : 0);
}

void xl_sh_NSHashInsert(XLCPU *c)
{
	[T(A(0)) put:A(1) value:A(1)];
	xl_ret(c, 0);
}

void xl_sh_NSHashInsertKnownAbsent(XLCPU *c) { xl_sh_NSHashInsert(c); }

void xl_sh_NSHashInsertIfAbsent(XLCPU *c)
{
	XLGTable *t = T(A(0));
	XLGEntry *e = [t entry:A(1)];
	if (e) {
		xl_ret(c, e->key);
		return;
	}
	[t put:A(1) value:A(1)];
	xl_ret(c, 0);
}

void xl_sh_NSHashRemove(XLCPU *c) { xl_sh_NSMapRemove(c); }
void xl_sh_NSCountHashTable(XLCPU *c) { xl_sh_NSCountMapTable(c); }

// NSHashEnumerator is 3 words as well, returned the same way
void xl_sh_NSEnumerateHashTable(XLCPU *c) { xl_sh_NSEnumerateMapTable(c); }

void xl_sh_NSNextHashEnumeratorItem(XLCPU *c)
{
	uint32_t *e = (uint32_t *)GP(A(0));
	NSArray *snap = e[2] ? (NSArray *)xl_p(e[2]) : nil;
	if (!snap || e[1] >= [snap count]) {
		xl_ret(c, 0);
		return;
	}
	XLGEntry *en = snap[e[1]++];
	xl_ret(c, en->key);
}

void xl_sh_NSEndHashTableEnumeration(XLCPU *c) { xl_sh_NSEndMapTableEnumeration(c); }
