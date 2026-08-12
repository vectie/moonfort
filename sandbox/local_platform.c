#include <moonbit.h>

#include <stdint.h>

/* Keep platform selection out of environment variables and PATH lookups. */
MOONBIT_FFI_EXPORT
int32_t moonfort_local_os_platform(void) {
#if defined(__APPLE__)
  return 1;
#elif defined(__linux__)
  return 2;
#else
  return 0;
#endif
}
