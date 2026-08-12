#define _POSIX_C_SOURCE 200809L

#include <moonbit.h>

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif
#ifndef O_NOFOLLOW
#define O_NOFOLLOW 0
#endif

enum secure_fs_status {
  SECURE_FS_OK = 0,
  SECURE_FS_INVALID = 1,
  SECURE_FS_SOURCE = 2,
  SECURE_FS_DESTINATION = 3,
  SECURE_FS_IO = 4,
  SECURE_FS_UNSUPPORTED = 5
};

static atomic_uint_fast64_t temporary_counter = 1;

struct sha256_state {
  uint32_t words[8];
  uint64_t bytes;
  unsigned char block[64];
  size_t used;
};

static uint32_t rotate_right(uint32_t value, unsigned amount) {
  return (value >> amount) | (value << (32 - amount));
}

static void sha256_transform(struct sha256_state *state) {
  static const uint32_t constants[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
  };
  uint32_t schedule[64];
  for (int index = 0; index < 16; ++index) {
    const unsigned char *input = state->block + index * 4;
    schedule[index] = ((uint32_t)input[0] << 24) |
      ((uint32_t)input[1] << 16) | ((uint32_t)input[2] << 8) | input[3];
  }
  for (int index = 16; index < 64; ++index) {
    uint32_t s0 = rotate_right(schedule[index - 15], 7) ^
      rotate_right(schedule[index - 15], 18) ^ (schedule[index - 15] >> 3);
    uint32_t s1 = rotate_right(schedule[index - 2], 17) ^
      rotate_right(schedule[index - 2], 19) ^ (schedule[index - 2] >> 10);
    schedule[index] = schedule[index - 16] + s0 + schedule[index - 7] + s1;
  }
  uint32_t a = state->words[0];
  uint32_t b = state->words[1];
  uint32_t c = state->words[2];
  uint32_t d = state->words[3];
  uint32_t e = state->words[4];
  uint32_t f = state->words[5];
  uint32_t g = state->words[6];
  uint32_t h = state->words[7];
  for (int index = 0; index < 64; ++index) {
    uint32_t upper = rotate_right(e, 6) ^ rotate_right(e, 11) ^ rotate_right(e, 25);
    uint32_t choice = (e & f) ^ (~e & g);
    uint32_t first = h + upper + choice + constants[index] + schedule[index];
    uint32_t lower = rotate_right(a, 2) ^ rotate_right(a, 13) ^ rotate_right(a, 22);
    uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
    uint32_t second = lower + majority;
    h = g;
    g = f;
    f = e;
    e = d + first;
    d = c;
    c = b;
    b = a;
    a = first + second;
  }
  state->words[0] += a;
  state->words[1] += b;
  state->words[2] += c;
  state->words[3] += d;
  state->words[4] += e;
  state->words[5] += f;
  state->words[6] += g;
  state->words[7] += h;
}

static void sha256_init(struct sha256_state *state) {
  const uint32_t initial[8] = {
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
  };
  memcpy(state->words, initial, sizeof(initial));
  state->bytes = 0;
  state->used = 0;
}

static void sha256_update(
  struct sha256_state *state,
  const unsigned char *input,
  size_t length
) {
  state->bytes += length;
  while (length > 0) {
    size_t available = sizeof(state->block) - state->used;
    size_t take = length < available ? length : available;
    memcpy(state->block + state->used, input, take);
    state->used += take;
    input += take;
    length -= take;
    if (state->used == sizeof(state->block)) {
      sha256_transform(state);
      state->used = 0;
    }
  }
}

static void sha256_finish(struct sha256_state *state, unsigned char output[32]) {
  uint64_t bit_length = state->bytes * 8;
  state->block[state->used++] = 0x80;
  if (state->used > 56) {
    memset(state->block + state->used, 0, sizeof(state->block) - state->used);
    sha256_transform(state);
    state->used = 0;
  }
  memset(state->block + state->used, 0, 56 - state->used);
  for (int index = 0; index < 8; ++index) {
    state->block[63 - index] = (unsigned char)(bit_length >> (index * 8));
  }
  sha256_transform(state);
  for (int index = 0; index < 8; ++index) {
    output[index * 4] = (unsigned char)(state->words[index] >> 24);
    output[index * 4 + 1] = (unsigned char)(state->words[index] >> 16);
    output[index * 4 + 2] = (unsigned char)(state->words[index] >> 8);
    output[index * 4 + 3] = (unsigned char)state->words[index];
  }
}

static int sha256_matches_hex(
  const unsigned char digest[32],
  const unsigned char *expected,
  int32_t expected_length
) {
  static const char hex[] = "0123456789abcdef";
  if (expected_length != 64) return 0;
  unsigned char difference = 0;
  for (int index = 0; index < 32; ++index) {
    difference |= expected[index * 2] ^ hex[digest[index] >> 4];
    difference |= expected[index * 2 + 1] ^ hex[digest[index] & 15];
  }
  return difference == 0;
}

static int open_directory_at(int parent, const char *component) {
  struct stat before;
  if (fstatat(parent, component, &before, AT_SYMLINK_NOFOLLOW) != 0) {
    return -1;
  }
  if (!S_ISDIR(before.st_mode)) {
    errno = ENOTDIR;
    return -1;
  }
  int directory = openat(
    parent,
    component,
    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
  );
  if (directory < 0) return -1;
  struct stat opened;
  struct stat after;
  if (fstat(directory, &opened) != 0 ||
      fstatat(parent, component, &after, AT_SYMLINK_NOFOLLOW) != 0 ||
      !S_ISDIR(after.st_mode) || before.st_dev != opened.st_dev ||
      before.st_ino != opened.st_ino || after.st_dev != opened.st_dev ||
      after.st_ino != opened.st_ino) {
    close(directory);
    errno = ESTALE;
    return -1;
  }
  return directory;
}

static int open_regular_at(int parent, const char *component) {
  struct stat before;
  if (fstatat(parent, component, &before, AT_SYMLINK_NOFOLLOW) != 0) return -1;
  if (!S_ISREG(before.st_mode)) {
    errno = EINVAL;
    return -1;
  }
  int file = openat(parent, component, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (file < 0) return -1;
  struct stat opened;
  struct stat after;
  if (fstat(file, &opened) != 0 ||
      fstatat(parent, component, &after, AT_SYMLINK_NOFOLLOW) != 0 ||
      !S_ISREG(opened.st_mode) || !S_ISREG(after.st_mode) ||
      before.st_dev != opened.st_dev || before.st_ino != opened.st_ino ||
      after.st_dev != opened.st_dev || after.st_ino != opened.st_ino) {
    close(file);
    errno = ESTALE;
    return -1;
  }
  return file;
}

static char *copy_checked_path(
  const unsigned char *bytes,
  int32_t length,
  int absolute
) {
  if (length <= 0 || memchr(bytes, 0, (size_t)length) != NULL) return NULL;
  if ((absolute && bytes[0] != '/') || (!absolute && bytes[0] == '/')) return NULL;
  char *path = malloc((size_t)length + 1);
  if (path == NULL) return NULL;
  memcpy(path, bytes, (size_t)length);
  path[length] = 0;
  if (path[length - 1] == '/' || strstr(path, "//") != NULL) {
    free(path);
    return NULL;
  }
  const char *cursor = absolute ? path + 1 : path;
  while (*cursor != 0) {
    const char *slash = strchr(cursor, '/');
    size_t component_length = slash == NULL
      ? strlen(cursor)
      : (size_t)(slash - cursor);
    if (component_length == 0 || component_length > NAME_MAX ||
        (component_length == 1 && cursor[0] == '.') ||
        (component_length == 2 && cursor[0] == '.' && cursor[1] == '.')) {
      free(path);
      return NULL;
    }
    if (slash == NULL) break;
    cursor = slash + 1;
  }
  return path;
}

static int open_absolute_directory(const char *path) {
  if (path == NULL || path[0] != '/') {
    errno = EINVAL;
    return -1;
  }
  int current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (current < 0) return -1;
  if (path[1] == 0) return current;
  const char *cursor = path + 1;
  while (*cursor != 0) {
    const char *slash = strchr(cursor, '/');
    size_t length = slash == NULL ? strlen(cursor) : (size_t)(slash - cursor);
    char component[NAME_MAX + 1];
    if (length == 0 || length > NAME_MAX) {
      close(current);
      errno = EINVAL;
      return -1;
    }
    memcpy(component, cursor, length);
    component[length] = 0;
    int next = open_directory_at(current, component);
    if (next < 0) {
      close(current);
      return -1;
    }
    close(current);
    current = next;
    if (slash == NULL) break;
    cursor = slash + 1;
  }
  return current;
}

static int open_relative_parent(
  int root,
  const char *path,
  int create,
  char leaf[NAME_MAX + 1]
) {
  int current = dup(root);
  if (current < 0) return -1;
  (void)fcntl(current, F_SETFD, FD_CLOEXEC);
  const char *cursor = path;
  for (;;) {
    const char *slash = strchr(cursor, '/');
    size_t length = slash == NULL ? strlen(cursor) : (size_t)(slash - cursor);
    if (length == 0 || length > NAME_MAX) {
      close(current);
      errno = EINVAL;
      return -1;
    }
    if (slash == NULL) {
      memcpy(leaf, cursor, length);
      leaf[length] = 0;
      return current;
    }
    char component[NAME_MAX + 1];
    memcpy(component, cursor, length);
    component[length] = 0;
    int next = open_directory_at(current, component);
    if (next < 0 && create && errno == ENOENT) {
      if (mkdirat(current, component, 0700) != 0 && errno != EEXIST) {
        close(current);
        return -1;
      }
      next = open_directory_at(current, component);
    }
    if (next < 0) {
      close(current);
      return -1;
    }
    close(current);
    current = next;
    cursor = slash + 1;
  }
}

static int split_absolute_parent(
  const char *path,
  int *parent,
  char leaf[NAME_MAX + 1]
) {
  const char *slash = strrchr(path, '/');
  if (slash == NULL || slash[1] == 0) return -1;
  size_t leaf_length = strlen(slash + 1);
  if (leaf_length == 0 || leaf_length > NAME_MAX) return -1;
  memcpy(leaf, slash + 1, leaf_length + 1);
  if (slash == path) {
    *parent = open_absolute_directory("/");
    return *parent < 0 ? -1 : 0;
  }
  size_t parent_length = (size_t)(slash - path);
  char *parent_path = malloc(parent_length + 1);
  if (parent_path == NULL) return -1;
  memcpy(parent_path, path, parent_length);
  parent_path[parent_length] = 0;
  *parent = open_absolute_directory(parent_path);
  free(parent_path);
  return *parent < 0 ? -1 : 0;
}

static int remove_directory_children(int directory) {
  int stream_fd = dup(directory);
  if (stream_fd < 0) return SECURE_FS_IO;
  DIR *stream = fdopendir(stream_fd);
  if (stream == NULL) {
    close(stream_fd);
    return SECURE_FS_IO;
  }
  int result = SECURE_FS_OK;
  for (;;) {
    errno = 0;
    struct dirent *entry = readdir(stream);
    if (entry == NULL) {
      if (errno != 0) result = SECURE_FS_IO;
      break;
    }
    if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
      continue;
    }
    struct stat status;
    if (fstatat(directory, entry->d_name, &status, AT_SYMLINK_NOFOLLOW) != 0) {
      result = SECURE_FS_IO;
      break;
    }
    if (S_ISDIR(status.st_mode)) {
      int child = open_directory_at(directory, entry->d_name);
      if (child < 0) {
        result = SECURE_FS_IO;
        break;
      }
      result = remove_directory_children(child);
      close(child);
      if (result != SECURE_FS_OK ||
          unlinkat(directory, entry->d_name, AT_REMOVEDIR) != 0) {
        if (result == SECURE_FS_OK) result = SECURE_FS_IO;
        break;
      }
    } else if (S_ISREG(status.st_mode) || S_ISLNK(status.st_mode)) {
      if (unlinkat(directory, entry->d_name, 0) != 0) {
        result = SECURE_FS_IO;
        break;
      }
    } else {
      result = SECURE_FS_UNSUPPORTED;
      break;
    }
  }
  closedir(stream);
  return result;
}

MOONBIT_FFI_EXPORT
int32_t moonfort_secure_clear_directory(
  moonbit_bytes_t root_bytes,
  int32_t root_length
) {
  char *root = copy_checked_path(root_bytes, root_length, 1);
  if (root == NULL) return SECURE_FS_INVALID;
  int directory = open_absolute_directory(root);
  free(root);
  if (directory < 0) return SECURE_FS_INVALID;
  int result = remove_directory_children(directory);
  close(directory);
  return result;
}

MOONBIT_FFI_EXPORT
int32_t moonfort_secure_discard_tree(
  moonbit_bytes_t root_bytes,
  int32_t root_length
) {
  char *root = copy_checked_path(root_bytes, root_length, 1);
  if (root == NULL || strcmp(root, "/") == 0) {
    free(root);
    return SECURE_FS_INVALID;
  }
  int parent = -1;
  char leaf[NAME_MAX + 1];
  if (split_absolute_parent(root, &parent, leaf) != 0) {
    free(root);
    return SECURE_FS_INVALID;
  }
  free(root);
  int directory = open_directory_at(parent, leaf);
  if (directory < 0) {
    close(parent);
    return SECURE_FS_INVALID;
  }
  struct stat opened;
  int result = fstat(directory, &opened) == 0
    ? remove_directory_children(directory)
    : SECURE_FS_IO;
  close(directory);
  if (result == SECURE_FS_OK) {
    struct stat current;
    if (fstatat(parent, leaf, &current, AT_SYMLINK_NOFOLLOW) != 0 ||
        !S_ISDIR(current.st_mode) || current.st_dev != opened.st_dev ||
        current.st_ino != opened.st_ino || unlinkat(parent, leaf, AT_REMOVEDIR) != 0) {
      result = SECURE_FS_IO;
    }
  }
  close(parent);
  return result;
}

MOONBIT_FFI_EXPORT
int32_t moonfort_secure_promote_regular(
  moonbit_bytes_t source_root_bytes,
  int32_t source_root_length,
  moonbit_bytes_t source_path_bytes,
  int32_t source_path_length,
  moonbit_bytes_t destination_root_bytes,
  int32_t destination_root_length,
  moonbit_bytes_t destination_path_bytes,
  int32_t destination_path_length,
  int64_t expected_size,
  moonbit_bytes_t expected_fingerprint,
  int32_t expected_fingerprint_length
) {
  char *source_root = copy_checked_path(
    source_root_bytes, source_root_length, 1
  );
  char *source_path = copy_checked_path(
    source_path_bytes, source_path_length, 0
  );
  char *destination_root = copy_checked_path(
    destination_root_bytes, destination_root_length, 1
  );
  char *destination_path = copy_checked_path(
    destination_path_bytes, destination_path_length, 0
  );
  if (source_root == NULL || source_path == NULL || destination_root == NULL ||
      destination_path == NULL || expected_size < 0 ||
      expected_fingerprint_length != 64) {
    free(source_root);
    free(source_path);
    free(destination_root);
    free(destination_path);
    return SECURE_FS_INVALID;
  }
  int source_root_fd = open_absolute_directory(source_root);
  int destination_root_fd = open_absolute_directory(destination_root);
  free(source_root);
  free(destination_root);
  if (source_root_fd < 0 || destination_root_fd < 0) {
    if (source_root_fd >= 0) close(source_root_fd);
    if (destination_root_fd >= 0) close(destination_root_fd);
    free(source_path);
    free(destination_path);
    return SECURE_FS_INVALID;
  }
  char source_leaf[NAME_MAX + 1];
  char destination_leaf[NAME_MAX + 1];
  int source_parent = open_relative_parent(
    source_root_fd, source_path, 0, source_leaf
  );
  int destination_parent = open_relative_parent(
    destination_root_fd, destination_path, 1, destination_leaf
  );
  free(source_path);
  free(destination_path);
  close(source_root_fd);
  close(destination_root_fd);
  if (source_parent < 0) {
    if (destination_parent >= 0) close(destination_parent);
    return SECURE_FS_SOURCE;
  }
  if (destination_parent < 0) {
    close(source_parent);
    return SECURE_FS_DESTINATION;
  }
  int source = open_regular_at(source_parent, source_leaf);
  close(source_parent);
  struct stat source_status;
  if (source < 0 || fstat(source, &source_status) != 0 ||
      !S_ISREG(source_status.st_mode) || source_status.st_size != expected_size) {
    if (source >= 0) close(source);
    close(destination_parent);
    return SECURE_FS_SOURCE;
  }
  struct stat destination_status;
  errno = 0;
  int destination_stat = fstatat(
    destination_parent,
    destination_leaf,
    &destination_status,
    AT_SYMLINK_NOFOLLOW
  );
  if (destination_stat == 0 && !S_ISREG(destination_status.st_mode)) {
    close(source);
    close(destination_parent);
    return SECURE_FS_DESTINATION;
  } else if (destination_stat != 0 && errno != ENOENT) {
    close(source);
    close(destination_parent);
    return SECURE_FS_DESTINATION;
  }
  char temporary[NAME_MAX + 1];
  int output = -1;
  for (int attempt = 0; attempt < 128; ++attempt) {
    uint64_t nonce = atomic_fetch_add(&temporary_counter, 1);
    snprintf(
      temporary,
      sizeof(temporary),
      ".moonfort-%ld-%llu.tmp",
      (long)getpid(),
      (unsigned long long)nonce
    );
    output = openat(
      destination_parent,
      temporary,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
      0600
    );
    if (output >= 0 || errno != EEXIST) break;
  }
  if (output < 0) {
    close(source);
    close(destination_parent);
    return SECURE_FS_DESTINATION;
  }
  int result = SECURE_FS_OK;
  int64_t copied = 0;
  struct sha256_state hasher;
  sha256_init(&hasher);
  unsigned char buffer[65536];
  for (;;) {
    ssize_t count = read(source, buffer, sizeof(buffer));
    if (count == 0) break;
    if (count < 0) {
      if (errno == EINTR) continue;
      result = SECURE_FS_SOURCE;
      break;
    }
    copied += count;
    if (copied > expected_size) {
      result = SECURE_FS_SOURCE;
      break;
    }
    sha256_update(&hasher, buffer, (size_t)count);
    size_t offset = 0;
    while (offset < (size_t)count) {
      ssize_t written = write(output, buffer + offset, (size_t)count - offset);
      if (written > 0) {
        offset += (size_t)written;
      } else if (written < 0 && errno == EINTR) {
        continue;
      } else {
        result = SECURE_FS_IO;
        break;
      }
    }
    if (result != SECURE_FS_OK) break;
  }
  struct stat source_after;
  unsigned char digest[32];
  sha256_finish(&hasher, digest);
  if (result == SECURE_FS_OK &&
      (copied != expected_size || fstat(source, &source_after) != 0 ||
       source_after.st_dev != source_status.st_dev ||
       source_after.st_ino != source_status.st_ino ||
       source_after.st_size != source_status.st_size ||
       !sha256_matches_hex(
         digest, expected_fingerprint, expected_fingerprint_length
       ))) {
    result = SECURE_FS_SOURCE;
  }
  if (result == SECURE_FS_OK && fsync(output) != 0) result = SECURE_FS_IO;
  close(source);
  close(output);
  if (result == SECURE_FS_OK &&
      renameat(destination_parent, temporary, destination_parent, destination_leaf) != 0) {
    result = SECURE_FS_DESTINATION;
  }
  if (result == SECURE_FS_OK && fsync(destination_parent) != 0) {
    result = SECURE_FS_IO;
  }
  if (result != SECURE_FS_OK) (void)unlinkat(destination_parent, temporary, 0);
  close(destination_parent);
  return result;
}
