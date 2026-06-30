#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include "php.h"
#include "php_javascript_obfuscator.h"
#include "ext/standard/php_string.h"
#include "Zend/zend_exceptions.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef JSO_BIN
#define JSO_BIN "/usr/local/bin/javascript-obfuscator"
#endif

ZEND_BEGIN_ARG_INFO_EX(arginfo_javascript_obfuscator_obfuscate, 0, 0, 1)
	ZEND_ARG_INFO(0, code)
ZEND_END_ARG_INFO()

static char *jso_read_file(const char *path, size_t *len)
{
	FILE *fp;
	char *buf;
	long fsize;

	fp = fopen(path, "rb");
	if (!fp) {
		return NULL;
	}

	if (fseek(fp, 0, SEEK_END) != 0) {
		fclose(fp);
		return NULL;
	}

	fsize = ftell(fp);
	if (fsize < 0) {
		fclose(fp);
		return NULL;
	}

	rewind(fp);
	buf = emalloc((size_t)fsize + 1);
	if (fread(buf, 1, (size_t)fsize, fp) != (size_t)fsize) {
		efree(buf);
		fclose(fp);
		return NULL;
	}
	buf[fsize] = '\0';
	fclose(fp);

	if (len) {
		*len = (size_t)fsize;
	}
	return buf;
}

static int jso_write_file(const char *path, const char *data, size_t len)
{
	FILE *fp = fopen(path, "wb");
	if (!fp) {
		return -1;
	}
	if (fwrite(data, 1, len, fp) != len) {
		fclose(fp);
		return -1;
	}
	fclose(fp);
	return 0;
}

static int jso_run_cli(const char *bin, const char *in_path, const char *out_path)
{
	char cmd[4096];
	int status;

	snprintf(cmd, sizeof(cmd), "%s %s -o %s 2>/dev/null", bin, in_path, out_path);
	status = system(cmd);
	return status == 0 ? 0 : -1;
}

PHP_FUNCTION(javascript_obfuscator_obfuscate)
{
	char *code;
	size_t code_len;
	char in_tpl[] = "/tmp/jso_in_XXXXXX";
	char out_tpl[] = "/tmp/jso_out_XXXXXX";
	int in_fd = -1, out_fd = -1;
	char *in_path = NULL, *out_path = NULL;
	char *result = NULL;
	size_t result_len = 0;

	ZEND_PARSE_PARAMETERS_START(1, 1)
		Z_PARAM_STRING(code, code_len)
	ZEND_PARSE_PARAMETERS_END();

	if (access(JSO_BIN, X_OK) != 0) {
		zend_throw_exception_ex(zend_ce_exception, 0,
			"javascript-obfuscator binary not found or not executable: %s", JSO_BIN);
		RETURN_FALSE;
	}

	in_fd = mkstemp(in_tpl);
	if (in_fd < 0) {
		zend_throw_exception(zend_ce_exception, "failed to create temp input file", 0);
		RETURN_FALSE;
	}
	close(in_fd);
	in_path = estrdup(in_tpl);

	out_fd = mkstemp(out_tpl);
	if (out_fd < 0) {
		unlink(in_path);
		efree(in_path);
		zend_throw_exception(zend_ce_exception, "failed to create temp output file", 0);
		RETURN_FALSE;
	}
	close(out_fd);
	out_path = estrdup(out_tpl);

	if (jso_write_file(in_path, code, code_len) != 0) {
		unlink(in_path);
		unlink(out_path);
		efree(in_path);
		efree(out_path);
		zend_throw_exception(zend_ce_exception, "failed to write temp input file", 0);
		RETURN_FALSE;
	}

	if (jso_run_cli(JSO_BIN, in_path, out_path) != 0) {
		unlink(in_path);
		unlink(out_path);
		efree(in_path);
		efree(out_path);
		zend_throw_exception(zend_ce_exception, "javascript-obfuscator CLI failed", 0);
		RETURN_FALSE;
	}

	result = jso_read_file(out_path, &result_len);
	unlink(in_path);
	unlink(out_path);
	efree(in_path);
	efree(out_path);

	if (!result) {
		zend_throw_exception(zend_ce_exception, "failed to read obfuscated output", 0);
		RETURN_FALSE;
	}

	RETVAL_STRINGL(result, result_len);
	efree(result);
}

static const zend_function_entry javascript_obfuscator_functions[] = {
	PHP_FE(javascript_obfuscator_obfuscate, arginfo_javascript_obfuscator_obfuscate)
	PHP_FE_END
};

zend_module_entry javascript_obfuscator_module_entry = {
	STANDARD_MODULE_HEADER,
	"javascript_obfuscator",
	javascript_obfuscator_functions,
	NULL,
	NULL,
	NULL,
	NULL,
	PHP_MINFO(javascript_obfuscator),
	PHP_JAVASCRIPT_OBFUSCATOR_VERSION,
	STANDARD_MODULE_PROPERTIES
};

#ifdef COMPILE_DL_JAVASCRIPT_OBFUSCATOR
ZEND_GET_MODULE(javascript_obfuscator)
#endif

PHP_MINFO_FUNCTION(javascript_obfuscator)
{
	php_info_print_table_start();
	php_info_print_table_header(2, "javascript-obfuscator support", "enabled");
	php_info_print_table_row(2, "Version", PHP_JAVASCRIPT_OBFUSCATOR_VERSION);
	php_info_print_table_row(2, "CLI binary", JSO_BIN);
	php_info_print_table_end();
}
