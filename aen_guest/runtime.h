#ifndef MOONFORT_AEN_GUEST_RUNTIME_H
#define MOONFORT_AEN_GUEST_RUNTIME_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#define MF_SHA256_HEX 65
#define MF_PATH_MAX 4096

struct mf_sha256 {
  uint32_t words[8];
  uint64_t bytes;
  unsigned char block[64];
  size_t used;
};

void mf_sha256_init(struct mf_sha256 *state);
void mf_sha256_update(struct mf_sha256 *state, const void *data, size_t length);
void mf_sha256_finish(struct mf_sha256 *state, unsigned char output[32]);
void mf_hex(const unsigned char *input, size_t length, char *output);
int mf_hash_fd(int descriptor, char output[MF_SHA256_HEX], off_t expected_size);
int mf_hash_regular_path(const char *path, char output[MF_SHA256_HEX], off_t *size);
int mf_hash_self(char output[MF_SHA256_HEX]);
int mf_valid_digest(const char *value);
int mf_valid_token(const char *value, size_t maximum);
int mf_canonical_absolute(const char *value);
int mf_join_path(char *output, size_t capacity, const char *left, const char *right);
int mf_write_all(int descriptor, const void *data, size_t length);
int mf_write_text_file(const char *path, const char *text, mode_t mode, int exclusive);
int mf_read_text_file(const char *path, char *output, size_t capacity);
int64_t mf_monotonic_ms(void);
void mf_json_string(int descriptor, const char *value);
void mf_die(const char *message);

#endif
