/* gnulib_stubs.c - Stub implementations for missing gnulib/grep functions */

#include <config.h>
#include <stddef.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdbool.h>
#include <string.h>

/* fgrep_to_grep_pattern - converts fgrep patterns to grep
 * We don't use this functionality, so just return the pattern as-is */
char *fgrep_to_grep_pattern(size_t *len, char *keys) {
    /* Return keys unchanged */
    return keys;
}

/* usage - called by argmatch on failure
 * We don't want to exit, so just print error and return */
void usage(int status) {
    (void)status;
    fprintf(stderr, "GNU grep wrapper: invalid usage\n");
}

/* gl_dynarray_resize - gnulib dynamic array resize
 * Used by regex internals */
bool gl_dynarray_resize(void *list, size_t size, void *scratch, size_t element) {
    /* This is an internal gnulib function.
     * The actual implementation is complex - for now, return false to signal failure.
     * This may cause regex to fail on very complex patterns. */
    (void)list;
    (void)size;
    (void)scratch;
    (void)element;
    return false;
}

/* rotr_sz - rotate right for size_t
 * Used by hash.c */
size_t rotr_sz(size_t x, int n) {
    int bits = sizeof(size_t) * 8;
    n = n % bits;
    if (n == 0) return x;
    return (x >> n) | (x << (bits - n));
}

/*
 * Override xmalloc family to use simple malloc without complex error handling.
 * This avoids the gnulib error() chain which has initialization issues.
 */

void xalloc_die(void) {
    fprintf(stderr, "grep: memory exhausted\n");
    abort();
}

void *xmalloc(size_t n) {
    void *p = malloc(n);
    if (!p && n != 0) {
        xalloc_die();
    }
    return p;
}

void *xcalloc(size_t n, size_t s) {
    void *p = calloc(n, s);
    if (!p && n != 0 && s != 0) {
        xalloc_die();
    }
    return p;
}

void *xrealloc(void *p, size_t n) {
    void *r = realloc(p, n);
    if (!r && n != 0) {
        xalloc_die();
    }
    return r;
}

void *xnmalloc(size_t n, size_t s) {
    return xmalloc(n * s);
}

void *xzalloc(size_t n) {
    return xcalloc(n, 1);
}

char *xstrdup(const char *s) {
    char *p = strdup(s);
    if (!p) {
        xalloc_die();
    }
    return p;
}

/* Additional xmalloc variants used by gnulib */

void *xmemdup(const void *p, size_t s) {
    void *r = xmalloc(s);
    memcpy(r, p, s);
    return r;
}

char *xcharalloc(size_t n) {
    return (char *)xmalloc(n);
}

/* idx_t variants (idx_t is typically ptrdiff_t or similar) */
void *ximalloc(size_t s) {
    return xmalloc(s);
}

void *xicalloc(size_t n, size_t s) {
    return xcalloc(n, s);
}

void *xirealloc(void *p, size_t s) {
    return xrealloc(p, s);
}

void *xizalloc(size_t s) {
    return xzalloc(s);
}

void *ximemdup0(const void *p, size_t s) {
    char *r = (char *)xmalloc(s + 1);
    memcpy(r, p, s);
    r[s] = '\0';
    return r;
}

/* xpalloc - grow an array, used for dynamic arrays */
void *xpalloc(void *pa, size_t *pn, size_t n_incr_min, ptrdiff_t n_max, size_t s) {
    size_t n = *pn;
    size_t n_incr = n;

    /* Grow by at least n_incr_min */
    if (n_incr < n_incr_min)
        n_incr = n_incr_min;

    /* Don't exceed n_max if specified */
    if (n_max >= 0 && n + n_incr > (size_t)n_max)
        n_incr = (size_t)n_max - n;

    size_t new_n = n + n_incr;
    *pn = new_n;

    return xrealloc(pa, new_n * s);
}

void *xreallocarray(void *p, size_t n, size_t s) {
    /* Check for overflow */
    if (s != 0 && n > (size_t)-1 / s) {
        xalloc_die();
    }
    return xrealloc(p, n * s);
}

void *x2realloc(void *p, size_t *pn) {
    return xpalloc(p, pn, 1, -1, 1);
}

void *x2nrealloc(void *p, size_t *pn, size_t s) {
    return xpalloc(p, pn, 1, -1, s);
}
