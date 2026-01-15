/* error.h - Generated from error.in.h for GNU grep wrapper */
#ifndef _GL_ERROR_H
#define _GL_ERROR_H

#if !_GL_CONFIG_H_INCLUDED
 #error "Please include config.h first."
#endif

#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Print a message with 'fprintf (stderr, FORMAT, ...)';
   if ERRNUM is nonzero, follow it with ": " and strerror (ERRNUM).
   If STATUS is nonzero, terminate the program with 'exit (STATUS)'.  */
extern void error (int __status, int __errnum, const char *__format, ...)
    __attribute__ ((__format__ (__printf__, 3, 4)));

/* Likewise.  If FILENAME is non-NULL, include FILENAME:LINENO: in the
   message.  */
extern void error_at_line (int __status, int __errnum, const char *__filename,
                           unsigned int __lineno, const char *__format, ...)
    __attribute__ ((__format__ (__printf__, 5, 6)));

/* If NULL, error will flush stdout, then print on stderr the program
   name, a colon and a space.  Otherwise, error will call this
   function without parameters instead.  */
extern void (*error_print_progname) (void);

/* This variable is incremented each time 'error' is called.  */
extern unsigned int error_message_count;

/* Sometimes we want to have at most one error per line.  This
   variable controls whether this mode is selected or not.  */
extern int error_one_per_line;

#ifdef __cplusplus
}
#endif

#endif /* _GL_ERROR_H */
