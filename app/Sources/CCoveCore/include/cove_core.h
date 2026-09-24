#ifndef COVE_CORE_H
#define COVE_CORE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Initializes the shelf persisted under `storage_dir` (NULL = in-memory).
void cove_init(const char* storage_dir);

/// Stages a JSON array of paths as a single stack; returns staged items JSON.
char* cove_stage_files(const char* paths_json);
char* cove_get_staged_files(void);
uint32_t cove_remove_items(const char* ids_json, bool delete_owned);
bool cove_ungroup(const char* group_id);
void cove_clear_all(void);
uint32_t cove_prune_missing(void);
char* cove_inbox_dir(void);

/// Removes items staged more than `max_age_secs` ago; returns the count removed.
uint32_t cove_expire_older_than(uint64_t max_age_secs);
/// Unix time the next item expires (0 when the shelf is empty).
uint64_t cove_next_expiry(uint64_t max_age_secs);

/// Blocking: zips a JSON array of paths into `out_dir`, returns archive path.
char* cove_zip(const char* paths_json, const char* out_dir);

void cove_free_string(char* ptr);

#ifdef __cplusplus
}
#endif

#endif /* COVE_CORE_H */
