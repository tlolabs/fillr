#ifndef FILLR_H
#define FILLR_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
uint32_t fillr_api_version(void);
void *fillr_create(const char *folder, const char *ffprobe);
char *fillr_snapshot(void *engine);
char *fillr_build(void *engine);
void fillr_refresh(void *engine);
char *fillr_last_error(void);
void fillr_free_string(char *value);
void fillr_destroy(void *engine);
#ifdef __cplusplus
}
#endif
#endif
