#include "runtime.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <linux/magic.h>
#include <limits.h>
#include <poll.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/mount.h>
#include <linux/mount.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/statfs.h>
#include <sys/statvfs.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef MF_RUNTIME_DIR
#define MF_RUNTIME_DIR "/run/moonfort"
#endif
#ifndef MF_TOOL_REGISTRY
#define MF_TOOL_REGISTRY "/opt/moonfort/etc/tool-registry.tsv"
#endif

static volatile sig_atomic_t cancelled;
static void cancellation(int signal_number){(void)signal_number;cancelled=1;}

static const char *argument(int argc,char **argv,const char *name,int end){
  (void)argc;
  for(int i=2;i+1<end;++i) {
    if(!strcmp(argv[i],name)) return argv[i+1];
  }
  return NULL;
}

static long long number_argument(int argc,char **argv,const char *name,long long maximum,int end){
  const char *text=argument(argc,argv,name,end);char *tail=NULL;if(!text||!*text||text[0]=='-')mf_die("missing numeric supervisor argument");
  errno=0;long long value=strtoll(text,&tail,10);if(errno||*tail||value<=0||value>maximum)mf_die("supervisor limit is outside its fixed bound");return value;
}

static long long directory_bytes_at(int descriptor,long long maximum,int *entries){
  int duplicate=dup(descriptor);if(duplicate<0)return -1;DIR *stream=fdopendir(duplicate);if(!stream){close(duplicate);return -1;}long long total=0;
  for(;;){errno=0;struct dirent *entry=readdir(stream);if(!entry){if(errno)total=-1;break;}if(!strcmp(entry->d_name,".")||!strcmp(entry->d_name,".."))continue;if(++*entries>1000000){total=-1;break;}
    struct stat status;if(fstatat(descriptor,entry->d_name,&status,AT_SYMLINK_NOFOLLOW)){total=-1;break;}
    if(S_ISREG(status.st_mode)){if(status.st_size<0||status.st_size>maximum-total){total=maximum+1;break;}total+=status.st_size;}
    else if(S_ISDIR(status.st_mode)){int child=openat(descriptor,entry->d_name,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);if(child<0){total=-1;break;}long long nested=directory_bytes_at(child,maximum-total,entries);close(child);if(nested<0||nested>maximum-total){total=nested<0?-1:maximum+1;break;}total+=nested;}
    else if(!S_ISLNK(status.st_mode)){total=-1;break;}
  }
  closedir(stream);return total;
}

static long long overlay_bytes(const char *profile,long long maximum){
  char path[MF_PATH_MAX];snprintf(path,sizeof(path),MF_RUNTIME_DIR "/overlay-%s/upper",profile);int fd=open(path,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);if(fd<0)return -1;int entries=0;long long result=directory_bytes_at(fd,maximum,&entries);close(fd);return result;
}

static int quota_is_enforced(const char *profile,long long disk_mib){
  char root[MF_PATH_MAX],name[80];int name_length=snprintf(name,sizeof(name),"overlay-%s",profile);
  if(name_length<=0||(size_t)name_length>=sizeof(name)||mf_join_path(root,sizeof(root),MF_RUNTIME_DIR,name))return 0;
  struct statfs status;if(statfs(root,&status)||status.f_type!=TMPFS_MAGIC||status.f_bsize<=0||status.f_blocks==0||status.f_files==0)return 0;
  unsigned long long maximum=(unsigned long long)disk_mib*1048576ULL;
  unsigned long long capacity=(unsigned long long)status.f_blocks*(unsigned long long)status.f_bsize;
  unsigned long long inode_limit=maximum/4096ULL+1024ULL;
  return capacity<=maximum+(unsigned long long)status.f_bsize&&
    (unsigned long long)status.f_files<=inode_limit;
}

static int write_control(const char *directory,const char *name,const char *value){
  char path[MF_PATH_MAX];snprintf(path,sizeof(path),"%s/%s",directory,name);int fd=open(path,O_WRONLY|O_CLOEXEC|O_NOFOLLOW);if(fd<0)return -1;int result=mf_write_all(fd,value,strlen(value));close(fd);return result;
}

static long long cpu_usage_usec(const char *directory){
  char path[MF_PATH_MAX],line[256];snprintf(path,sizeof(path),"%s/cpu.stat",directory);FILE *stream=fopen(path,"re");if(!stream)return -1;long long value=-1;while(fgets(line,sizeof(line),stream))if(sscanf(line,"usage_usec %lld",&value)==1)break;fclose(stream);return value;
}

static long long pids_limit_events(const char *directory){
  char path[MF_PATH_MAX],line[128];if(mf_join_path(path,sizeof(path),directory,"pids.events"))return -1;
  FILE *stream=fopen(path,"re");if(!stream)return -1;long long value=-1;
  while(fgets(line,sizeof(line),stream))if(sscanf(line,"max %lld",&value)==1)break;
  fclose(stream);return value;
}

static void kill_cgroup(const char *directory){
  if(write_control(directory,"cgroup.kill","1")){/* best effort is checked by removal */}
}

static int remove_cgroup(const char *directory){
  for(int attempt=0;attempt<100;++attempt){if(!rmdir(directory))return 0;if(errno!=EBUSY&&errno!=ENOTEMPTY)return -1;usleep(10000);}return -1;
}

static int setup_cgroup(char *directory,size_t capacity,const char *profile,long long process_limit,pid_t child){
  snprintf(directory,capacity,"/sys/fs/cgroup/moonfort-%.16s-%ld",profile,(long)child);
  if(mkdir(directory,0700))return -1;
  char value[64];snprintf(value,sizeof(value),"%lld",process_limit);if(write_control(directory,"pids.max",value))return -1;
  snprintf(value,sizeof(value),"%ld",(long)child);if(write_control(directory,"cgroup.procs",value))return -1;
  if(cpu_usage_usec(directory)<0)return -1;
  return 0;
}

static int registry_allows(const char *capability,const char *executable,const char *expected_registry_digest){
  char digest[MF_SHA256_HEX];if(mf_hash_regular_path(MF_TOOL_REGISTRY,digest,NULL)||strcmp(digest,expected_registry_digest))return 0;
  FILE *stream=fopen(MF_TOOL_REGISTRY,"re");if(!stream)return 0;char *line=NULL;size_t capacity=0;int allowed=0;
  while(getline(&line,&capacity,stream)>0){char label[129],path[MF_PATH_MAX],expected[MF_SHA256_HEX],extra;
    int fields=sscanf(line,"%128[^\t]\t%4095[^\t]\t%64[a-f0-9]%c",label,path,expected,&extra);
    if(fields!=4||extra!='\n'||!mf_valid_token(label,128)||!mf_canonical_absolute(path)||!mf_valid_digest(expected)){allowed=0;break;}
    if(!strcmp(label,capability)&&!strcmp(path,executable)){char actual[MF_SHA256_HEX];allowed=!mf_hash_regular_path(path,actual,NULL)&&!strcmp(actual,expected);break;}
  }
  free(line);fclose(stream);return allowed;
}

struct policy {char contract[64],profile[MF_SHA256_HEX],scratch[MF_PATH_MAX],supervisor_digest[MF_SHA256_HEX],registry_digest[MF_SHA256_HEX],root_digest[MF_SHA256_HEX];long long cpu,processes,disk;};

static struct policy read_policy(const char *profile){
  char path[MF_PATH_MAX],body[MF_PATH_MAX*3];snprintf(path,sizeof(path),MF_RUNTIME_DIR "/policy-%s",profile);if(mf_read_text_file(path,body,sizeof(body))<0)mf_die("prepared profile policy unavailable");
  struct policy p={0};char extra;int read=sscanf(body,"%63[^\n]\n%64[a-f0-9]\n%lld\n%lld\n%lld\n%4095[^\n]\n%64[a-f0-9]\n%64[a-f0-9]\n%64[a-f0-9]\n%c",p.contract,p.profile,&p.cpu,&p.processes,&p.disk,p.scratch,p.supervisor_digest,p.registry_digest,p.root_digest,&extra);
  if(read!=9||strcmp(p.contract,"moonfort-guest-v1")||strcmp(p.profile,profile)||!mf_canonical_absolute(p.scratch)||!mf_valid_digest(p.supervisor_digest)||!mf_valid_digest(p.registry_digest)||!mf_valid_digest(p.root_digest))mf_die("prepared profile policy malformed");
  return p;
}

static int readonly_root_except_scratch(const char *scratch,const char *profile){
  if(unshare(CLONE_NEWNS)||mount(NULL,"/",NULL,MS_REC|MS_PRIVATE,NULL))return -1;
  struct mount_attr readonly={.attr_set=MOUNT_ATTR_RDONLY};
  if(syscall(SYS_mount_setattr,AT_FDCWD,"/",AT_RECURSIVE,&readonly,sizeof(readonly)))return -1;
  struct mount_attr writable={.attr_clr=MOUNT_ATTR_RDONLY};
  char quota_root[MF_PATH_MAX],name[80];int name_length=snprintf(name,sizeof(name),"overlay-%s",profile);
  if(name_length<=0||(size_t)name_length>=sizeof(name)||mf_join_path(quota_root,sizeof(quota_root),MF_RUNTIME_DIR,name)||syscall(SYS_mount_setattr,AT_FDCWD,quota_root,AT_RECURSIVE,&writable,sizeof(writable))||syscall(SYS_mount_setattr,AT_FDCWD,scratch,AT_RECURSIVE,&writable,sizeof(writable)))return -1;
  struct statvfs root_status,scratch_status,quota_status;
  if(statvfs("/",&root_status)||statvfs(scratch,&scratch_status)||statvfs(quota_root,&quota_status)||!(root_status.f_flag&ST_RDONLY)||(scratch_status.f_flag&ST_RDONLY)||(quota_status.f_flag&ST_RDONLY))return -1;
  return 0;
}

static int close_untrusted_descriptors(void){
#ifdef SYS_close_range
  if(syscall(SYS_close_range,3U,UINT_MAX,0)==0)return 0;
  if(errno!=ENOSYS&&errno!=EINVAL)return -1;
#endif
  struct rlimit limit;if(getrlimit(RLIMIT_NOFILE,&limit))return -1;
  unsigned long maximum=limit.rlim_cur==RLIM_INFINITY?1048576UL:(unsigned long)limit.rlim_cur;
  if(maximum>1048576UL)maximum=1048576UL;
  for(unsigned long descriptor=3;descriptor<maximum;++descriptor)close((int)descriptor);
  return 0;
}

static int unprivileged_user_namespaces_disabled(void){
  char value[64];
  int descriptor=open("/proc/sys/kernel/unprivileged_userns_clone",O_RDONLY|O_CLOEXEC|O_NOFOLLOW);
  ssize_t first=descriptor<0?-1:read(descriptor,value,sizeof(value)-1);if(descriptor>=0)close(descriptor);if(first>=0)value[first]=0;
  if(first>=0&&strcmp(value,"0\n")&&strcmp(value,"0"))return 0;
  descriptor=open("/proc/sys/user/max_user_namespaces",O_RDONLY|O_CLOEXEC|O_NOFOLLOW);
  ssize_t second=descriptor<0?-1:read(descriptor,value,sizeof(value)-1);if(descriptor>=0)close(descriptor);if(second>=0)value[second]=0;
  return second>=0&&(!strcmp(value,"0\n")||!strcmp(value,"0"));
}

static void child_exec(int output_fd,int ready_fd,char **command,long long cpu,long long processes,const char *scratch,const char *profile){
  char ready;while(read(ready_fd,&ready,1)<0&&errno==EINTR){}close(ready_fd);
  int null_fd=open("/dev/null",O_RDONLY|O_CLOEXEC);if(null_fd<0||dup2(null_fd,STDIN_FILENO)<0||dup2(output_fd,STDOUT_FILENO)<0||dup2(output_fd,STDERR_FILENO)<0)_exit(125);
  if(null_fd>2)close(null_fd);
  if(output_fd>2)close(output_fd);
  struct rlimit limit={.rlim_cur=(rlim_t)cpu,.rlim_max=(rlim_t)cpu};if(setrlimit(RLIMIT_CPU,&limit))_exit(125);
  limit.rlim_cur=(rlim_t)processes;limit.rlim_max=(rlim_t)processes;if(setrlimit(RLIMIT_NPROC,&limit))_exit(125);
  limit.rlim_cur=0;limit.rlim_max=0;if(setrlimit(RLIMIT_CORE,&limit))_exit(125);
  if(readonly_root_except_scratch(scratch,profile)||setgroups(0,NULL)||setgid(65534)||setuid(65534)||prctl(PR_SET_NO_NEW_PRIVS,1,0,0,0))_exit(125);
  if(close_untrusted_descriptors())_exit(125);
  char home[MF_PATH_MAX+16],tmp[MF_PATH_MAX+16];snprintf(home,sizeof(home),"HOME=%s",scratch);snprintf(tmp,sizeof(tmp),"TMPDIR=%s/.tmp",scratch);
  char *environment[]={"LANG=C.UTF-8","LC_ALL=C.UTF-8","PATH=/opt/moonfort/tools",home,tmp,NULL};
  execve(command[0],command,environment);_exit(126);
}

int main(int argc,char **argv){
  if(argc<4||strcmp(argv[1],"run"))mf_die("only the fixed run operation is allowed");
  int separator=-1;
  for(int i=2;i<argc;++i)if(!strcmp(argv[i],"--")){separator=i;break;}
  if(separator<0||separator+1>=argc)mf_die("supervised command is missing");
  const char *contract=argument(argc,argv,"--contract",separator),*profile=argument(argc,argv,"--profile-digest",separator),*scratch=argument(argc,argv,"--scratch",separator);
  const char *capability=argument(argc,argv,"--capability",separator);
  long long cpu=number_argument(argc,argv,"--cpu-seconds",86400,separator),processes=number_argument(argc,argv,"--process-limit",4096,separator),disk=number_argument(argc,argv,"--scratch-disk-mib",1048576,separator),wall=number_argument(argc,argv,"--wall-clock-ms",86400000,separator),output_limit=number_argument(argc,argv,"--output-bytes",67108864,separator);
  if(!contract||strcmp(contract,"moonfort-guest-v1")||!mf_valid_digest(profile)||!mf_valid_token(capability,128)||!mf_canonical_absolute(scratch)||!mf_canonical_absolute(argv[separator+1]))mf_die("supervisor request malformed");
  struct policy policy=read_policy(profile);char self[MF_SHA256_HEX];if(mf_hash_self(self)||strcmp(self,policy.supervisor_digest)||strcmp(policy.scratch,scratch)||policy.cpu!=cpu||policy.processes!=processes||policy.disk!=disk||!registry_allows(capability,argv[separator+1],policy.registry_digest)||!quota_is_enforced(profile,disk)||!unprivileged_user_namespaces_disabled())mf_die("supervisor request is not bound to enforced filesystem and runtime policy");
  char temporary[MF_PATH_MAX];if(mf_join_path(temporary,sizeof(temporary),scratch,".tmp")||(mkdir(temporary,0700)&&errno!=EEXIST)||chown(temporary,65534,65534)||chmod(temporary,0700))mf_die("private temporary directory unavailable");
  int output_pipe[2],ready_pipe[2];if(pipe2(output_pipe,O_CLOEXEC|O_NONBLOCK)||pipe2(ready_pipe,O_CLOEXEC))mf_die("bounded process pipes unavailable");
  pid_t child=fork();if(child<0)mf_die("target fork failed");if(!child){close(output_pipe[0]);close(ready_pipe[1]);child_exec(output_pipe[1],ready_pipe[0],&argv[separator+1],cpu,processes,scratch,profile);}
  close(output_pipe[1]);close(ready_pipe[0]);char cgroup[MF_PATH_MAX];if(setup_cgroup(cgroup,sizeof(cgroup),profile,processes,child)){kill(child,SIGKILL);close(ready_pipe[1]);waitpid(child,NULL,0);remove_cgroup(cgroup);mf_die("private cgroup limits unavailable");}if(mf_write_all(ready_pipe[1],"1",1)){kill_cgroup(cgroup);waitpid(child,NULL,0);remove_cgroup(cgroup);mf_die("target launch synchronization failed");}close(ready_pipe[1]);
  struct sigaction action={0};action.sa_handler=cancellation;sigemptyset(&action.sa_mask);sigaction(SIGTERM,&action,NULL);sigaction(SIGINT,&action,NULL);sigaction(SIGHUP,&action,NULL);
  int64_t start=mf_monotonic_ms(),next_disk=start;long long emitted=0;int status=0,exited=0,limit_code=0;char buffer[16384];
  while(!exited){
    struct pollfd descriptor={.fd=output_pipe[0],.events=POLLIN};(void)poll(&descriptor,1,20);
    for(;;){ssize_t count=read(output_pipe[0],buffer,sizeof(buffer));if(count<0&&(errno==EAGAIN||errno==EWOULDBLOCK))break;if(count<0&&errno==EINTR)continue;if(count<=0)break;long long keep=count;if(keep>output_limit-emitted)keep=output_limit-emitted;if(keep>0&&mf_write_all(STDOUT_FILENO,buffer,(size_t)keep)){cancelled=1;keep=0;}emitted+=keep;if(keep<count){limit_code=201;break;}}
    if(waitpid(child,&status,WNOHANG)==child)exited=1;
    int64_t now=mf_monotonic_ms();long long usage=cpu_usage_usec(cgroup);
    if(cancelled&&!limit_code)limit_code=202;
    if(now-start>=wall&&!limit_code)limit_code=202;
    if((usage<0||usage>cpu*1000000LL)&&!limit_code)limit_code=203;
    long long pids_events=pids_limit_events(cgroup);if(pids_events!=0&&!limit_code)limit_code=205;
    if(now>=next_disk){long long used=overlay_bytes(profile,disk*1048576LL);if((used<0||used>disk*1048576LL)&&!limit_code)limit_code=204;next_disk=now+50;}
    if(limit_code)kill_cgroup(cgroup);
    if(limit_code&&!exited){if(waitpid(child,&status,0)==child)exited=1;}
  }
  kill_cgroup(cgroup);for(;;){ssize_t count=read(output_pipe[0],buffer,sizeof(buffer));if(count<=0)break;long long keep=count;if(keep>output_limit-emitted)keep=output_limit-emitted;if(keep>0)mf_write_all(STDOUT_FILENO,buffer,(size_t)keep);emitted+=keep;}close(output_pipe[0]);
  if(remove_cgroup(cgroup))mf_die("descendant cleanup could not be verified");
  if(limit_code)return limit_code;
  if(WIFEXITED(status)){int code=WEXITSTATUS(status);return code>=201&&code<=205?200:code;}
  if(WIFSIGNALED(status))return 128+WTERMSIG(status);
  return 125;
}
