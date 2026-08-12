#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

static int outside_scratch(void) {
  const char *paths[] = { "/tmp/moonfort-escape", "/run/moonfort-escape", "/run/moonfort/escape", "/root/moonfort-escape", "/opt/moonfort/escape", "/sys/fs/cgroup/cgroup.procs" };
  for (size_t index = 0; index < sizeof(paths) / sizeof(paths[0]); ++index) {
    int descriptor = open(paths[index], O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (descriptor >= 0) { close(descriptor); return 90; }
  }
  const char *temporary = getenv("TMPDIR");
  if (!temporary) return 92;
  char allowed[4096]; int length = snprintf(allowed, sizeof(allowed), "%s/allowed", temporary);
  if (length <= 0 || (size_t)length >= sizeof(allowed)) return 93;
  int descriptor = open(allowed, O_WRONLY | O_CREAT | O_EXCL, 0600);
  if (descriptor < 0) return 94;
  close(descriptor);
  return 0;
}

static int inode_storm(void) {
  const char *temporary = getenv("TMPDIR");
  if (!temporary || (mkdir(temporary, 0700) != 0 && errno != EEXIST)) return 92;
  char path[4096];
  for (int index = 0; index < 100000; ++index) {
    int length = snprintf(path, sizeof(path), "%s/inode-%d", temporary, index);
    if (length <= 0 || (size_t)length >= sizeof(path)) return 93;
    int descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (descriptor < 0) return errno == ENOSPC ? 0 : 94;
    close(descriptor);
  }
  return 95;
}

static int deleted_open_allocation(void) {
  const char *temporary = getenv("TMPDIR");
  if (!temporary || (mkdir(temporary, 0700) != 0 && errno != EEXIST)) return 96;
  char path[4096]; int length = snprintf(path, sizeof(path), "%s/deleted-open", temporary);
  if (length <= 0 || (size_t)length >= sizeof(path)) return 97;
  int descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
  if (descriptor < 0 || unlink(path) != 0) return 98;
  static char block[65536];
  for (int index = 0; index < 2048; ++index) {
    ssize_t count = write(descriptor, block, sizeof(block));
    if (count < 0) { int result = errno == ENOSPC ? 0 : 99; close(descriptor); return result; }
    if ((size_t)count != sizeof(block)) { close(descriptor); return 0; }
  }
  close(descriptor); return 100;
}

int main(int argc, char **argv) {
  if (argc != 2) return 64;
  if (!strcmp(argv[1], "outside")) return outside_scratch();
  if (!strcmp(argv[1], "inode-storm")) return inode_storm();
  if (!strcmp(argv[1], "deleted-open")) return deleted_open_allocation();
  return 64;
}
