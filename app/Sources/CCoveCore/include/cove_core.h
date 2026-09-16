#ifndef COVE_CORE_H
#define COVE_CORE_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

void cove_init(void);
char* cove_stage_file(const char* path);
char* cove_get_staged_files(void);
bool cove_remove_item(const char* id);
void cove_clear_all(void);
void cove_free_string(char* ptr);

#ifdef __cplusplus
}
#endif

#endif /* COVE_CORE_H */
