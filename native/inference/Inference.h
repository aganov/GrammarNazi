#ifndef GRAMMARNAZI_INFERENCE_H
#define GRAMMARNAZI_INFERENCE_H
#include <stdbool.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct gn_session gn_session;
typedef bool (*gn_cancel_check)(void * user);
typedef enum { GN_PHASE_LOADING = 0, GN_PHASE_WORKING = 1 } gn_phase;
typedef void (*gn_phase_callback)(gn_phase phase, void * user);
// Sessions are confined to one serial worker. Cancellation callbacks must be thread-safe.
gn_session * gn_session_create(void);
void gn_session_destroy(gn_session * session);
// Returns 0 on success, 1 on failure, 2 on cancellation. Output and error use gn_string_free.
int gn_session_run(gn_session * session, const char * model_path, const char * request,
                   gn_cancel_check cancelled, gn_phase_callback phase, void * user, char ** output, char ** error);
bool gn_session_is_loaded(const gn_session * session);
size_t gn_session_load_count(const gn_session * session);
void gn_string_free(char * string);
#ifdef __cplusplus
}
#endif
#endif
