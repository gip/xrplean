#ifndef LX_NUDB_STORE_H
#define LX_NUDB_STORE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
int lx_nudb_available(void);
const char *lx_nudb_error(void);
/* Generation names are validated, private children of DB.nodes. */
void *lx_nudb_open(const char *database, const char *generation, int create);
int lx_nudb_new_generation(char out[35]);
int lx_nudb_get(void *handle, const void *hash, unsigned char **data, size_t *size);
int lx_nudb_put(void *handle, const void *hash, const void *data, size_t size, uint64_t budget);
/* Insert without comparing an existing value: 1=new, 2=existing, 0=error.
   Caller must check catalog visibility or validate orphan bytes before adoption. */
int lx_nudb_put_new(void *handle, const void *hash, const void *data, size_t size, uint64_t budget);
int lx_nudb_flush(void *handle, uint64_t budget);
int lx_nudb_bytes(void *handle, uint64_t *bytes);
void lx_nudb_release(void *handle);
/* Retired generations remain alive while an existing reader holds a handle. */
void lx_nudb_retire(void *handle);
int lx_nudb_cleanup(const char *database, const char *active);
int lx_nudb_clone(void *handle, const char *target);
#ifdef __cplusplus
}
#endif
#endif
