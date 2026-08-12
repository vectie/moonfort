#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE 1

#include <moonbit.h>

#include <errno.h>
#include <dirent.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifdef __APPLE__
#include <libproc.h>
#include <mach-o/dyld.h>
#include <sys/proc_info.h>
#endif

extern char **environ;

MOONBIT_FFI_EXPORT
int32_t moonfort_local_supervisor_test_platform(void) {
#if defined(__APPLE__)
  return 1;
#elif defined(__linux__)
  return 2;
#else
  return 0;
#endif
}

enum setup_stage {
  STAGE_NONE = 0,
  STAGE_SESSION,
  STAGE_CWD,
  STAGE_CPU,
  STAGE_AS,
  STAGE_FSIZE,
  STAGE_NOFILE,
  STAGE_EXEC,
  STAGE_PROTOCOL,
  STAGE_FORK,
  STAGE_CLOCK,
  STAGE_SIGNAL,
  STAGE_OUTPUT
};

enum applied_limit {
  APPLIED_CPU = 1 << 0,
  APPLIED_AS = 1 << 1,
  APPLIED_FSIZE = 1 << 2,
  APPLIED_NOFILE = 1 << 3,
  APPLIED_DISK_MONITOR = 1 << 4,
  APPLIED_PROCESS_MONITOR = 1 << 5
};

struct setup_error {
  int32_t stage;
  int32_t error_number;
  int32_t applied_limits;
};

static atomic_flag supervisor_busy = ATOMIC_FLAG_INIT;
static volatile sig_atomic_t active_child = -1;
static volatile sig_atomic_t received_signal = 0;

static int64_t monotonic_ms(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return -1;
  return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static void sleep_ms(int64_t millis) {
  if (millis <= 0) return;
  struct timespec delay = {
    .tv_sec = (time_t)(millis / 1000),
    .tv_nsec = (long)((millis % 1000) * 1000000)
  };
  while (nanosleep(&delay, &delay) != 0 && errno == EINTR) {}
}

static const char *stage_name(int stage) {
  switch (stage) {
    case STAGE_SESSION: return "session";
    case STAGE_CWD: return "cwd";
    case STAGE_CPU: return "rlimit_cpu";
    case STAGE_AS: return "rlimit_as";
    case STAGE_FSIZE: return "rlimit_fsize";
    case STAGE_NOFILE: return "rlimit_nofile";
    case STAGE_EXEC: return "exec";
    case STAGE_PROTOCOL: return "protocol";
    case STAGE_FORK: return "fork";
    case STAGE_CLOCK: return "clock";
    case STAGE_SIGNAL: return "signal_handlers";
    case STAGE_OUTPUT: return "output";
    default: return "unknown";
  }
}

static moonbit_bytes_t make_result(
  const char *kind,
  int exit_code,
  int signal_number,
  const char *limit,
  int setup_stage,
  int error_number,
  int64_t elapsed_ms,
  int applied_limits
) {
  char json[768];
  char exit_field[48] = "";
  char signal_field[48] = "";
  char limit_field[80] = "";
  char stage_field[112] = "";
  char errno_field[48] = "";
  if (exit_code >= 0) {
    snprintf(exit_field, sizeof(exit_field), ",\"exit_code\":%d", exit_code);
  }
  if (signal_number > 0) {
    snprintf(signal_field, sizeof(signal_field), ",\"signal\":%d", signal_number);
  }
  if (limit != NULL) {
    snprintf(limit_field, sizeof(limit_field), ",\"limit\":\"%s\"", limit);
  }
  if (setup_stage != STAGE_NONE) {
    snprintf(
      stage_field,
      sizeof(stage_field),
      ",\"setup_stage\":\"%s\"",
      stage_name(setup_stage)
    );
  }
  if (error_number > 0) {
    snprintf(errno_field, sizeof(errno_field), ",\"os_errno\":%d", error_number);
  }
  int length = snprintf(
    json,
    sizeof(json),
    "{\"kind\":\"%s\"%s%s%s%s%s,\"elapsed_ms\":\"%lld\",\"applied_limits\":%d}",
    kind,
    exit_field,
    signal_field,
    limit_field,
    stage_field,
    errno_field,
    (long long)elapsed_ms,
    applied_limits
  );
  if (length < 0) length = 0;
  if ((size_t)length >= sizeof(json)) length = (int)sizeof(json) - 1;
  moonbit_bytes_t result = moonbit_make_bytes(length, 0);
  memcpy(result, json, (size_t)length);
  return result;
}

static moonbit_bytes_t finish_result(
  const char *kind,
  int exit_code,
  int signal_number,
  const char *limit,
  int setup_stage,
  int error_number,
  int64_t elapsed_ms,
  int applied_limits
) {
  moonbit_bytes_t result = make_result(
    kind,
    exit_code,
    signal_number,
    limit,
    setup_stage,
    error_number,
    elapsed_ms,
    applied_limits
  );
  atomic_flag_clear(&supervisor_busy);
  return result;
}

static char **decode_nul_list(
  const unsigned char *blob,
  int32_t blob_len,
  int32_t count
) {
  if (blob_len < 0 || count < 0) {
    errno = EINVAL;
    return NULL;
  }
  char **list = calloc((size_t)count + 1, sizeof(char *));
  if (list == NULL) return NULL;
  int32_t offset = 0;
  for (int32_t index = 0; index < count; ++index) {
    if (offset >= blob_len) goto invalid;
    const unsigned char *end = memchr(blob + offset, 0, (size_t)(blob_len - offset));
    if (end == NULL) goto invalid;
    list[index] = (char *)(blob + offset);
    offset = (int32_t)(end - blob) + 1;
  }
  if (offset != blob_len) goto invalid;
  return list;

invalid:
  free(list);
  errno = EINVAL;
  return NULL;
}

static char *copy_c_string(const unsigned char *bytes, int32_t length) {
  if (length < 0 || memchr(bytes, 0, (size_t)length) != NULL) {
    errno = EINVAL;
    return NULL;
  }
  char *result = malloc((size_t)length + 1);
  if (result == NULL) return NULL;
  memcpy(result, bytes, (size_t)length);
  result[length] = 0;
  return result;
}

static int install_limit(int resource, uint64_t requested) {
  struct rlimit current;
  if (getrlimit(resource, &current) != 0) return -1;
  rlim_t value = (rlim_t)requested;
  if (current.rlim_max != RLIM_INFINITY && value > current.rlim_max) {
    value = current.rlim_max;
  }
  if (value == 0) {
    errno = EINVAL;
    return -1;
  }
  struct rlimit limit = { .rlim_cur = value, .rlim_max = value };
  return setrlimit(resource, &limit);
}

static int install_cpu_limit(uint64_t requested) {
  struct rlimit current;
  if (getrlimit(RLIMIT_CPU, &current) != 0) return -1;
  rlim_t soft = (rlim_t)requested;
  rlim_t hard = soft < RLIM_INFINITY - 1 ? soft + 1 : soft;
  if (current.rlim_max != RLIM_INFINITY && hard > current.rlim_max) {
    hard = current.rlim_max;
  }
  if (soft > hard) soft = hard;
  if (soft == 0) {
    errno = EINVAL;
    return -1;
  }
  struct rlimit limit = { .rlim_cur = soft, .rlim_max = hard };
  return setrlimit(RLIMIT_CPU, &limit);
}

static void child_fail(int fd, int stage, int applied_limits) {
  struct setup_error failure = { stage, errno, applied_limits };
  const unsigned char *cursor = (const unsigned char *)&failure;
  size_t remaining = sizeof(failure);
  while (remaining > 0) {
    ssize_t written = write(fd, cursor, remaining);
    if (written > 0) {
      cursor += written;
      remaining -= (size_t)written;
    } else if (written < 0 && errno == EINTR) {
      continue;
    } else {
      break;
    }
  }
  _exit(126);
}

static void kill_group(pid_t leader, int signal_number) {
  if (leader <= 0) return;
  (void)kill(-leader, signal_number);
  (void)kill(leader, signal_number);
}

static int open_scanned_directory(int parent, const char *name) {
  struct stat before;
  if (fstatat(parent, name, &before, AT_SYMLINK_NOFOLLOW) != 0 ||
      !S_ISDIR(before.st_mode)) {
    errno = ENOTDIR;
    return -1;
  }
  int child = openat(
    parent,
    name,
    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
  );
  if (child < 0) return -1;
  struct stat opened;
  struct stat after;
  if (fstat(child, &opened) != 0 ||
      fstatat(parent, name, &after, AT_SYMLINK_NOFOLLOW) != 0 ||
      !S_ISDIR(after.st_mode) || before.st_dev != opened.st_dev ||
      before.st_ino != opened.st_ino || after.st_dev != opened.st_dev ||
      after.st_ino != opened.st_ino) {
    close(child);
    errno = ESTALE;
    return -1;
  }
  return child;
}

/* Returns 0 below limits, 1 over byte limit, 2 over entry limit, or -1 when
 * concurrent mutation prevents a trustworthy observation. Symlinks are never
 * followed. */
static int scan_disk_usage(
  int directory,
  uint64_t byte_limit,
  uint64_t entry_limit,
  uint64_t *bytes,
  uint64_t *entries
) {
  int stream_fd = dup(directory);
  if (stream_fd < 0) return -1;
  DIR *stream = fdopendir(stream_fd);
  if (stream == NULL) {
    close(stream_fd);
    return -1;
  }
  int result = 0;
  for (;;) {
    errno = 0;
    struct dirent *entry = readdir(stream);
    if (entry == NULL) {
      if (errno != 0) result = -1;
      break;
    }
    if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
      continue;
    }
    *entries += 1;
    if (*entries > entry_limit) {
      result = 2;
      break;
    }
    struct stat status;
    if (fstatat(directory, entry->d_name, &status, AT_SYMLINK_NOFOLLOW) != 0) {
      result = -1;
      break;
    }
    if (S_ISREG(status.st_mode)) {
      if (status.st_size < 0 || (uint64_t)status.st_size > byte_limit - *bytes) {
        result = 1;
        break;
      }
      *bytes += (uint64_t)status.st_size;
    } else if (S_ISDIR(status.st_mode)) {
      int child = open_scanned_directory(directory, entry->d_name);
      if (child < 0) {
        result = -1;
        break;
      }
      result = scan_disk_usage(
        child, byte_limit, entry_limit, bytes, entries
      );
      close(child);
      if (result != 0) break;
    } else if (!S_ISLNK(status.st_mode)) {
      result = -1;
      break;
    }
  }
  closedir(stream);
  return result;
}

static int open_monitored_root(const char *path) {
  if (path == NULL || path[0] != '/') {
    errno = EINVAL;
    return -1;
  }
  int current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (current < 0) return -1;
  if (path[1] == 0) return current;
  char *copy = strdup(path + 1);
  if (copy == NULL) {
    close(current);
    return -1;
  }
  char *state = NULL;
  for (char *component = strtok_r(copy, "/", &state);
       component != NULL;
       component = strtok_r(NULL, "/", &state)) {
    if (strcmp(component, ".") == 0 || strcmp(component, "..") == 0) {
      free(copy);
      close(current);
      errno = EINVAL;
      return -1;
    }
    int next = open_scanned_directory(current, component);
    if (next < 0) {
      free(copy);
      close(current);
      return -1;
    }
    close(current);
    current = next;
  }
  free(copy);
  return current;
}

static int scan_disk_path(
  const char *path,
  uint64_t byte_limit,
  uint64_t entry_limit
) {
  int root = open_monitored_root(path);
  if (root < 0) return -1;
  uint64_t bytes = 0;
  uint64_t entries = 0;
  int result = scan_disk_usage(
    root, byte_limit, entry_limit, &bytes, &entries
  );
  close(root);
  return result;
}

#ifdef __linux__
struct linux_process {
  pid_t pid;
  pid_t parent;
};

static int compare_linux_process(const void *left, const void *right) {
  const struct linux_process *a = left;
  const struct linux_process *b = right;
  return a->pid < b->pid ? -1 : (a->pid > b->pid ? 1 : 0);
}
#endif

static int group_process_count(pid_t leader) {
#ifdef __APPLE__
  int required = proc_listpids(PROC_PGRP_ONLY, (uint32_t)leader, NULL, 0);
  if (required < 0) return -1;
  if (required == 0) return 0;
  int capacity = required + 64 * (int)sizeof(pid_t);
  for (int attempt = 0; attempt < 4 && capacity <= 4 * 1024 * 1024; ++attempt) {
    pid_t *pids = malloc((size_t)capacity);
    if (pids == NULL) return -1;
    int received = proc_listpids(
      PROC_PGRP_ONLY, (uint32_t)leader, pids, capacity
    );
    if (received < 0) {
      free(pids);
      return -1;
    }
    if (received < capacity) {
      int count = 0;
      int slots = received / (int)sizeof(pid_t);
      for (int index = 0; index < slots; ++index) {
        if (pids[index] > 0) count += 1;
      }
      free(pids);
      return count;
    }
    free(pids);
    capacity *= 2;
  }
  return -1;
#elif defined(__linux__)
  DIR *proc = opendir("/proc");
  if (proc == NULL) return -1;
  size_t count = 0;
  size_t capacity = 256;
  struct linux_process *processes = calloc(capacity, sizeof(*processes));
  if (processes == NULL) {
    closedir(proc);
    return -1;
  }
  int failed = 0;
  for (;;) {
    errno = 0;
    struct dirent *entry = readdir(proc);
    if (entry == NULL) {
      if (errno != 0) failed = 1;
      break;
    }
    char *end = NULL;
    errno = 0;
    long parsed_pid = strtol(entry->d_name, &end, 10);
    if (errno != 0 || end == entry->d_name || *end != 0 || parsed_pid <= 0) {
      continue;
    }
    char path[64];
    if (snprintf(path, sizeof(path), "/proc/%ld/stat", parsed_pid) >=
        (int)sizeof(path)) {
      continue;
    }
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) {
      if (errno == ENOENT || errno == ESRCH) continue;
      failed = 1;
      break;
    }
    char stat_line[4096];
    ssize_t length = read(fd, stat_line, sizeof(stat_line) - 1);
    int saved = errno;
    close(fd);
    if (length <= 0) {
      if (length < 0 && (saved == ENOENT || saved == ESRCH)) continue;
      failed = 1;
      break;
    }
    stat_line[length] = 0;
    char *closing = strrchr(stat_line, ')');
    char state = 0;
    long parent = 0;
    long group = 0;
    if (closing == NULL ||
        sscanf(closing + 1, " %c %ld %ld", &state, &parent, &group) != 3 ||
        parent < 0) {
      failed = 1;
      break;
    }
    if (count == capacity) {
      if (capacity >= 4 * 1024 * 1024 / sizeof(*processes)) {
        failed = 1;
        break;
      }
      size_t next_capacity = capacity * 2;
      struct linux_process *grown = realloc(
        processes, next_capacity * sizeof(*processes)
      );
      if (grown == NULL) {
        failed = 1;
        break;
      }
      processes = grown;
      capacity = next_capacity;
    }
    processes[count].pid = (pid_t)parsed_pid;
    processes[count].parent = (pid_t)parent;
    count += 1;
  }
  closedir(proc);
  if (failed) {
    free(processes);
    return -1;
  }
  qsort(processes, count, sizeof(*processes), compare_linux_process);
  int descendants = 0;
  for (size_t index = 0; index < count; ++index) {
    pid_t cursor = processes[index].pid;
    for (size_t depth = 0; depth <= count && cursor > 0; ++depth) {
      if (cursor == leader) {
        descendants += 1;
        break;
      }
      struct linux_process key = { .pid = cursor, .parent = 0 };
      struct linux_process *found = bsearch(
        &key, processes, count, sizeof(*processes), compare_linux_process
      );
      if (found == NULL || found->parent == cursor) break;
      cursor = found->parent;
    }
  }
  free(processes);
  return descendants;
#else
  (void)leader;
  return -1;
#endif
}

static int make_pipe_cloexec(int descriptors[2]) {
  if (pipe(descriptors) != 0) return -1;
  for (int index = 0; index < 2; ++index) {
    int flags = fcntl(descriptors[index], F_GETFD);
    if (flags < 0 || fcntl(descriptors[index], F_SETFD, flags | FD_CLOEXEC) != 0) {
      int saved = errno;
      close(descriptors[0]);
      close(descriptors[1]);
      errno = saved;
      return -1;
    }
  }
  return 0;
}

static void close_target_fds(long ceiling) {
  if (ceiling < 0) ceiling = 65536;
  /* fd 3 is the CLOEXEC setup channel; the target receives only 0, 1, and 2. */
  for (int fd = 4; fd < ceiling; ++fd) (void)close(fd);
}

static void forward_signal(int signal_number) {
  pid_t leader = (pid_t)active_child;
  received_signal = signal_number;
  if (leader > 0) kill_group(leader, signal_number);
}

static int install_handlers(struct sigaction old_actions[4]) {
  const int signals[4] = { SIGINT, SIGTERM, SIGHUP, SIGQUIT };
  struct sigaction action;
  memset(&action, 0, sizeof(action));
  action.sa_handler = forward_signal;
  sigemptyset(&action.sa_mask);
  for (int index = 0; index < 4; ++index) {
    if (sigaction(signals[index], &action, &old_actions[index]) != 0) {
      for (int previous = 0; previous < index; ++previous) {
        (void)sigaction(signals[previous], &old_actions[previous], NULL);
      }
      return -1;
    }
  }
  return 0;
}

static void restore_handlers(const struct sigaction old_actions[4]) {
  const int signals[4] = { SIGINT, SIGTERM, SIGHUP, SIGQUIT };
  for (int index = 0; index < 4; ++index) {
    (void)sigaction(signals[index], &old_actions[index], NULL);
  }
}

static int current_executable(char *buffer, size_t capacity) {
#ifdef __APPLE__
  uint32_t length = (uint32_t)capacity;
  if (_NSGetExecutablePath(buffer, &length) != 0) {
    errno = ENAMETOOLONG;
    return -1;
  }
  return 0;
#elif defined(__linux__)
  ssize_t length = readlink("/proc/self/exe", buffer, capacity - 1);
  if (length < 0 || (size_t)length >= capacity) {
    if (length >= 0) errno = ENAMETOOLONG;
    return -1;
  }
  buffer[length] = 0;
  return 0;
#else
  errno = ENOTSUP;
  return -1;
#endif
}

static int parse_worker_limit(const char *name, uint64_t *result) {
  const char *value = getenv(name);
  if (value == NULL || *value == 0) {
    errno = EINVAL;
    return -1;
  }
  errno = 0;
  char *end = NULL;
  unsigned long long parsed = strtoull(value, &end, 10);
  if (errno != 0 || end == value || *end != 0 || parsed == 0) {
    errno = EINVAL;
    return -1;
  }
  *result = (uint64_t)parsed;
  return 0;
}

static int worker_environment(char **source, char ***result) {
  size_t count = 0;
  while (source[count] != NULL) count += 1;
  char **filtered = calloc(count + 1, sizeof(char *));
  if (filtered == NULL) return -1;
  size_t kept = 0;
  for (size_t index = 0; index < count; ++index) {
    if (strncmp(source[index], "MOONFORT_SUPERVISOR_", 20) != 0) {
      filtered[kept++] = source[index];
    }
  }
  *result = filtered;
  return 0;
}

__attribute__((constructor))
static void moonfort_supervisor_worker(int argc, char **argv, char **envp) {
  const char *mode = getenv("MOONFORT_SUPERVISOR_WORKER");
  if (mode == NULL || strcmp(mode, "1") != 0) return;
  const int setup_fd = 3;
  (void)fcntl(setup_fd, F_SETFD, FD_CLOEXEC);
  long target_fd_ceiling = sysconf(_SC_OPEN_MAX);
  int applied = 0;
  uint64_t cpu = 0;
  uint64_t address_space = 0;
  uint64_t file_size = 0;
  uint64_t open_files_limit = 0;
  const char *cwd = getenv("MOONFORT_SUPERVISOR_CWD");
  if (argc < 2 || cwd == NULL) {
    errno = EINVAL;
    child_fail(setup_fd, STAGE_PROTOCOL, applied);
  }
  if (chdir(cwd) != 0) child_fail(setup_fd, STAGE_CWD, applied);
  if (parse_worker_limit("MOONFORT_SUPERVISOR_CPU", &cpu) != 0 ||
      install_cpu_limit(cpu) != 0) {
    child_fail(setup_fd, STAGE_CPU, applied);
  }
  applied |= APPLIED_CPU;
#ifdef RLIMIT_AS
  if (parse_worker_limit("MOONFORT_SUPERVISOR_AS", &address_space) != 0 ||
      install_limit(RLIMIT_AS, address_space) != 0) {
#ifdef __APPLE__
    /* MoonBit's native launcher can already reserve more virtual address
     * space than a low target ceiling. macOS rejects lowering RLIMIT_AS below
     * that reservation with EINVAL. The local backend reports this limit as
     * unverified instead of making every otherwise-confined run unavailable. */
    if (errno != EINVAL && errno != ENOTSUP) {
      child_fail(setup_fd, STAGE_AS, applied);
    }
#else
    child_fail(setup_fd, STAGE_AS, applied);
#endif
  } else {
    applied |= APPLIED_AS;
  }
#else
  errno = ENOTSUP;
  child_fail(setup_fd, STAGE_AS, applied);
#endif
  if (parse_worker_limit("MOONFORT_SUPERVISOR_FSIZE", &file_size) != 0 ||
      install_limit(RLIMIT_FSIZE, file_size) != 0) {
    child_fail(setup_fd, STAGE_FSIZE, applied);
  }
  applied |= APPLIED_FSIZE;
  if (parse_worker_limit("MOONFORT_SUPERVISOR_NOFILE", &open_files_limit) != 0 ||
      install_limit(RLIMIT_NOFILE, open_files_limit) != 0) {
    child_fail(setup_fd, STAGE_NOFILE, applied);
  }
  applied |= APPLIED_NOFILE;
  char **target_environment = NULL;
  if (worker_environment(envp, &target_environment) != 0) {
    child_fail(setup_fd, STAGE_PROTOCOL, applied);
  }
  close_target_fds(target_fd_ceiling);
  execve(argv[1], &argv[1], target_environment);
  child_fail(setup_fd, STAGE_EXEC, applied);
}

static int write_all(int fd, const unsigned char *bytes, size_t length) {
  while (length > 0) {
    ssize_t written = write(fd, bytes, length);
    if (written > 0) {
      bytes += written;
      length -= (size_t)written;
    } else if (written < 0 && errno == EINTR) {
      continue;
    } else {
      return -1;
    }
  }
  return 0;
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t moonfort_local_supervisor_run(
  moonbit_bytes_t argv_blob,
  int32_t argv_blob_len,
  int32_t argc,
  moonbit_bytes_t env_blob,
  int32_t env_blob_len,
  int32_t envc,
  moonbit_bytes_t cwd,
  int32_t cwd_len,
  moonbit_bytes_t output_path,
  int32_t output_path_len,
  moonbit_bytes_t disk_root,
  int32_t disk_root_len,
  int64_t output_bytes,
  int64_t wall_clock_ms,
  int64_t cpu_seconds,
  int64_t address_space_bytes,
  int64_t file_size_bytes,
  int64_t open_files,
  int64_t processes,
  int64_t aggregate_disk_bytes
) {
  if (atomic_flag_test_and_set(&supervisor_busy)) {
    return make_result("setup_failed", -1, 0, NULL, STAGE_PROTOCOL, EBUSY, 0, 0);
  }
  int64_t started = monotonic_ms();
  if (started < 0) {
    return finish_result("setup_failed", -1, 0, NULL, STAGE_CLOCK, errno, 0, 0);
  }
  if (output_bytes <= 0 || wall_clock_ms <= 0 || processes <= 0 ||
      aggregate_disk_bytes <= 0 || disk_root_len < 0) {
    return finish_result("setup_failed", -1, 0, NULL, STAGE_PROTOCOL, EINVAL, 0, 0);
  }
  const char *disk_root_c = (const char *)disk_root;
  int disk_monitor_enabled = disk_root_len > 0;
  if (disk_monitor_enabled &&
      (disk_root_c[0] != '/' ||
       memchr(disk_root_c, 0, (size_t)disk_root_len) != NULL)) {
    return finish_result(
      "setup_failed", -1, 0, NULL, STAGE_PROTOCOL, EINVAL, 0, 0
    );
  }
  for (int fd = STDIN_FILENO; fd <= STDERR_FILENO; ++fd) {
    if (fcntl(fd, F_GETFD) < 0) {
      int saved = errno;
      return finish_result(
        "setup_failed", -1, 0, NULL, STAGE_PROTOCOL, saved, 0, 0
      );
    }
  }

  char **argv = decode_nul_list(argv_blob, argv_blob_len, argc);
  if (argv == NULL || argc == 0 || argv[0][0] != '/') {
    int saved = errno != 0 ? errno : EINVAL;
    free(argv);
    return finish_result("setup_failed", -1, 0, NULL, STAGE_PROTOCOL, saved, 0, 0);
  }
  char **envp = decode_nul_list(env_blob, env_blob_len, envc);
  if (envp == NULL) {
    int saved = errno != 0 ? errno : EINVAL;
    free(argv);
    return finish_result("setup_failed", -1, 0, NULL, STAGE_PROTOCOL, saved, 0, 0);
  }
  char *cwd_c = copy_c_string(cwd, cwd_len);
  char *output_path_c = copy_c_string(output_path, output_path_len);
  if (cwd_c == NULL || output_path_c == NULL) {
    int saved = errno != 0 ? errno : EINVAL;
    free(argv);
    free(envp);
    free(cwd_c);
    free(output_path_c);
    return finish_result("setup_failed", -1, 0, NULL, STAGE_PROTOCOL, saved, 0, 0);
  }
  int output_fd = open(
    output_path_c,
    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
    0600
  );
  if (output_fd < 0) {
    int saved = errno;
    free(argv);
    free(envp);
    free(cwd_c);
    free(output_path_c);
    return finish_result("setup_failed", -1, 0, NULL, STAGE_OUTPUT, saved, 0, 0);
  }

  int setup_pipe[2];
  int output_pipe[2];
  if (make_pipe_cloexec(setup_pipe) != 0) {
    int saved = errno;
    close(output_fd);
    free(argv);
    free(envp);
    free(cwd_c);
    free(output_path_c);
    return finish_result("setup_failed", -1, 0, NULL, STAGE_FORK, saved, 0, 0);
  }
  if (make_pipe_cloexec(output_pipe) != 0) {
    int saved = errno;
    close(output_fd);
    close(setup_pipe[0]);
    close(setup_pipe[1]);
    free(argv);
    free(envp);
    free(cwd_c);
    free(output_path_c);
    return finish_result("setup_failed", -1, 0, NULL, STAGE_FORK, saved, 0, 0);
  }
  (void)fcntl(output_pipe[0], F_SETFL, fcntl(output_pipe[0], F_GETFL) | O_NONBLOCK);

  struct sigaction old_actions[4];
  if (install_handlers(old_actions) != 0) {
    int saved = errno;
    close(output_fd);
    close(setup_pipe[0]);
    close(setup_pipe[1]);
    close(output_pipe[0]);
    close(output_pipe[1]);
    free(argv);
    free(envp);
    free(cwd_c);
    free(output_path_c);
    return finish_result("setup_failed", -1, 0, NULL, STAGE_SIGNAL, saved, 0, 0);
  }

  char executable[4096];
  if (current_executable(executable, sizeof(executable)) != 0) {
    int saved = errno;
    restore_handlers(old_actions);
    close(output_fd);
    close(setup_pipe[0]);
    close(setup_pipe[1]);
    close(output_pipe[0]);
    close(output_pipe[1]);
    free(argv);
    free(envp);
    free(cwd_c);
    free(output_path_c);
    return finish_result("setup_failed", -1, 0, NULL, STAGE_EXEC, saved, 0, 0);
  }
  char **worker_argv = calloc((size_t)argc + 2, sizeof(char *));
  char **worker_env = calloc((size_t)envc + 7, sizeof(char *));
  if (worker_argv == NULL || worker_env == NULL) {
    int saved = errno;
    restore_handlers(old_actions);
    close(output_fd);
    close(setup_pipe[0]);
    close(setup_pipe[1]);
    close(output_pipe[0]);
    close(output_pipe[1]);
    free(argv);
    free(envp);
    free(cwd_c);
    free(output_path_c);
    free(worker_argv);
    free(worker_env);
    return finish_result("setup_failed", -1, 0, NULL, STAGE_FORK, saved, 0, 0);
  }
  worker_argv[0] = executable;
  for (int index = 0; index < argc; ++index) worker_argv[index + 1] = argv[index];
  char meta_cpu[96];
  char meta_as[96];
  char meta_fsize[96];
  char meta_nofile[96];
  char meta_cwd[4096];
  snprintf(meta_cpu, sizeof(meta_cpu), "MOONFORT_SUPERVISOR_CPU=%lld", (long long)cpu_seconds);
  snprintf(meta_as, sizeof(meta_as), "MOONFORT_SUPERVISOR_AS=%lld", (long long)address_space_bytes);
  snprintf(meta_fsize, sizeof(meta_fsize), "MOONFORT_SUPERVISOR_FSIZE=%lld", (long long)file_size_bytes);
  snprintf(meta_nofile, sizeof(meta_nofile), "MOONFORT_SUPERVISOR_NOFILE=%lld", (long long)open_files);
  if (snprintf(meta_cwd, sizeof(meta_cwd), "MOONFORT_SUPERVISOR_CWD=%s", cwd_c) >= (int)sizeof(meta_cwd)) {
    restore_handlers(old_actions);
    close(output_fd);
    close(setup_pipe[0]);
    close(setup_pipe[1]);
    close(output_pipe[0]);
    close(output_pipe[1]);
    free(argv);
    free(envp);
    free(cwd_c);
    free(output_path_c);
    free(worker_argv);
    free(worker_env);
    return finish_result("setup_failed", -1, 0, NULL, STAGE_PROTOCOL, ENAMETOOLONG, 0, 0);
  }
  for (int index = 0; index < envc; ++index) worker_env[index] = envp[index];
  worker_env[envc] = "MOONFORT_SUPERVISOR_WORKER=1";
  worker_env[envc + 1] = meta_cpu;
  worker_env[envc + 2] = meta_as;
  worker_env[envc + 3] = meta_fsize;
  worker_env[envc + 4] = meta_nofile;
  worker_env[envc + 5] = meta_cwd;

  posix_spawn_file_actions_t actions;
  posix_spawnattr_t attributes;
  int actions_initialized = 0;
  int attributes_initialized = 0;
  int spawn_setup_error = posix_spawn_file_actions_init(&actions);
  if (spawn_setup_error == 0) actions_initialized = 1;
  if (spawn_setup_error == 0) spawn_setup_error = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
  if (spawn_setup_error == 0) spawn_setup_error = posix_spawn_file_actions_adddup2(&actions, output_pipe[1], STDOUT_FILENO);
  if (spawn_setup_error == 0) spawn_setup_error = posix_spawn_file_actions_adddup2(&actions, output_pipe[1], STDERR_FILENO);
  if (spawn_setup_error == 0) spawn_setup_error = posix_spawn_file_actions_addclose(&actions, output_fd);
  if (spawn_setup_error == 0) spawn_setup_error = posix_spawn_file_actions_adddup2(&actions, setup_pipe[1], 3);
  if (spawn_setup_error == 0) spawn_setup_error = posix_spawn_file_actions_addclose(&actions, output_pipe[0]);
  if (spawn_setup_error == 0) spawn_setup_error = posix_spawn_file_actions_addclose(&actions, setup_pipe[0]);
  if (spawn_setup_error == 0) spawn_setup_error = posix_spawn_file_actions_addclose(&actions, output_pipe[1]);
  if (spawn_setup_error == 0) spawn_setup_error = posix_spawn_file_actions_addclose(&actions, setup_pipe[1]);
  if (spawn_setup_error == 0) spawn_setup_error = posix_spawnattr_init(&attributes);
  if (spawn_setup_error == 0) attributes_initialized = 1;
  sigset_t empty_mask;
  sigset_t default_signals;
  sigemptyset(&empty_mask);
  sigfillset(&default_signals);
  if (spawn_setup_error == 0) spawn_setup_error = posix_spawnattr_setsigmask(&attributes, &empty_mask);
  if (spawn_setup_error == 0) spawn_setup_error = posix_spawnattr_setsigdefault(&attributes, &default_signals);
  short spawn_flags = POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF;
#ifdef POSIX_SPAWN_SETSID
  spawn_flags |= POSIX_SPAWN_SETSID;
#else
  spawn_flags |= POSIX_SPAWN_SETPGROUP;
  if (spawn_setup_error == 0) spawn_setup_error = posix_spawnattr_setpgroup(&attributes, 0);
#endif
  if (spawn_setup_error == 0) spawn_setup_error = posix_spawnattr_setflags(&attributes, spawn_flags);
  received_signal = 0;
  pid_t child = -1;
  int spawn_error = spawn_setup_error;
  if (spawn_error == 0) {
    spawn_error = posix_spawn(
      &child,
      executable,
      &actions,
      &attributes,
      worker_argv,
      worker_env
    );
  }
  if (actions_initialized) posix_spawn_file_actions_destroy(&actions);
  if (attributes_initialized) posix_spawnattr_destroy(&attributes);
  free(worker_argv);
  free(worker_env);
  if (spawn_error != 0) {
    restore_handlers(old_actions);
    close(output_fd);
    close(setup_pipe[0]);
    close(setup_pipe[1]);
    close(output_pipe[0]);
    close(output_pipe[1]);
    free(argv);
    free(envp);
    free(cwd_c);
    free(output_path_c);
    return finish_result("setup_failed", -1, 0, NULL, STAGE_FORK, spawn_error, 0, 0);
  }

  active_child = (sig_atomic_t)child;
  close(setup_pipe[1]);
  close(output_pipe[1]);
  free(argv);
  free(envp);
  free(cwd_c);
  free(output_path_c);
  if (received_signal != 0) kill_group(child, received_signal);

  int setup_eof = 0;
  int output_eof = 0;
  int child_reaped = 0;
  int group_killed = 0;
  int timed_out = 0;
  int output_exceeded = 0;
  int disk_exceeded = 0;
  int disk_entries_exceeded = 0;
  int process_exceeded = 0;
  const char *monitor_unverified = NULL;
  int supervisor_applied = APPLIED_PROCESS_MONITOR |
    (disk_monitor_enabled ? APPLIED_DISK_MONITOR : 0);
  int64_t last_resource_check = started - 25;
  int cleanup_unverified = 0;
  int64_t drain_deadline = -1;
  int wait_status = 0;
  int64_t output_written = 0;
  struct setup_error setup_failure = { STAGE_NONE, 0, 0 };
  size_t setup_read = 0;
  unsigned char buffer[8192];
  uint64_t disk_entry_limit = (uint64_t)aggregate_disk_bytes / 512 + 1024;
  if (disk_entry_limit > 1000000) disk_entry_limit = 1000000;

  while (!child_reaped || !output_eof) {
    int64_t now = monotonic_ms();
    if (!timed_out && now >= 0 && now - started >= wall_clock_ms) {
      timed_out = 1;
      kill_group(child, SIGKILL);
      group_killed = 1;
    }

    if (!group_killed && now >= 0 && now - last_resource_check >= 25) {
      last_resource_check = now;
      int process_count = group_process_count(child);
      if (process_count < 0) {
        monitor_unverified = "process_count";
        kill_group(child, SIGKILL);
        group_killed = 1;
      } else {
        supervisor_applied |= APPLIED_PROCESS_MONITOR;
        if ((int64_t)process_count > processes) {
          process_exceeded = 1;
          kill_group(child, SIGKILL);
          group_killed = 1;
        }
      }
      if (!group_killed && disk_monitor_enabled) {
        int disk_status = scan_disk_path(
          disk_root_c,
          (uint64_t)aggregate_disk_bytes,
          disk_entry_limit
        );
        if (disk_status < 0) {
          monitor_unverified = "aggregate_disk";
          kill_group(child, SIGKILL);
          group_killed = 1;
        } else {
          supervisor_applied |= APPLIED_DISK_MONITOR;
          if (disk_status == 1) disk_exceeded = 1;
          if (disk_status == 2) disk_entries_exceeded = 1;
          if (disk_status > 0) {
            kill_group(child, SIGKILL);
            group_killed = 1;
          }
        }
      }
    }

    if (!child_reaped) {
      pid_t waited = waitpid(child, &wait_status, WNOHANG);
      if (waited == child) {
        child_reaped = 1;
        if (disk_monitor_enabled && !disk_exceeded &&
            !disk_entries_exceeded && monitor_unverified == NULL) {
          int disk_status = scan_disk_path(
            disk_root_c,
            (uint64_t)aggregate_disk_bytes,
            disk_entry_limit
          );
          if (disk_status < 0) monitor_unverified = "aggregate_disk";
          if (disk_status == 1) disk_exceeded = 1;
          if (disk_status == 2) disk_entries_exceeded = 1;
          if (disk_status >= 0) supervisor_applied |= APPLIED_DISK_MONITOR;
        }
        kill_group(child, SIGKILL);
        group_killed = 1;
      } else if (waited < 0 && errno != EINTR) {
        setup_failure.stage = STAGE_PROTOCOL;
        setup_failure.error_number = errno;
        kill_group(child, SIGKILL);
        group_killed = 1;
        child_reaped = 1;
      }
    }

    struct pollfd descriptors[2] = {
      { .fd = setup_pipe[0], .events = setup_eof ? 0 : (POLLIN | POLLHUP) },
      { .fd = output_pipe[0], .events = output_eof ? 0 : (POLLIN | POLLHUP) }
    };
    int ready = poll(descriptors, 2, 10);
    if (ready < 0 && errno != EINTR) {
      setup_failure.stage = STAGE_PROTOCOL;
      setup_failure.error_number = errno;
      kill_group(child, SIGKILL);
      group_killed = 1;
    }

    if (!setup_eof && (descriptors[0].revents & (POLLIN | POLLHUP))) {
      ssize_t count = read(
        setup_pipe[0],
        ((unsigned char *)&setup_failure) + setup_read,
        sizeof(setup_failure) - setup_read
      );
      if (count > 0) {
        setup_read += (size_t)count;
        if (setup_read == sizeof(setup_failure)) {
          kill_group(child, SIGKILL);
          group_killed = 1;
        }
      } else if (count == 0) {
        setup_eof = 1;
      } else if (errno != EAGAIN && errno != EINTR) {
        setup_failure.stage = STAGE_PROTOCOL;
        setup_failure.error_number = errno;
        kill_group(child, SIGKILL);
        group_killed = 1;
      }
    }

    if (!output_eof && (descriptors[1].revents & (POLLIN | POLLHUP))) {
      for (;;) {
        ssize_t count = read(output_pipe[0], buffer, sizeof(buffer));
        if (count > 0) {
          int64_t remaining = output_bytes - output_written;
          size_t keep = remaining > 0 && remaining < count
            ? (size_t)remaining
            : (remaining > 0 ? (size_t)count : 0);
          if (keep > 0 && write_all(output_fd, buffer, keep) != 0) {
            setup_failure.stage = STAGE_OUTPUT;
            setup_failure.error_number = errno;
            kill_group(child, SIGKILL);
            group_killed = 1;
          }
          output_written += (int64_t)keep;
          if (keep < (size_t)count && !output_exceeded) {
            output_exceeded = 1;
            kill_group(child, SIGKILL);
            group_killed = 1;
          }
        } else if (count == 0) {
          output_eof = 1;
          break;
        } else if (errno == EAGAIN || errno == EINTR) {
          break;
        } else {
          setup_failure.stage = STAGE_OUTPUT;
          setup_failure.error_number = errno;
          kill_group(child, SIGKILL);
          group_killed = 1;
          break;
        }
      }
    }

    if (group_killed && drain_deadline < 0) {
      drain_deadline = now >= 0 ? now + 250 : 0;
    }
    if (group_killed && child_reaped && !output_eof &&
        (now < 0 || now >= drain_deadline)) {
      /* A setsid descendant can escape the leader's process group while keeping
       * stdout/stderr open. Never let such a writer extend the supervisor past
       * the bounded post-kill drain window or report verified cleanup. */
      cleanup_unverified = 1;
      close(output_pipe[0]);
      output_pipe[0] = -1;
      output_eof = 1;
    }
  }

  if (!child_reaped) {
    kill_group(child, SIGKILL);
    (void)waitpid(child, &wait_status, 0);
  }
  kill_group(child, SIGKILL);
  close(setup_pipe[0]);
  if (output_pipe[0] >= 0) close(output_pipe[0]);
  close(output_fd);
  active_child = -1;
  restore_handlers(old_actions);
  int forwarded = received_signal;
  received_signal = 0;
  int64_t ended = monotonic_ms();
  int64_t elapsed = ended >= started ? ended - started : 0;
  int applied = setup_read == sizeof(setup_failure)
    ? setup_failure.applied_limits
    : APPLIED_CPU | APPLIED_AS | APPLIED_FSIZE | APPLIED_NOFILE;
  applied |= supervisor_applied;

  if (cleanup_unverified) {
    return finish_result(
      "cleanup_unverified", -1, 0, NULL, STAGE_NONE, 0, elapsed, applied
    );
  }

  if (setup_failure.stage != STAGE_NONE) {
    return finish_result(
      "setup_failed", -1, 0, NULL, setup_failure.stage,
      setup_failure.error_number, elapsed, applied
    );
  }
  if (monitor_unverified != NULL) {
    return finish_result(
      "monitor_unverified", -1, 0, monitor_unverified,
      STAGE_NONE, 0, elapsed, applied
    );
  }
  if (process_exceeded) {
    return finish_result(
      "limit_exceeded", -1, SIGKILL, "process_count",
      STAGE_NONE, 0, elapsed, applied
    );
  }
  if (disk_exceeded || disk_entries_exceeded) {
    return finish_result(
      "limit_exceeded", -1, SIGKILL,
      disk_exceeded ? "aggregate_disk" : "disk_entries",
      STAGE_NONE, 0, elapsed, applied
    );
  }
  if (output_exceeded) {
    return finish_result(
      "limit_exceeded", -1, SIGKILL, "output", STAGE_NONE, 0, elapsed, applied
    );
  }
  if (timed_out) {
    return finish_result(
      "timed_out", -1, SIGKILL, "wall_clock", STAGE_NONE, 0, elapsed, applied
    );
  }
  if (forwarded != 0) {
    return finish_result(
      "interrupted", -1, forwarded, NULL, STAGE_NONE, 0, elapsed, applied
    );
  }
  if (WIFEXITED(wait_status)) {
    return finish_result(
      "exited", WEXITSTATUS(wait_status), 0, NULL, STAGE_NONE, 0, elapsed, applied
    );
  }
  if (WIFSIGNALED(wait_status)) {
    int signal_number = WTERMSIG(wait_status);
#ifdef SIGXCPU
    if (signal_number == SIGXCPU) {
      return finish_result(
        "limit_exceeded", -1, signal_number, "cpu", STAGE_NONE, 0, elapsed, applied
      );
    }
#endif
#ifdef SIGXFSZ
    if (signal_number == SIGXFSZ) {
      return finish_result(
        "limit_exceeded", -1, signal_number, "file_size", STAGE_NONE, 0, elapsed, applied
      );
    }
#endif
    return finish_result(
      "signaled", -1, signal_number, NULL, STAGE_NONE, 0, elapsed, applied
    );
  }
  return finish_result(
    "setup_failed", -1, 0, NULL, STAGE_PROTOCOL, ECHILD, elapsed, applied
  );
}

MOONBIT_FFI_EXPORT
int32_t moonfort_local_supervisor_getpid(void) {
  return (int32_t)getpid();
}

MOONBIT_FFI_EXPORT
int32_t moonfort_local_supervisor_read_pid_file(moonbit_bytes_t path) {
  FILE *file = fopen((const char *)path, "r");
  if (file == NULL) return -errno;
  long pid = -1;
  int ok = fscanf(file, "%ld", &pid);
  fclose(file);
  if (ok != 1 || pid <= 0 || pid > INT32_MAX) return -EINVAL;
  return (int32_t)pid;
}

MOONBIT_FFI_EXPORT
int32_t moonfort_local_supervisor_wait_pid_gone(int32_t pid, int32_t timeout_ms) {
  int64_t started = monotonic_ms();
  for (;;) {
    if (kill((pid_t)pid, 0) != 0 && errno == ESRCH) return 1;
    int64_t now = monotonic_ms();
    if (now < 0 || now - started >= timeout_ms) return 0;
    sleep_ms(10);
  }
}

MOONBIT_FFI_EXPORT
void moonfort_local_supervisor_unlink(moonbit_bytes_t path) {
  (void)unlink((const char *)path);
}

MOONBIT_FFI_EXPORT
int32_t moonfort_local_supervisor_test_open_inherited_fd(void) {
  return (int32_t)open("/dev/null", O_RDONLY);
}

MOONBIT_FFI_EXPORT
void moonfort_local_supervisor_test_close_fd(int32_t fd) {
  if (fd >= 0) (void)close(fd);
}

static void cleanup_test_directory_fd(int directory) {
  int stream_fd = dup(directory);
  if (stream_fd < 0) return;
  DIR *stream = fdopendir(stream_fd);
  if (stream == NULL) {
    close(stream_fd);
    return;
  }
  for (;;) {
    errno = 0;
    struct dirent *entry = readdir(stream);
    if (entry == NULL) break;
    if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
      continue;
    }
    struct stat status;
    if (fstatat(directory, entry->d_name, &status, AT_SYMLINK_NOFOLLOW) != 0) {
      continue;
    }
    if (S_ISDIR(status.st_mode)) {
      int child = open_scanned_directory(directory, entry->d_name);
      if (child >= 0) {
        cleanup_test_directory_fd(child);
        close(child);
        (void)unlinkat(directory, entry->d_name, AT_REMOVEDIR);
      }
    } else {
      (void)unlinkat(directory, entry->d_name, 0);
    }
  }
  closedir(stream);
}

MOONBIT_FFI_EXPORT
int32_t moonfort_local_supervisor_test_prepare_directory(moonbit_bytes_t path) {
  const char *path_c = (const char *)path;
  int existing = open_monitored_root(path_c);
  if (existing >= 0) {
    cleanup_test_directory_fd(existing);
    close(existing);
    (void)rmdir(path_c);
  }
  return mkdir(path_c, 0700) == 0;
}

MOONBIT_FFI_EXPORT
void moonfort_local_supervisor_test_cleanup_directory(moonbit_bytes_t path) {
  const char *path_c = (const char *)path;
  int directory = open_monitored_root(path_c);
  if (directory < 0) return;
  cleanup_test_directory_fd(directory);
  close(directory);
  (void)rmdir(path_c);
}
