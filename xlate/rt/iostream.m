// std::ifstream / std::istream of the GCC 4.0 libstdc++ the Atlas was built with
// (gone from macOS), over host FILE streams.
//
// The guest keeps the stream object in its own memory and only calls the
// constructor, the destructor, extraction functions and basic_ios::operator
// void*. Translated inline code reaches the basic_ios part through the vtable's
// virtual base offset (vptr[-3]), so the constructor writes a vptr whose offset
// puts basic_ios 8 bytes into the object, and the state word is mirrored where
// inline good()/eof()/fail() read it (ios_base::_M_streambuf_state, +20).
// istream::_M_gcount (+4) is kept for gcount().
#import <Foundation/Foundation.h>
#include "rt.h"

#define A(i) xl_arg(c, i)

enum { BADBIT = 1, EOFBIT = 2, FAILBIT = 4 };
enum { IOS_OFF = 8, STATE_OFF = 20 };

typedef struct {
	FILE *f;
	uint32_t self;
	uint32_t state;
} GStream;

static XLMap streams;   // istream address -> GStream *
static uint32_t vtbl;   // guest vtable stub: [vbase offset][offset to top][typeinfo] vptr ->

static GStream *S(uint32_t self)
{
	GStream *s = (GStream *)xl_map_get(&streams, self);
	if (!s)
		xl_log("istream %08x not opened through the translated ifstream", self);
	return s;
}

static void set_state(GStream *s, uint32_t bits)
{
	s->state |= bits;
	*(uint32_t *)GP(s->self + IOS_OFF + STATE_OFF) = s->state;
}

static void gcount(GStream *s, uint32_t n) { *(uint32_t *)GP(s->self + 4) = n; }

// basic_ifstream(const char *path, ios_base::openmode)
static void sh_ifstream_ctor(XLCPU *c)
{
	uint32_t self = A(0);
	const char *path = A(1) ? (const char *)GP(A(1)) : "";
	if (!vtbl) {
		vtbl = xl_calloc(16);
		*(uint32_t *)GP(vtbl) = IOS_OFF;
	}
	memset(GP(self), 0, IOS_OFF + 64);
	*(uint32_t *)GP(self) = vtbl + 12;
	GStream *s = calloc(1, sizeof *s);
	s->self = self;
	s->f = fopen(path, "rb");
	xl_map_put(&streams, self, (uint64_t)s);
	if (!s->f) {
		if (xl_verbose > 0)
			xl_log("ifstream: cannot open %s", path);
		set_state(s, FAILBIT);
	}
	xl_ret(c, 0);
}

static void sh_ifstream_dtor(XLCPU *c)
{
	uint32_t self = A(0);
	GStream *s = (GStream *)xl_map_get(&streams, self);
	if (s) {
		if (s->f)
			fclose(s->f);
		xl_map_del(&streams, self);
		free(s);
	}
	xl_ret(c, 0);
}

// basic_ios::operator void*(): null once failbit or badbit is set
static void sh_ios_void(XLCPU *c)
{
	uint32_t ios = A(0);
	GStream *s = S(ios - IOS_OFF);
	xl_ret(c, s && !(s->state & (FAILBIT | BADBIT)) ? ios : 0);
}

static int next(GStream *s)
{
	int ch = s->f ? getc(s->f) : EOF;
	if (ch == EOF)
		set_state(s, EOFBIT);
	return ch;
}

// istream::ignore(n, EOF)
static void ignore_n(GStream *s, int n)
{
	uint32_t k = 0;
	if (!(s->state & (FAILBIT | BADBIT | EOFBIT)))
		while (n-- > 0 && next(s) != EOF)
			k++;
	gcount(s, k);
}

static void sh_ignore0(XLCPU *c)
{
	GStream *s = S(A(0));
	if (s)
		ignore_n(s, 1);
	xl_ret(c, A(0));
}

static void sh_ignore1(XLCPU *c)
{
	GStream *s = S(A(0));
	if (s)
		ignore_n(s, (int)A(1));
	xl_ret(c, A(0));
}

// istream::getline(char *buf, n, delim): up to n - 1 characters; the delimiter is
// consumed, not stored; failbit if nothing was extracted or the buffer filled first
static void getline_d(XLCPU *c, int delim)
{
	GStream *s = S(A(0));
	uint32_t buf = A(1);
	int n = (int)A(2);
	if (!s) {
		xl_ret(c, A(0));
		return;
	}
	uint32_t k = 0, stored = 0;
	int found = 0;
	if (s->state & (FAILBIT | BADBIT | EOFBIT))
		set_state(s, FAILBIT);
	else {
		while (1) {
			if ((int)stored >= n - 1) {
				int ch = s->f ? getc(s->f) : EOF;
				if (ch == delim) {
					found = 1;
					k++;
				} else {
					if (ch != EOF)
						ungetc(ch, s->f);
					set_state(s, FAILBIT);
				}
				break;
			}
			int ch = next(s);
			if (ch == EOF)
				break;
			k++;
			if (ch == delim) {
				found = 1;
				break;
			}
			if (buf)
				*(char *)GP(buf + stored) = (char)ch;
			stored++;
		}
		if (!k)
			set_state(s, FAILBIT);
	}
	if (buf && n > 0)
		*(char *)GP(buf + stored) = 0;
	(void)found;
	gcount(s, k);
	xl_ret(c, A(0));
}

static void sh_getline(XLCPU *c) { getline_d(c, '\n'); }
static void sh_getline_delim(XLCPU *c) { getline_d(c, (char)A(3)); }

// the characters of one number, after leading white space
static int number_text(GStream *s, char *out, int max, int fl)
{
	int ch;
	if (s->state & (FAILBIT | BADBIT | EOFBIT)) {
		set_state(s, FAILBIT);
		return 0;
	}
	do
		ch = next(s);
	while (ch != EOF && isspace(ch));
	int n = 0;
	while (ch != EOF && n < max - 1 &&
		(isdigit(ch) || (n == 0 && (ch == '-' || ch == '+')) ||
			(fl && (ch == '.' || ch == 'e' || ch == 'E' || ((ch == '-' || ch == '+') && n && (out[n - 1] == 'e' || out[n - 1] == 'E')))))) {
		out[n++] = (char)ch;
		ch = next(s);
	}
	if (ch != EOF)
		ungetc(ch, s->f);
	out[n] = 0;
	if (!n || (n == 1 && (out[0] == '-' || out[0] == '+')))
		set_state(s, FAILBIT);
	return n;
}

static void sh_extract_float(XLCPU *c)
{
	GStream *s = S(A(0));
	char t[64];
	if (s && number_text(s, t, sizeof t, 1) && !(s->state & FAILBIT)) {
		float v = strtof(t, NULL);
		memcpy(GP(A(1)), &v, 4);
	}
	xl_ret(c, A(0));
}

static void sh_extract_long(XLCPU *c)
{
	GStream *s = S(A(0));
	char t[64];
	if (s && number_text(s, t, sizeof t, 0) && !(s->state & FAILBIT))
		*(int32_t *)GP(A(1)) = (int32_t)strtol(t, NULL, 10);
	xl_ret(c, A(0));
}

static void sh_extract_ulong(XLCPU *c)
{
	GStream *s = S(A(0));
	char t[64];
	if (s && number_text(s, t, sizeof t, 0) && !(s->state & FAILBIT))
		*(uint32_t *)GP(A(1)) = (uint32_t)strtoul(t, NULL, 10);
	xl_ret(c, A(0));
}

// output: the Atlas only writes diagnostics; they go to stderr
static void sh_put_float(XLCPU *c)
{
	uint32_t v = A(1);
	float f;
	memcpy(&f, &v, 4);
	fprintf(stderr, "%g", f);
	xl_ret(c, A(0));
}

static void sh_put_long(XLCPU *c)
{
	fprintf(stderr, "%ld", (long)(int32_t)A(1));
	xl_ret(c, A(0));
}

static void sh_put_str(XLCPU *c)
{
	if (A(1))
		fputs((const char *)GP(A(1)), stderr);
	xl_ret(c, A(0));
}

static void sh_put_char(XLCPU *c)
{
	fputc((char)A(1), stderr);
	xl_ret(c, A(0));
}

static const struct { const char *name; XLShim fn; } ios_shims[] = {
	{"__ZNSt14basic_ifstreamIcSt11char_traitsIcEEC1EPKcSt13_Ios_Openmode", sh_ifstream_ctor},
	{"__ZNSt14basic_ifstreamIcSt11char_traitsIcEEC2EPKcSt13_Ios_Openmode", sh_ifstream_ctor},
	{"__ZNSt14basic_ifstreamIcSt11char_traitsIcEED1Ev", sh_ifstream_dtor},
	{"__ZNSt14basic_ifstreamIcSt11char_traitsIcEED2Ev", sh_ifstream_dtor},
	{"__ZNKSt9basic_iosIcSt11char_traitsIcEEcvPvEv", sh_ios_void},
	{"__ZNSi6ignoreEv", sh_ignore0},
	{"__ZNSi6ignoreEi", sh_ignore1},
	{"__ZNSi7getlineEPci", sh_getline},
	{"__ZNSi7getlineEPcic", sh_getline_delim},
	{"__ZNSirsERf", sh_extract_float},
	{"__ZNSirsERl", sh_extract_long},
	{"__ZNSirsERm", sh_extract_ulong},
	{"__ZNSolsEf", sh_put_float},
	{"__ZNSolsEl", sh_put_long},
	{"__ZStlsISt11char_traitsIcEERSt13basic_ostreamIcT_ES5_PKc", sh_put_str},
	{"__ZStlsISt11char_traitsIcEERSt13basic_ostreamIcT_ES5_c", sh_put_char},
	{NULL, NULL},
};

XLShim xl_find_iostream_shim(const char *name)
{
	for (int i = 0; ios_shims[i].name; i++)
		if (!strcmp(ios_shims[i].name, name))
			return ios_shims[i].fn;
	return NULL;
}
