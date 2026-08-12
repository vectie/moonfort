#include "runtime.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static uint32_t rotate(uint32_t value, unsigned count) {
  return (value >> count) | (value << (32 - count));
}

static void transform(struct mf_sha256 *state) {
  static const uint32_t constants[64] = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
  };
  uint32_t schedule[64];
  for (int index = 0; index < 16; ++index) {
    const unsigned char *p = state->block + index * 4;
    schedule[index] = (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 |
      (uint32_t)p[2] << 8 | p[3];
  }
  for (int index = 16; index < 64; ++index) {
    uint32_t a = schedule[index - 15], b = schedule[index - 2];
    schedule[index] = schedule[index - 16] +
      (rotate(a, 7) ^ rotate(a, 18) ^ (a >> 3)) + schedule[index - 7] +
      (rotate(b, 17) ^ rotate(b, 19) ^ (b >> 10));
  }
  uint32_t a=state->words[0], b=state->words[1], c=state->words[2], d=state->words[3];
  uint32_t e=state->words[4], f=state->words[5], g=state->words[6], h=state->words[7];
  for (int index = 0; index < 64; ++index) {
    uint32_t s1=rotate(e,6)^rotate(e,11)^rotate(e,25);
    uint32_t choice=(e&f)^((~e)&g);
    uint32_t first=h+s1+choice+constants[index]+schedule[index];
    uint32_t s0=rotate(a,2)^rotate(a,13)^rotate(a,22);
    uint32_t majority=(a&b)^(a&c)^(b&c);
    uint32_t second=s0+majority;
    h=g; g=f; f=e; e=d+first; d=c; c=b; b=a; a=first+second;
  }
  state->words[0]+=a; state->words[1]+=b; state->words[2]+=c; state->words[3]+=d;
  state->words[4]+=e; state->words[5]+=f; state->words[6]+=g; state->words[7]+=h;
}

void mf_sha256_init(struct mf_sha256 *state) {
  static const uint32_t initial[8] = {
    0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
    0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19
  };
  memcpy(state->words, initial, sizeof(initial));
  state->bytes = 0; state->used = 0;
}

void mf_sha256_update(struct mf_sha256 *state, const void *input, size_t length) {
  const unsigned char *cursor = input;
  state->bytes += length;
  while (length) {
    size_t available = sizeof(state->block) - state->used;
    size_t take = length < available ? length : available;
    memcpy(state->block + state->used, cursor, take);
    state->used += take; cursor += take; length -= take;
    if (state->used == sizeof(state->block)) { transform(state); state->used = 0; }
  }
}

void mf_sha256_finish(struct mf_sha256 *state, unsigned char output[32]) {
  uint64_t bits = state->bytes * 8;
  state->block[state->used++] = 0x80;
  if (state->used > 56) {
    memset(state->block + state->used, 0, 64 - state->used); transform(state); state->used = 0;
  }
  memset(state->block + state->used, 0, 56 - state->used);
  for (int index = 0; index < 8; ++index) state->block[63-index] = (unsigned char)(bits >> (index*8));
  transform(state);
  for (int index = 0; index < 8; ++index) {
    output[index*4]=(unsigned char)(state->words[index]>>24);
    output[index*4+1]=(unsigned char)(state->words[index]>>16);
    output[index*4+2]=(unsigned char)(state->words[index]>>8);
    output[index*4+3]=(unsigned char)state->words[index];
  }
}

void mf_hex(const unsigned char *input, size_t length, char *output) {
  static const char alphabet[] = "0123456789abcdef";
  for (size_t index = 0; index < length; ++index) {
    output[index*2] = alphabet[input[index] >> 4]; output[index*2+1] = alphabet[input[index] & 15];
  }
  output[length*2] = 0;
}

int mf_write_all(int descriptor, const void *data, size_t length) {
  const unsigned char *cursor = data;
  while (length) {
    ssize_t count = write(descriptor, cursor, length);
    if (count < 0) { if (errno == EINTR) continue; return -1; }
    if (count == 0) return -1;
    cursor += count; length -= (size_t)count;
  }
  return 0;
}

int mf_hash_fd(int descriptor, char output[MF_SHA256_HEX], off_t expected_size) {
  struct mf_sha256 hash; mf_sha256_init(&hash);
  unsigned char buffer[65536]; off_t observed = 0;
  if (lseek(descriptor, 0, SEEK_SET) < 0) return -1;
  for (;;) {
    ssize_t count = read(descriptor, buffer, sizeof(buffer));
    if (count < 0) { if (errno == EINTR) continue; return -1; }
    if (!count) break;
    observed += count; if (expected_size >= 0 && observed > expected_size) return -1;
    mf_sha256_update(&hash, buffer, (size_t)count);
  }
  if (expected_size >= 0 && observed != expected_size) return -1;
  unsigned char raw[32]; mf_sha256_finish(&hash, raw); mf_hex(raw, 32, output);
  return 0;
}

int mf_hash_regular_path(const char *path, char output[MF_SHA256_HEX], off_t *size) {
  struct stat before, opened, after;
  if (lstat(path, &before) || !S_ISREG(before.st_mode)) return -1;
  int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (fd < 0 || fstat(fd, &opened) || !S_ISREG(opened.st_mode) ||
      before.st_dev != opened.st_dev || before.st_ino != opened.st_ino || before.st_size != opened.st_size) {
    if (fd >= 0) close(fd);
    return -1;
  }
  int result = mf_hash_fd(fd, output, opened.st_size);
  if (fstat(fd, &after) || after.st_dev != opened.st_dev || after.st_ino != opened.st_ino ||
      after.st_size != opened.st_size) result = -1;
  close(fd); if (!result && size) *size = opened.st_size; return result;
}

int mf_hash_self(char output[MF_SHA256_HEX]) {
  return mf_hash_regular_path("/proc/self/exe", output, NULL);
}

int mf_valid_digest(const char *value) {
  if (!value || strlen(value) != 64) return 0;
  for (int i=0;i<64;++i) if (!((value[i]>='0'&&value[i]<='9')||(value[i]>='a'&&value[i]<='f'))) return 0;
  return 1;
}

int mf_valid_token(const char *value, size_t maximum) {
  size_t length = value ? strlen(value) : 0;
  if (!length || length > maximum) return 0;
  for (size_t i=0;i<length;++i) {
    unsigned char c=(unsigned char)value[i];
    if (!((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='-'||c=='_'||c=='.'||c==':')) return 0;
  }
  return 1;
}

int mf_canonical_absolute(const char *value) {
  if (!value || value[0] != '/' || !value[1] || strlen(value) >= MF_PATH_MAX || strstr(value,"//")) return 0;
  size_t length=strlen(value); if (value[length-1]=='/') return 0;
  const char *cursor=value+1;
  while (*cursor) {
    const char *slash=strchr(cursor,'/'); size_t n=slash?(size_t)(slash-cursor):strlen(cursor);
    if (!n || (n==1&&cursor[0]=='.') || (n==2&&cursor[0]=='.'&&cursor[1]=='.')) return 0;
    cursor=slash?slash+1:cursor+n;
  }
  return 1;
}

int mf_join_path(char *output, size_t capacity, const char *left, const char *right) {
  if (!output || !capacity || !left || !right || !*left || !*right || strchr(right, '/')) return -1;
  size_t left_length = strlen(left), right_length = strlen(right);
  if (left_length > capacity - 1 || right_length > capacity - left_length - 2) return -1;
  memcpy(output, left, left_length);
  output[left_length] = '/';
  memcpy(output + left_length + 1, right, right_length + 1);
  return 0;
}

int mf_write_text_file(const char *path, const char *text, mode_t mode, int exclusive) {
  int flags=O_WRONLY|O_CREAT|O_CLOEXEC|O_NOFOLLOW|(exclusive?O_EXCL:O_TRUNC);
  int fd=open(path,flags,mode); if(fd<0)return -1;
  int result=mf_write_all(fd,text,strlen(text)); if(!result&&fsync(fd))result=-1; if(close(fd))result=-1; return result;
}

int mf_read_text_file(const char *path, char *output, size_t capacity) {
  int fd=open(path,O_RDONLY|O_CLOEXEC|O_NOFOLLOW); if(fd<0)return -1;
  struct stat status; if(fstat(fd,&status)||!S_ISREG(status.st_mode)||status.st_size<0||(size_t)status.st_size>=capacity){close(fd);return -1;}
  size_t used=0; while(used<(size_t)status.st_size){ssize_t n=read(fd,output+used,(size_t)status.st_size-used);if(n<0&&errno==EINTR)continue;if(n<=0){close(fd);return -1;}used+=(size_t)n;}
  output[used]=0; close(fd); return (int)used;
}

int64_t mf_monotonic_ms(void) {
  struct timespec now; if(clock_gettime(CLOCK_MONOTONIC,&now))return INT64_MAX;
  return (int64_t)now.tv_sec*1000+now.tv_nsec/1000000;
}

void mf_json_string(int descriptor, const char *value) {
  mf_write_all(descriptor,"\"",1);
  for (const unsigned char *p=(const unsigned char *)value;*p;++p) {
    char escaped[7]; size_t length=1;
    if(*p=='\"'||*p=='\\'){escaped[0]='\\';escaped[1]=(char)*p;length=2;}
    else if(*p=='\n'||*p=='\r'||*p=='\t'){escaped[0]='\\';escaped[1]=*p=='\n'?'n':*p=='\r'?'r':'t';length=2;}
    else if(*p<0x20){snprintf(escaped,sizeof(escaped),"\\u%04x",*p);length=6;}
    else escaped[0]=(char)*p;
    mf_write_all(descriptor,escaped,length);
  }
  mf_write_all(descriptor,"\"",1);
}

void mf_die(const char *message) {
  mf_write_all(STDERR_FILENO,"moonfort guest helper refused: ",31);
  mf_write_all(STDERR_FILENO,message,strlen(message)); mf_write_all(STDERR_FILENO,"\n",1); _exit(125);
}
