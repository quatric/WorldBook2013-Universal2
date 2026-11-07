// A map from 32-bit guest values (handles, tokens) to host pointers.
#ifndef HMAP_H
#define HMAP_H
#include <stdint.h>
#include <stdlib.h>

typedef struct { uint32_t *k; void **v; uint32_t cap, n; } HMap;

static inline uint32_t hm_hash(uint32_t k) { k ^= k >> 16; k *= 0x45d9f3b; k ^= k >> 16; return k; }

static inline void *hm_get(HMap *m, uint32_t k)
{
	if (!m->cap || !k)
		return NULL;
	for (uint32_t i = hm_hash(k) & (m->cap - 1);; i = (i + 1) & (m->cap - 1)) {
		if (m->k[i] == k)
			return m->v[i];
		if (!m->k[i])
			return NULL;
	}
}

static inline void hm_put(HMap *m, uint32_t k, void *v);

static inline void hm_grow(HMap *m)
{
	HMap o = *m;
	m->cap = o.cap ? o.cap * 2 : 64;
	m->k = calloc(m->cap, 4);
	m->v = calloc(m->cap, sizeof(void *));
	m->n = 0;
	for (uint32_t i = 0; i < o.cap; i++)
		if (o.k[i] && o.k[i] != 0xffffffffu)
			hm_put(m, o.k[i], o.v[i]);
	free(o.k);
	free(o.v);
}

static inline void hm_put(HMap *m, uint32_t k, void *v)
{
	if ((m->n + 1) * 2 > m->cap)
		hm_grow(m);
	uint32_t i = hm_hash(k) & (m->cap - 1);
	uint32_t tomb = 0xffffffffu;
	for (;; i = (i + 1) & (m->cap - 1)) {
		if (m->k[i] == k) {
			m->v[i] = v;
			return;
		}
		if (m->k[i] == 0xffffffffu && tomb == 0xffffffffu)
			tomb = i;
		if (!m->k[i])
			break;
	}
	if (tomb != 0xffffffffu)
		i = tomb;
	m->k[i] = k;
	m->v[i] = v;
	m->n++;
}

static inline void hm_del(HMap *m, uint32_t k)
{
	if (!m->cap || !k)
		return;
	for (uint32_t i = hm_hash(k) & (m->cap - 1);; i = (i + 1) & (m->cap - 1)) {
		if (m->k[i] == k) {
			m->k[i] = 0xffffffffu;
			m->v[i] = NULL;
			return;
		}
		if (!m->k[i])
			return;
	}
}

#endif
