#ifndef PHP_JAVASCRIPT_OBFUSCATOR_H
#define PHP_JAVASCRIPT_OBFUSCATOR_H

extern zend_module_entry javascript_obfuscator_module_entry;
#define phpext_javascript_obfuscator_ptr &javascript_obfuscator_module_entry

#define PHP_JAVASCRIPT_OBFUSCATOR_VERSION "1.0.0"

PHP_FUNCTION(javascript_obfuscator_obfuscate);

#endif
