#define _POSIX_C_SOURCE 200809L
#include <moonbit.h>
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

/* POSIX specifies the sticky mode bit, but glibc hides S_ISVTX under some
 * strict feature profiles. Keep the native verifier portable without
 * weakening the root-owned sticky-directory check. */
#ifndef S_ISVTX
#define S_ISVTX 01000
#endif

static char *copy_path(moonbit_bytes_t bytes, int32_t length) {
  if (length <= 0 || memchr(bytes, '\0', (size_t)length) != NULL) return NULL;
  char *path = malloc((size_t)length + 1);
  if (path == NULL) return NULL;
  memcpy(path, bytes, (size_t)length);
  path[length] = '\0';
  return path;
}

static int trusted_owner(const struct stat *st, uid_t uid) {
  return st->st_uid == uid || st->st_uid == 0;
}

static int trusted_directory_mode(const struct stat *st, uid_t uid) {
  if (!S_ISDIR(st->st_mode) || !trusted_owner(st, uid)) return 0;
  if ((st->st_mode & (S_IWGRP | S_IWOTH)) == 0) return 1;
  /* Root-owned sticky directories such as /private/tmp do not let another
   * unprivileged user replace an entry owned by the executor. */
  return st->st_uid == 0 && (st->st_mode & S_ISVTX) != 0;
}

static int trusted_parent_chain(char *path, uid_t uid) {
  char *slash = strrchr(path, '/');
  if (slash == NULL) return 0;
  if (slash == path) slash[1] = '\0';
  else *slash = '\0';
  for (;;) {
    struct stat parent;
    if (lstat(path, &parent) != 0 || !trusted_directory_mode(&parent, uid)) {
      return 0;
    }
    if (strcmp(path, "/") == 0) return 1;
    slash = strrchr(path, '/');
    if (slash == NULL) return 0;
    if (slash == path) slash[1] = '\0';
    else *slash = '\0';
  }
}

/*
 * policy 1: protected regular config/grant file
 * policy 2: executor-private directory (0700-equivalent)
 * policy 3: trusted workspace/read directory
 * policy 4: trusted executable
 */
MOONBIT_FFI_EXPORT
int32_t moonfort_secure_path(moonbit_bytes_t bytes, int32_t length, int32_t policy) {
  char *path = copy_path(bytes, length);
  if (path == NULL) return 0;
  struct stat st;
  int ok = lstat(path, &st) == 0;
  if (!ok) {
    free(path);
    return 0;
  }
  uid_t uid = geteuid();
  if (!trusted_owner(&st, uid) ||
      (st.st_mode & (S_IWGRP | S_IWOTH)) != 0 ||
      !trusted_parent_chain(path, uid)) {
    free(path);
    return 0;
  }
  free(path);
  switch (policy) {
    case 1:
      return S_ISREG(st.st_mode) ? 1 : 0;
    case 2:
      return S_ISDIR(st.st_mode) &&
        (st.st_mode & (S_IRWXG | S_IRWXO)) == 0 ? 1 : 0;
    case 3:
      return S_ISDIR(st.st_mode) ? 1 : 0;
    case 4:
      return S_ISREG(st.st_mode) &&
        (st.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH)) != 0 ? 1 : 0;
    default:
      return 0;
  }
}
