#ifndef FILLR_H
#define FILLR_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/**
 * Returns the FILLR C ABI version (currently 1).
 */
uint32_t fillr_api_version(void);

/**
 * Validates a JSON-encoded MediaPolicy string without requiring an active engine or folder.
 * Returns 1 if valid, 0 on error (check fillr_last_error()).
 * Pointer parameters must be valid NUL-terminated UTF-8 strings.
 */
uint8_t fillr_validate_media_policy(const char *policy_json);

/**
 * Validates a JSON-encoded SortSettings string without requiring an active engine or folder.
 * Returns 1 if valid, 0 on error (check fillr_last_error()).
 * Pointer parameters must be valid NUL-terminated UTF-8 strings.
 */
uint8_t fillr_validate_sort_settings(const char *settings_json);

/**
 * Creates an Engine instance for the specified download folder and ffprobe path.
 * Returns an opaque engine pointer on success, or NULL on failure.
 * The caller owns the returned engine and must release it using fillr_destroy().
 */
void *fillr_create(const char *folder, const char *ffprobe);

void *fillr_create_configured(const char *folder, const char *ffprobe, const char *policy_json);
void *fillr_create_configured_owned(const char *folder, const char *policy_json);

/**
 * Creates an Engine instance with bundled ffprobe, initial policy, and initial sort settings.
 * Returns an opaque pointer owned by the caller, or NULL on error.
 */
void *fillr_create_with_settings_owned(const char *folder, const char *policy_json, const char *settings_json);

/**
 * Transactionally updates both media policy and sort settings under a single engine lock.
 * If either fails validation, neither is applied.
 * Returns 1 on success, 0 on failure.
 */
uint8_t fillr_set_configuration(void *engine, const char *policy_json, const char *settings_json);

uint8_t fillr_set_media_policy(void *engine, const char *policy_json);
uint8_t fillr_set_sort_settings(void *engine, const char *settings_json);

/**
 * Returns a JSON snapshot of the current engine state.
 * The caller takes ownership of the returned C string and MUST free it using fillr_free_string() or fillr_string_free().
 */
char *fillr_snapshot(void *engine);

/**
 * Executes the export build operation.
 * The caller takes ownership of the returned C string and MUST free it using fillr_free_string() or fillr_string_free().
 */
char *fillr_build(void *engine);

/**
 * Wakes up the folder watcher and triggers an immediate scan.
 */
void fillr_refresh(void *engine);

/**
 * Returns the thread-local last error message as a newly allocated C string.
 * The caller takes ownership of the returned string and MUST free it using fillr_free_string() or fillr_string_free().
 */
char *fillr_last_error(void);

/**
 * Frees a C string allocated by the Rust runtime.
 * Passing NULL is a safe no-op.
 */
void fillr_free_string(char *value);

/**
 * Alias for fillr_free_string.
 */
void fillr_string_free(char *value);

/**
 * Destroys an Engine instance and stops its background worker thread.
 * Passing NULL is a safe no-op. Must not be called concurrently with other calls on the same handle.
 */
void fillr_destroy(void *engine);

#ifdef __cplusplus
}
#endif
#endif
