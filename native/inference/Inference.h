#ifndef GRAMMARNAZI_INFERENCE_H
#define GRAMMARNAZI_INFERENCE_H
#include <stdbool.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct gn_session gn_session;
typedef bool (*gn_cancel_check)(void * user);
// Sessions are confined to one serial worker. Cancellation callbacks must be thread-safe.
gn_session * gn_session_create(void);
void gn_session_destroy(gn_session * session);
// Returns 0 on success, 1 on failure, 2 on cancellation. Output and error use gn_string_free.
int gn_session_run(gn_session * session, const char * model_path, const char * request,
                   gn_cancel_check cancelled, void * user, char ** output, char ** error);
size_t gn_session_load_count(const gn_session * session);
void gn_string_free(char * string);
#ifdef __cplusplus
}
#endif
#endif
