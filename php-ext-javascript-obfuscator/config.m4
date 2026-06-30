PHP_ARG_ENABLE([javascript_obfuscator],,
  [Whether to enable javascript-obfuscator support],
  [no])

if test "$PHP_JAVASCRIPT_OBFUSCATOR" != "no"; then
  AC_DEFINE(HAVE_JAVASCRIPT_OBFUSCATOR, 1, [Have javascript-obfuscator support])
  PHP_NEW_EXTENSION(javascript_obfuscator, javascript_obfuscator.c, $ext_shared)
fi
