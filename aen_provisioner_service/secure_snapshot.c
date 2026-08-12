#define _POSIX_C_SOURCE 200809L

#include <moonbit.h>

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif
#ifndef O_NOFOLLOW
#define O_NOFOLLOW 0
#endif

struct sha256_state {
  uint32_t words[8];
  uint64_t bytes;
  unsigned char block[64];
  size_t used;
};

struct snapshot_context {
  int layer;
  int manifest;
  int64_t max_bytes;
  int64_t max_file_bytes;
  int64_t total_bytes;
  int max_entries;
  int entry_count;
  int64_t deadline_ms;
  struct sha256_state layer_hash;
  struct sha256_state workspace_hash;
};

static int trusted_owner_mode(const struct stat *status, int directory);

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
  uint32_t a = state->words[0], b = state->words[1];
  uint32_t c = state->words[2], d = state->words[3];
  uint32_t e = state->words[4], f = state->words[5];
  uint32_t g = state->words[6], h = state->words[7];
  for (int index = 0; index < 64; ++index) {
    uint32_t upper = rotate_right(e, 6) ^ rotate_right(e, 11) ^ rotate_right(e, 25);
    uint32_t choice = (e & f) ^ (~e & g);
    uint32_t first = h + upper + choice + constants[index] + schedule[index];
    uint32_t lower = rotate_right(a, 2) ^ rotate_right(a, 13) ^ rotate_right(a, 22);
    uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
    uint32_t second = lower + majority;
    h = g; g = f; f = e; e = d + first;
    d = c; c = b; b = a; a = first + second;
  }
  state->words[0] += a; state->words[1] += b;
  state->words[2] += c; state->words[3] += d;
  state->words[4] += e; state->words[5] += f;
  state->words[6] += g; state->words[7] += h;
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

static void hex_digest(const unsigned char digest[32], char output[65]) {
  static const char hex[] = "0123456789abcdef";
  for (int index = 0; index < 32; ++index) {
    output[index * 2] = hex[digest[index] >> 4];
    output[index * 2 + 1] = hex[digest[index] & 15];
  }
  output[64] = 0;
}

static int64_t monotonic_ms(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return INT64_MAX;
  return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static int timed_out(const struct snapshot_context *context) {
  return monotonic_ms() > context->deadline_ms;
}

static int write_all(int descriptor, const void *data, size_t length) {
  const unsigned char *cursor = data;
  while (length > 0) {
    ssize_t written = write(descriptor, cursor, length);
    if (written < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    if (written == 0) return -1;
    cursor += written;
    length -= (size_t)written;
  }
  return 0;
}

static int write_hashed(
  int descriptor,
  struct sha256_state *hash,
  const void *data,
  size_t length
) {
  if (write_all(descriptor, data, length) != 0) return -1;
  sha256_update(hash, data, length);
  return 0;
}

static int valid_utf8(const unsigned char *value, size_t length) {
  size_t index = 0;
  while (index < length) {
    unsigned char first = value[index++];
    if (first < 0x80) {
      if (first == 0 || first == '\n' || first == '\r' || first == '\t' ||
          first == '\\') return 0;
      continue;
    }
    int needed;
    uint32_t code;
    if ((first & 0xe0) == 0xc0) { needed = 1; code = first & 0x1f; }
    else if ((first & 0xf0) == 0xe0) { needed = 2; code = first & 0x0f; }
    else if ((first & 0xf8) == 0xf0) { needed = 3; code = first & 0x07; }
    else return 0;
    if (index + (size_t)needed > length) return 0;
    for (int count = 0; count < needed; ++count) {
      unsigned char next = value[index++];
      if ((next & 0xc0) != 0x80) return 0;
      code = (code << 6) | (next & 0x3f);
    }
    if ((needed == 1 && code < 0x80) || (needed == 2 && code < 0x800) ||
        (needed == 3 && code < 0x10000) || code > 0x10ffff ||
        (code >= 0xd800 && code <= 0xdfff)) return 0;
  }
  return 1;
}

static char *copy_input(moonbit_bytes_t bytes, int32_t length, int absolute) {
  if (length <= 0 || length > 4096 || memchr(bytes, 0, (size_t)length) != NULL) {
    return NULL;
  }
  if (absolute && bytes[0] != '/') return NULL;
  char *result = malloc((size_t)length + 1);
  if (result == NULL) return NULL;
  memcpy(result, bytes, (size_t)length);
  result[length] = 0;
  if (absolute && (length == 1 || result[length - 1] == '/' || strstr(result, "//"))) {
    free(result);
    return NULL;
  }
  if (!valid_utf8((unsigned char *)result, (size_t)length)) {
    free(result);
    return NULL;
  }
  return result;
}

static int safe_token(const char *value) {
  size_t length = strlen(value);
  if (length == 0 || length > 128) return 0;
  for (size_t index = 0; index < length; ++index) {
    char c = value[index];
    if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
          (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.')) return 0;
  }
  return 1;
}

static int safe_repository(const char *value) {
  size_t length = strlen(value);
  if (length == 0 || length > 1024 || value[0] == '/' || value[length - 1] == '/' ||
      strchr(value, '@') || strstr(value, "://") || strstr(value, "//") ||
      strstr(value, "/../") || strstr(value, "/./")) return 0;
  for (size_t index = 0; index < length; ++index) {
    char c = value[index];
    if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
          (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-' ||
          c == '/' || c == ':')) return 0;
  }
  return 1;
}

static int open_directory_component(int parent, const char *name) {
  struct stat before, opened, after;
  if (fstatat(parent, name, &before, AT_SYMLINK_NOFOLLOW) != 0 ||
      !S_ISDIR(before.st_mode)) return -1;
  int result = openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (result < 0) return -1;
  if (fstat(result, &opened) != 0 ||
      fstatat(parent, name, &after, AT_SYMLINK_NOFOLLOW) != 0 ||
      !S_ISDIR(after.st_mode) || before.st_dev != opened.st_dev ||
      before.st_ino != opened.st_ino || after.st_dev != opened.st_dev ||
      after.st_ino != opened.st_ino) {
    close(result);
    errno = ESTALE;
    return -1;
  }
  return result;
}

static int open_absolute_directory(const char *path) {
  int current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (current < 0) return -1;
  const char *cursor = path + 1;
  while (*cursor) {
    const char *slash = strchr(cursor, '/');
    size_t length = slash ? (size_t)(slash - cursor) : strlen(cursor);
    if (length == 0 || length > NAME_MAX ||
        (length == 1 && cursor[0] == '.') ||
        (length == 2 && cursor[0] == '.' && cursor[1] == '.')) {
      close(current); errno = EINVAL; return -1;
    }
    char component[NAME_MAX + 1];
    memcpy(component, cursor, length); component[length] = 0;
    int next = open_directory_component(current, component);
    close(current);
    if (next < 0) return -1;
    current = next;
    if (!slash) break;
    cursor = slash + 1;
  }
  return current;
}

static int stat_same(const struct stat *left, const struct stat *right) {
  int timestamps_match;
#if defined(__APPLE__)
  timestamps_match = left->st_mtime == right->st_mtime &&
    left->st_mtimensec == right->st_mtimensec &&
    left->st_ctime == right->st_ctime &&
    left->st_ctimensec == right->st_ctimensec;
#else
  timestamps_match = left->st_mtim.tv_sec == right->st_mtim.tv_sec &&
    left->st_mtim.tv_nsec == right->st_mtim.tv_nsec &&
    left->st_ctim.tv_sec == right->st_ctim.tv_sec &&
    left->st_ctim.tv_nsec == right->st_ctim.tv_nsec;
#endif
  return timestamps_match &&
    left->st_dev == right->st_dev && left->st_ino == right->st_ino &&
    left->st_mode == right->st_mode && left->st_size == right->st_size &&
    left->st_mtime == right->st_mtime && left->st_ctime == right->st_ctime;
}

static int compare_names(const void *left, const void *right) {
  const char *const *a = left;
  const char *const *b = right;
  return strcmp(*a, *b);
}

static void free_names(char **names, size_t count) {
  if (!names) return;
  for (size_t index = 0; index < count; ++index) free(names[index]);
  free(names);
}

static int list_names(int directory, char ***output, size_t *count) {
  int copied = dup(directory);
  if (copied < 0) return -1;
  (void)fcntl(copied, F_SETFD, FD_CLOEXEC);
  DIR *stream = fdopendir(copied);
  if (!stream) { close(copied); return -1; }
  char **names = NULL;
  size_t used = 0, capacity = 0;
  for (;;) {
    errno = 0;
    struct dirent *entry = readdir(stream);
    if (!entry) {
      if (errno != 0) { free_names(names, used); closedir(stream); return -1; }
      break;
    }
    if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
    size_t length = strlen(entry->d_name);
    if (length == 0 || length > NAME_MAX ||
        !valid_utf8((unsigned char *)entry->d_name, length)) {
      free_names(names, used); closedir(stream); errno = EINVAL; return -1;
    }
    if (used == capacity) {
      size_t next = capacity ? capacity * 2 : 32;
      char **grown = realloc(names, next * sizeof(*names));
      if (!grown) { free_names(names, used); closedir(stream); return -1; }
      names = grown; capacity = next;
    }
    names[used] = strdup(entry->d_name);
    if (!names[used]) { free_names(names, used); closedir(stream); return -1; }
    ++used;
  }
  closedir(stream);
  qsort(names, used, sizeof(*names), compare_names);
  *output = names; *count = used;
  return 0;
}

static void tar_octal(char *field, size_t length, uint64_t value) {
  memset(field, '0', length);
  field[length - 1] = 0;
  size_t index = length - 2;
  while (value && index > 0) {
    field[index--] = (char)('0' + (value & 7));
    value >>= 3;
  }
}

static int tar_name(char header[512], const char *path) {
  size_t length = strlen(path);
  if (length <= 100) { memcpy(header, path, length); return 0; }
  if (length > 255) return -1;
  const char *split = path + length - 100;
  while (split < path + length && *split != '/') ++split;
  if (*split != '/' || (size_t)(split - path) > 155 || strlen(split + 1) > 100) return -1;
  memcpy(header + 345, path, (size_t)(split - path));
  memcpy(header, split + 1, strlen(split + 1));
  return 0;
}

static int tar_header(
  struct snapshot_context *context,
  const char *path,
  uint64_t size,
  int directory
) {
  char header[512];
  memset(header, 0, sizeof(header));
  if (tar_name(header, path) != 0) return -1;
  tar_octal(header + 100, 8, directory ? 0555 : 0444);
  tar_octal(header + 108, 8, 0);
  tar_octal(header + 116, 8, 0);
  tar_octal(header + 124, 12, size);
  tar_octal(header + 136, 12, 0);
  memset(header + 148, ' ', 8);
  header[156] = directory ? '5' : '0';
  memcpy(header + 257, "ustar", 5);
  header[262] = 0;
  memcpy(header + 263, "00", 2);
  unsigned checksum = 0;
  for (size_t index = 0; index < sizeof(header); ++index) checksum += (unsigned char)header[index];
  snprintf(header + 148, 8, "%06o", checksum);
  header[154] = 0;
  header[155] = ' ';
  return write_hashed(context->layer, &context->layer_hash, header, sizeof(header));
}

static int manifest_line(
  struct snapshot_context *context,
  char kind,
  const char *path,
  int64_t size,
  const char *digest
) {
  int required = snprintf(NULL, 0, "%c\t%s\t%lld\t%s\n", kind, path,
    (long long)size, digest);
  if (required < 0 || required > 8192) return -1;
  char *line = malloc((size_t)required + 1);
  if (!line) return -1;
  snprintf(line, (size_t)required + 1, "%c\t%s\t%lld\t%s\n", kind, path,
    (long long)size, digest);
  int result = write_hashed(context->manifest, &context->workspace_hash,
    line, (size_t)required);
  free(line);
  return result;
}

static int copy_regular(
  struct snapshot_context *context,
  int parent,
  const char *name,
  const char *relative,
  const struct stat *before
) {
  if (before->st_size < 0 || before->st_size > context->max_file_bytes ||
      before->st_size > context->max_bytes - context->total_bytes) return -2;
  int file = openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (file < 0) return -3;
  struct stat opened;
  if (fstat(file, &opened) != 0 || !S_ISREG(opened.st_mode) ||
      !stat_same(before, &opened)) { close(file); return -3; }
  if (tar_header(context, relative, (uint64_t)opened.st_size, 0) != 0) {
    close(file); return -1;
  }
  struct sha256_state file_hash;
  sha256_init(&file_hash);
  unsigned char buffer[65536];
  int64_t observed = 0;
  for (;;) {
    if (timed_out(context)) { close(file); return -4; }
    ssize_t count = read(file, buffer, sizeof(buffer));
    if (count < 0) { if (errno == EINTR) continue; close(file); return -1; }
    if (count == 0) break;
    observed += count;
    if (observed > opened.st_size || observed > context->max_file_bytes ||
        observed > context->max_bytes - context->total_bytes) {
      close(file); return -2;
    }
    if (write_hashed(context->layer, &context->layer_hash, buffer,
          (size_t)count) != 0) { close(file); return -1; }
    sha256_update(&file_hash, buffer, (size_t)count);
  }
  struct stat after_open, after_name;
  if (fstat(file, &after_open) != 0 ||
      fstatat(parent, name, &after_name, AT_SYMLINK_NOFOLLOW) != 0 ||
      observed != opened.st_size || !stat_same(&opened, &after_open) ||
      !stat_same(&opened, &after_name)) { close(file); return -3; }
  close(file);
  size_t padding = (size_t)((512 - (observed % 512)) % 512);
  if (padding) {
    unsigned char zeros[512] = {0};
    if (write_hashed(context->layer, &context->layer_hash, zeros, padding) != 0) return -1;
  }
  unsigned char digest[32]; char hex[65];
  sha256_finish(&file_hash, digest); hex_digest(digest, hex);
  if (manifest_line(context, 'F', relative, observed, hex) != 0) return -1;
  context->total_bytes += observed;
  return 0;
}

static int walk_directory(
  struct snapshot_context *context,
  int directory,
  const char *prefix
) {
  if (timed_out(context)) return -4;
  struct stat directory_before;
  if (fstat(directory, &directory_before) != 0 || !S_ISDIR(directory_before.st_mode)) return -3;
  char **names = NULL; size_t count = 0;
  if (list_names(directory, &names, &count) != 0) return -3;
  for (size_t index = 0; index < count; ++index) {
    if (timed_out(context)) { free_names(names, count); return -4; }
    if (++context->entry_count > context->max_entries) {
      free_names(names, count); return -2;
    }
    size_t needed = strlen(prefix) + (prefix[0] ? 1 : 0) + strlen(names[index]) + 1;
    if (needed > 4096) { free_names(names, count); return -2; }
    char *relative = malloc(needed);
    if (!relative) { free_names(names, count); return -1; }
    snprintf(relative, needed, "%s%s%s", prefix, prefix[0] ? "/" : "", names[index]);
    struct stat before;
    if (fstatat(directory, names[index], &before, AT_SYMLINK_NOFOLLOW) != 0) {
      free(relative); free_names(names, count); return -3;
    }
    int result;
    if (S_ISREG(before.st_mode)) {
      result = copy_regular(context, directory, names[index], relative, &before);
    } else if (S_ISDIR(before.st_mode)) {
      if (tar_header(context, relative, 0, 1) != 0 ||
          manifest_line(context, 'D', relative, 0, "-") != 0) {
        result = -1;
      } else {
        int child = open_directory_component(directory, names[index]);
        if (child < 0) result = -3;
        else {
          result = walk_directory(context, child, relative);
          struct stat opened_after, named_after;
          if (result == 0 && (fstat(child, &opened_after) != 0 ||
              fstatat(directory, names[index], &named_after, AT_SYMLINK_NOFOLLOW) != 0 ||
              !stat_same(&before, &opened_after) || !stat_same(&before, &named_after))) result = -3;
          close(child);
        }
      }
    } else {
      result = -5;
    }
    free(relative);
    if (result != 0) { free_names(names, count); return result; }
  }
  free_names(names, count);
  struct stat directory_after;
  if (fstat(directory, &directory_after) != 0 ||
      !stat_same(&directory_before, &directory_after)) return -3;
  return 0;
}

static moonbit_bytes_t json_message(int ok, const char *message) {
  const char *format = ok ? "{\"ok\":true,\"result\":%s}" :
    "{\"ok\":false,\"error\":\"%s\"}";
  int length = snprintf(NULL, 0, format, message);
  char *temporary = malloc((size_t)length + 1);
  if (!temporary) return moonbit_make_bytes(0, 0);
  snprintf(temporary, (size_t)length + 1, format, message);
  moonbit_bytes_t output = moonbit_make_bytes(length, 0);
  memcpy(output, temporary, (size_t)length);
  free(temporary);
  return output;
}

static const char *failure_message(int code) {
  switch (code) {
    case -2: return "workspace exceeds configured size, file, path, or entry bounds";
    case -3: return "workspace changed during snapshot or contains an unsafe entry";
    case -4: return "workspace snapshot exceeded its wall-clock limit";
    case -5: return "workspace contains a symlink or special file";
    default: return "workspace snapshot storage operation failed";
  }
}

static int publish_blob(
  int temporary,
  int stage,
  const char *temporary_name,
  int blob_root,
  const char digest[65],
  int64_t deadline_ms
) {
  if (fsync(temporary) != 0) return -1;
  if (linkat(stage, temporary_name, blob_root, digest, 0) == 0) return 0;
  if (errno != EEXIST) return -1;
  struct stat before, opened, after;
  if (fstatat(blob_root, digest, &before, AT_SYMLINK_NOFOLLOW) != 0 ||
      !S_ISREG(before.st_mode)) return -1;
  int existing = openat(blob_root, digest, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (existing < 0 || fstat(existing, &opened) != 0 ||
      !stat_same(&before, &opened)) {
    if (existing >= 0) close(existing);
    return -1;
  }
  struct sha256_state hash;
  sha256_init(&hash);
  unsigned char buffer[65536];
  for (;;) {
    if (monotonic_ms() > deadline_ms) { close(existing); return -1; }
    ssize_t count = read(existing, buffer, sizeof(buffer));
    if (count < 0) {
      if (errno == EINTR) continue;
      close(existing); return -1;
    }
    if (count == 0) break;
    sha256_update(&hash, buffer, (size_t)count);
  }
  unsigned char raw[32]; char observed[65];
  sha256_finish(&hash, raw); hex_digest(raw, observed);
  int valid = fstat(existing, &after) == 0 && stat_same(&opened, &after) &&
    fstatat(blob_root, digest, &after, AT_SYMLINK_NOFOLLOW) == 0 &&
    stat_same(&opened, &after) && strcmp(observed, digest) == 0;
  close(existing);
  return valid ? 0 : -1;
}

static int ensure_blob_root(int artifact_root) {
  if (mkdirat(artifact_root, "blobs", 0700) != 0 && errno != EEXIST) return -1;
  int blobs = open_directory_component(artifact_root, "blobs");
  if (blobs < 0) return -1;
  if (mkdirat(blobs, "sha256", 0700) != 0 && errno != EEXIST) { close(blobs); return -1; }
  int result = open_directory_component(blobs, "sha256");
  close(blobs);
  return result;
}

static int write_temp(int directory, const char *name, const char *data, size_t length) {
  int file = openat(directory, name, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (file < 0) return -1;
  if (write_all(file, data, length) != 0) { close(file); return -1; }
  return file;
}

static int cleanup_stage(int parent, const char *name, int stage) {
  if (stage >= 0) {
    char **names = NULL; size_t count = 0;
    if (list_names(stage, &names, &count) != 0) return -1;
    for (size_t index = 0; index < count; ++index) {
      struct stat status;
      if (fstatat(stage, names[index], &status, AT_SYMLINK_NOFOLLOW) != 0 ||
          !S_ISREG(status.st_mode) || unlinkat(stage, names[index], 0) != 0) {
        free_names(names, count); return -1;
      }
    }
    free_names(names, count);
    close(stage);
  }
  return unlinkat(parent, name, AT_REMOVEDIR);
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t moonfort_aen_provisioner_snapshot(
  moonbit_bytes_t source_bytes, int32_t source_len,
  moonbit_bytes_t staging_bytes, int32_t staging_len,
  moonbit_bytes_t artifact_bytes, int32_t artifact_len,
  moonbit_bytes_t repository_bytes, int32_t repository_len,
  moonbit_bytes_t lease_bytes, int32_t lease_len,
  int64_t max_bytes, int32_t max_entries, int64_t max_file_bytes,
  int32_t timeout_ms
) {
  char *source_path = copy_input(source_bytes, source_len, 1);
  char *staging_path = copy_input(staging_bytes, staging_len, 1);
  char *artifact_path = copy_input(artifact_bytes, artifact_len, 1);
  char *repository = copy_input(repository_bytes, repository_len, 0);
  char *lease = copy_input(lease_bytes, lease_len, 0);
  int source = -1, staging_root = -1, artifact_root = -1, stage = -1;
  int layer = -1, manifest_file = -1, blob_root = -1;
  char stage_name[160];
  moonbit_bytes_t output = NULL;
  if (!source_path || !staging_path || !artifact_path || !repository || !lease ||
      !safe_token(lease) || !safe_repository(repository) ||
      max_bytes <= 0 || max_entries <= 0 || max_file_bytes <= 0 ||
      max_file_bytes > max_bytes || timeout_ms <= 0) {
    output = json_message(0, "invalid native snapshot request"); goto done;
  }
  source = open_absolute_directory(source_path);
  staging_root = open_absolute_directory(staging_path);
  artifact_root = open_absolute_directory(artifact_path);
  if (source < 0 || staging_root < 0 || artifact_root < 0) {
    output = json_message(0, "trusted source or storage root is unsafe"); goto done;
  }
  struct stat staging_status, artifact_status;
  if (fstat(staging_root, &staging_status) != 0 ||
      fstat(artifact_root, &artifact_status) != 0 ||
      !trusted_owner_mode(&staging_status, 1) ||
      !trusted_owner_mode(&artifact_status, 1) ||
      staging_status.st_dev != artifact_status.st_dev) {
    output = json_message(0, "provisioner storage roots are not private"); goto done;
  }
  snprintf(stage_name, sizeof(stage_name), ".snapshot-%s", lease);
  if (mkdirat(staging_root, stage_name, 0700) != 0) {
    output = json_message(0, "private staging allocation failed"); goto done;
  }
  stage = open_directory_component(staging_root, stage_name);
  if (stage < 0) { output = json_message(0, "private staging verification failed"); goto done;
  }
  layer = openat(stage, "layer.tar", O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
  manifest_file = openat(stage, "workspace.manifest", O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (layer < 0 || manifest_file < 0) {
    output = json_message(0, "private staging files could not be created"); goto done;
  }
  struct snapshot_context context = {
    .layer = layer, .manifest = manifest_file,
    .max_bytes = max_bytes, .max_file_bytes = max_file_bytes,
    .total_bytes = 0, .max_entries = max_entries, .entry_count = 0,
    .deadline_ms = monotonic_ms() + timeout_ms
  };
  sha256_init(&context.layer_hash); sha256_init(&context.workspace_hash);
  int result = walk_directory(&context, source, "");
  if (result != 0) { output = json_message(0, failure_message(result)); goto done; }
  unsigned char zeros[1024] = {0};
  if (write_hashed(layer, &context.layer_hash, zeros, sizeof(zeros)) != 0 ||
      fsync(manifest_file) != 0) {
    output = json_message(0, "snapshot finalization failed"); goto done;
  }
  unsigned char layer_raw[32], workspace_raw[32];
  char layer_digest[65], workspace_digest[65];
  sha256_finish(&context.layer_hash, layer_raw); hex_digest(layer_raw, layer_digest);
  sha256_finish(&context.workspace_hash, workspace_raw); hex_digest(workspace_raw, workspace_digest);
  off_t layer_size = lseek(layer, 0, SEEK_END);
  if (layer_size < 0) { output = json_message(0, "snapshot size could not be verified"); goto done; }
  char config_json[512];
  int config_len = snprintf(config_json, sizeof(config_json),
    "{\"architecture\":\"amd64\",\"config\":{},\"created\":\"1970-01-01T00:00:00Z\",\"os\":\"linux\",\"rootfs\":{\"diff_ids\":[\"sha256:%s\"],\"type\":\"layers\"}}",
    layer_digest);
  if (config_len <= 0 || config_len >= (int)sizeof(config_json)) {
    output = json_message(0, "OCI config encoding failed"); goto done;
  }
  struct sha256_state config_hash; unsigned char config_raw[32]; char config_digest[65];
  sha256_init(&config_hash); sha256_update(&config_hash, (unsigned char *)config_json, (size_t)config_len);
  sha256_finish(&config_hash, config_raw); hex_digest(config_raw, config_digest);
  char image_json[2048];
  int image_len = snprintf(image_json, sizeof(image_json),
    "{\"annotations\":{\"org.moonfort.workspace.digest\":\"%s\",\"org.moonfort.workspace.entries\":\"%d\",\"org.moonfort.workspace.totalBytes\":\"%lld\"},\"config\":{\"digest\":\"sha256:%s\",\"mediaType\":\"application/vnd.oci.image.config.v1+json\",\"size\":%d},\"layers\":[{\"digest\":\"sha256:%s\",\"mediaType\":\"application/vnd.oci.image.layer.v1.tar\",\"size\":%lld}],\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"schemaVersion\":2}",
    workspace_digest, context.entry_count, (long long)context.total_bytes,
    config_digest, config_len, layer_digest, (long long)layer_size);
  if (image_len <= 0 || image_len >= (int)sizeof(image_json)) {
    output = json_message(0, "OCI manifest encoding failed"); goto done;
  }
  struct sha256_state image_hash; unsigned char image_raw[32]; char image_digest[65];
  sha256_init(&image_hash); sha256_update(&image_hash, (unsigned char *)image_json, (size_t)image_len);
  sha256_finish(&image_hash, image_raw); hex_digest(image_raw, image_digest);
  int config_file = write_temp(stage, "config.json", config_json, (size_t)config_len);
  int image_file = write_temp(stage, "image.manifest.json", image_json, (size_t)image_len);
  if (config_file < 0 || image_file < 0) {
    if (config_file >= 0) close(config_file);
    if (image_file >= 0) close(image_file);
    output = json_message(0, "OCI metadata staging failed"); goto done;
  }
  blob_root = ensure_blob_root(artifact_root);
  if (blob_root < 0 ||
      publish_blob(layer, stage, "layer.tar", blob_root, layer_digest,
        context.deadline_ms) != 0 ||
      publish_blob(config_file, stage, "config.json", blob_root, config_digest,
        context.deadline_ms) != 0 ||
      publish_blob(image_file, stage, "image.manifest.json", blob_root, image_digest,
        context.deadline_ms) != 0) {
    close(config_file); close(image_file);
    output = json_message(0, "content-addressed OCI blob publication failed"); goto done;
  }
  close(config_file); close(image_file);
  close(layer); layer = -1;
  close(manifest_file); manifest_file = -1;
  if (cleanup_stage(staging_root, stage_name, stage) != 0) {
    stage = -1;
    output = json_message(0, "staging cleanup could not be verified"); goto done;
  }
  stage = -1;
  char result_json[4096];
  int result_len = snprintf(result_json, sizeof(result_json),
    "{\"workspace_digest\":\"%s\",\"image_ref\":\"%s@sha256:%s\",\"image_manifest_digest\":\"%s\",\"entry_count\":%d,\"total_bytes\":\"%lld\",\"staging_cleanup_verified\":true}",
    workspace_digest, repository, image_digest, image_digest,
    context.entry_count, (long long)context.total_bytes);
  if (result_len <= 0 || result_len >= (int)sizeof(result_json))
    output = json_message(0, "snapshot response encoding failed");
  else output = json_message(1, result_json);
done:
  if (layer >= 0) close(layer);
  if (manifest_file >= 0) close(manifest_file);
  if (blob_root >= 0) close(blob_root);
  if (stage >= 0) (void)cleanup_stage(staging_root, stage_name, stage);
  if (source >= 0) close(source);
  if (staging_root >= 0) close(staging_root);
  if (artifact_root >= 0) close(artifact_root);
  free(source_path); free(staging_path); free(artifact_path); free(repository); free(lease);
  return output ? output : json_message(0, "snapshot helper exhausted memory");
}

static int trusted_owner_mode(const struct stat *status, int directory) {
  uid_t uid = geteuid();
  if (status->st_uid != uid && status->st_uid != 0) return 0;
  if ((status->st_mode & (S_IRWXG | S_IRWXO)) != 0) return 0;
  return directory ? S_ISDIR(status->st_mode) : S_ISREG(status->st_mode);
}

MOONBIT_FFI_EXPORT
int32_t moonfort_aen_provisioner_write_lease(
  moonbit_bytes_t root_bytes, int32_t root_len,
  moonbit_bytes_t lease_bytes, int32_t lease_len,
  moonbit_bytes_t body, int32_t body_len
) {
  char *root_path = copy_input(root_bytes, root_len, 1);
  char *lease = copy_input(lease_bytes, lease_len, 0);
  if (!root_path || !lease || !safe_token(lease) || body_len <= 0 || body_len > 65536) {
    free(root_path); free(lease); return 1;
  }
  int root = open_absolute_directory(root_path);
  struct stat status;
  if (root < 0 || fstat(root, &status) != 0 || !trusted_owner_mode(&status, 1)) {
    if (root >= 0) close(root); free(root_path); free(lease); return 2;
  }
  char name[160]; snprintf(name, sizeof(name), "%s.json", lease);
  int file = openat(root, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
  int result = 0;
  if (file < 0 || write_all(file, body, (size_t)body_len) != 0 || fsync(file) != 0 || fsync(root) != 0) result = 3;
  if (file >= 0) close(file);
  if (result != 0) (void)unlinkat(root, name, 0);
  close(root); free(root_path); free(lease); return result;
}

MOONBIT_FFI_EXPORT
int32_t moonfort_aen_provisioner_release_lease(
  moonbit_bytes_t root_bytes, int32_t root_len,
  moonbit_bytes_t lease_bytes, int32_t lease_len
) {
  char *root_path = copy_input(root_bytes, root_len, 1);
  char *lease = copy_input(lease_bytes, lease_len, 0);
  if (!root_path || !lease || !safe_token(lease)) {
    free(root_path); free(lease); return 2;
  }
  int root = open_absolute_directory(root_path);
  if (root < 0) { free(root_path); free(lease); return 2; }
  char name[160]; snprintf(name, sizeof(name), "%s.json", lease);
  struct stat status;
  int result;
  if (fstatat(root, name, &status, AT_SYMLINK_NOFOLLOW) != 0) {
    result = errno == ENOENT ? 1 : 2;
  } else if (!S_ISREG(status.st_mode) || unlinkat(root, name, 0) != 0 || fsync(root) != 0) {
    result = 2;
  } else result = 0;
  close(root); free(root_path); free(lease); return result;
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t moonfort_aen_provisioner_read_protected_config(
  moonbit_bytes_t path_bytes, int32_t path_len, int32_t max_bytes
) {
  char *path = copy_input(path_bytes, path_len, 1);
  moonbit_bytes_t empty = moonbit_make_bytes(0, 0);
  if (!path || max_bytes <= 0 || max_bytes > 1048576) {
    free(path); return empty;
  }
  char *slash = strrchr(path, '/');
  if (!slash || !slash[1]) { free(path); return empty; }
  char *name = strdup(slash + 1);
  if (!name) { free(path); return empty; }
  if (slash == path) path[1] = 0; else *slash = 0;
  int parent = open_absolute_directory(path);
  struct stat before, opened, after;
  int file = -1;
  moonbit_bytes_t result = empty;
  if (parent >= 0 && fstatat(parent, name, &before, AT_SYMLINK_NOFOLLOW) == 0 &&
      trusted_owner_mode(&before, 0) && before.st_size > 0 &&
      before.st_size <= max_bytes) {
    file = openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (file >= 0 && fstat(file, &opened) == 0 &&
        fstatat(parent, name, &after, AT_SYMLINK_NOFOLLOW) == 0 &&
        stat_same(&before, &opened) && stat_same(&opened, &after)) {
      result = moonbit_make_bytes((int32_t)opened.st_size, 0);
      size_t used = 0;
      while (used < (size_t)opened.st_size) {
        ssize_t count = read(file, result + used, (size_t)opened.st_size - used);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { result = empty; break; }
        used += (size_t)count;
      }
      if (fstat(file, &after) != 0 || !stat_same(&opened, &after)) result = empty;
    }
  }
  if (file >= 0) close(file);
  if (parent >= 0) close(parent);
  free(name); free(path); return result;
}

MOONBIT_FFI_EXPORT
int32_t moonfort_aen_provisioner_test_make_fifo(
  moonbit_bytes_t path_bytes, int32_t path_len
) {
  char *path = copy_input(path_bytes, path_len, 1);
  if (!path) return 0;
  int result = mkfifo(path, 0600) == 0;
  free(path);
  return result;
}
