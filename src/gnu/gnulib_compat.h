/* gnulib_compat.h - Compatibility shims for gnulib functions on macOS */
#ifndef GNULIB_COMPAT_H
#define GNULIB_COMPAT_H

#include <stddef.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>
#include <locale.h>
#include <limits.h>
#include <wchar.h>

/* reallocarray - realloc with overflow checking */
#ifndef HAVE_REALLOCARRAY
static inline void *reallocarray(void *ptr, size_t nmemb, size_t size) {
    if (nmemb && size > SIZE_MAX / nmemb) {
        errno = ENOMEM;
        return NULL;
    }
    return realloc(ptr, nmemb * size);
}
#endif

/* rawmemchr - like memchr but assumes the byte exists (no length limit) */
#ifndef HAVE_RAWMEMCHR
static inline void *rawmemchr(const void *s, int c) {
    const unsigned char *p = (const unsigned char *)s;
    while (*p != (unsigned char)c)
        p++;
    return (void *)p;
}
#endif

/* memrchr - reverse memchr, find last occurrence */
#ifndef HAVE_MEMRCHR
static inline void *memrchr(const void *s, int c, size_t n) {
    const unsigned char *p = (const unsigned char *)s + n;
    while (n--) {
        if (*--p == (unsigned char)c)
            return (void *)p;
    }
    return NULL;
}
#endif

/* mbslen - length of multibyte string in characters */
#ifndef HAVE_MBSLEN
static inline size_t mbslen(const char *s) {
    size_t len = 0;
    mbstate_t state;
    memset(&state, 0, sizeof(state));

    while (*s) {
        size_t bytes = mbrlen(s, MB_LEN_MAX, &state);
        if (bytes == (size_t)-1 || bytes == (size_t)-2) {
            /* Invalid or incomplete - count as one byte */
            s++;
        } else if (bytes == 0) {
            break;
        } else {
            s += bytes;
        }
        len++;
    }
    return len;
}
#endif

/* setlocale_null_r - thread-safe locale query */
#ifndef HAVE_SETLOCALE_NULL_R
static inline int setlocale_null_r(int category, char *buf, size_t bufsize) {
    const char *locale = setlocale(category, NULL);
    if (!locale) {
        if (bufsize > 0)
            buf[0] = '\0';
        return EINVAL;
    }
    size_t len = strlen(locale);
    if (len >= bufsize) {
        if (bufsize > 0) {
            memcpy(buf, locale, bufsize - 1);
            buf[bufsize - 1] = '\0';
        }
        return ERANGE;
    }
    memcpy(buf, locale, len + 1);
    return 0;
}
#endif

/* Attribute macros that might be missing */
#ifndef _GL_ATTRIBUTE_FORMAT_PRINTF_STANDARD
#define _GL_ATTRIBUTE_FORMAT_PRINTF_STANDARD(a, b) __attribute__((__format__(__printf__, a, b)))
#endif

#ifndef _GL_ARG_NONNULL
#define _GL_ARG_NONNULL(args)
#endif

#ifndef _GL_ATTRIBUTE_FORMAT
#define _GL_ATTRIBUTE_FORMAT(spec) __attribute__((__format__ spec))
#endif

#ifndef _GL_ATTRIBUTE_PURE
#define _GL_ATTRIBUTE_PURE __attribute__((__pure__))
#endif

#ifndef _GL_ATTRIBUTE_CONST
#define _GL_ATTRIBUTE_CONST __attribute__((__const__))
#endif

#ifndef _GL_ATTRIBUTE_MALLOC
#define _GL_ATTRIBUTE_MALLOC __attribute__((__malloc__))
#endif

#ifndef _GL_ATTRIBUTE_RETURNS_NONNULL
#define _GL_ATTRIBUTE_RETURNS_NONNULL __attribute__((__returns_nonnull__))
#endif

#ifndef _GL_ATTRIBUTE_ALLOC_SIZE
#define _GL_ATTRIBUTE_ALLOC_SIZE(args)
#endif

#ifndef _GL_ATTRIBUTE_DEALLOC
#define _GL_ATTRIBUTE_DEALLOC(f, i)
#endif

#ifndef _GL_ATTRIBUTE_NODISCARD
#define _GL_ATTRIBUTE_NODISCARD
#endif

/* static_assert compatibility for older C standards */
#ifndef static_assert
#define static_assert _Static_assert
#endif

#endif /* GNULIB_COMPAT_H */
