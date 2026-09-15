// Build the library first: `make libstorage` writes generated/storage.h.
#pragma once
#ifndef __libstorage__
#define __libstorage__

#include <stddef.h>
#include <stdint.h>

#include "generated/storage.h"

// Aliases of the generated NIMFFI_RET_* codes, so short-name callers keep compiling.
#ifndef RET_OK
#define RET_OK NIMFFI_RET_OK
#endif
#ifndef RET_ERR
#define RET_ERR NIMFFI_RET_ERROR
#endif
#ifndef RET_MISSING_CALLBACK
#define RET_MISSING_CALLBACK NIMFFI_RET_MISSING_CALLBACK
#endif

#ifdef __cplusplus
extern "C"
{
#endif

  // No ctx, no callback. The buffer is thread-local and lives until the next call.
  const char *storage_version(void);
  const char *storage_revision(void);

#ifdef __cplusplus
}
#endif

#endif /* __libstorage__ */
