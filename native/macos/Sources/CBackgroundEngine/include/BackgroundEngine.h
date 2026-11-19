#ifndef FILLR_BACKGROUND_ENGINE_H
#define FILLR_BACKGROUND_ENGINE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct fillr_background_context fillr_background_context;
typedef void (*fillr_background_progress)(void *user, int frames, int total_frames);

// A context owns cancellation for one synchronous job. Run this call on a
// worker queue. cancel() is thread-safe; destroy only after render returns.
// Distinct contexts may run concurrently. Cancellation remains set thereafter.
fillr_background_context *fillr_background_create(void);
void fillr_background_cancel(fillr_background_context *context);
void fillr_background_destroy(fillr_background_context *context);

// JSON is UTF-8 and copied before work begins. Return values are allocated JSON
// objects, including on failure; release with fillr_background_free_string().
// A normal render requires 17,982 frames. Short jobs require benchmark=true.
// The output appears only after a complete decode verifies the rendered file.
char *fillr_background_render(fillr_background_context *context,
                             const char *job_json,
                             const char *output_path,
                             const char *settings_json,
                             fillr_background_progress progress,
                             void *user);
char *fillr_background_probe(const char *path);
char *fillr_background_test_job(const char *directory, int frames);
// Converts completed MPEG-2 downloads to ProRes 422 LT MOV with every audio
// track preserved as 24-bit PCM. The caller supplies a new provisional path;
// success is returned only after full decode verification. Source is read-only.
// Cancellation and returned-string ownership match the background render API.
char *fillr_download_transcode(fillr_background_context *context,
                              const char *source_path,
                              const char *output_path);
void fillr_background_free_string(char *string);

#ifdef __cplusplus
}
#endif
#endif
