#include "runtime.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <unistd.h>

#ifndef LLONG_MAX
#define LLONG_MAX 9223372036854775807LL
#endif

#ifndef MF_RUNTIME_DIR
#define MF_RUNTIME_DIR "/run/moonfort"
#endif
#ifndef MF_ROOT_MANIFEST
#define MF_ROOT_MANIFEST "/opt/moonfort/etc/executor-root.manifest"
#endif
#ifndef MF_TOOL_REGISTRY
#define MF_TOOL_REGISTRY "/opt/moonfort/etc/tool-registry.tsv"
#endif

struct options {
  const char *contract, *workspace, *workspace_digest, *scratch, *profile_digest;
  const char *supervisor, *executor_root_digest, *attester_digest;
  const char *supervisor_digest, *tool_registry_digest;
  long long cpu_seconds, process_limit, scratch_disk_mib, disk_mib, max_entries;
};

struct inventory {
  struct mf_sha256 workspace_hash;
  long long entries, bytes, maximum_entries, maximum_bytes;
  int emit_json, first;
};

static const char *argument(int argc, char **argv, const char *name) {
  for (int i=2;i+1<argc;++i) if(!strcmp(argv[i],name)) return argv[i+1];
  return NULL;
}

static long long number_argument(int argc, char **argv, const char *name, long long maximum) {
  const char *text=argument(argc,argv,name); char *end=NULL;
  if(!text||!*text||text[0]=='-'||strlen(text)>20)mf_die("missing numeric argument");
  errno=0; long long value=strtoll(text,&end,10);
  if(errno||*end||value<=0||value>maximum)mf_die("numeric argument is outside its fixed bound");
  return value;
}

static int compare_names(const void *left, const void *right) {
  return strcmp(*(char *const *)left, *(char *const *)right);
}

static char **names_at(int descriptor, size_t *count) {
  int duplicate=dup(descriptor); if(duplicate<0)return NULL;
  DIR *stream=fdopendir(duplicate); if(!stream){close(duplicate);return NULL;}
  char **names=NULL; size_t used=0,capacity=0; int failed=0;
  for(;;){
    errno=0; struct dirent *entry=readdir(stream);
    if(!entry){if(errno)failed=1;break;}
    if(!strcmp(entry->d_name,".")||!strcmp(entry->d_name,".."))continue;
    if(strchr(entry->d_name,'\n')||strchr(entry->d_name,'\t')||strchr(entry->d_name,'\\')){failed=1;break;}
    if(used==capacity){size_t next=capacity?capacity*2:32;void *grown=realloc(names,next*sizeof(*names));if(!grown){failed=1;break;}names=grown;capacity=next;}
    names[used]=strdup(entry->d_name);if(!names[used]){failed=1;break;}++used;
  }
  closedir(stream);
  if(failed){if(names){for(size_t i=0;i<used;++i)free(names[i]);free(names);}*count=SIZE_MAX;return NULL;}
  qsort(names,used,sizeof(*names),compare_names);*count=used;return names;
}

static void free_names(char **names, size_t count){for(size_t i=0;i<count;++i)free(names[i]);free(names);}

static void hash_manifest_line(struct inventory *scan, char kind, const char *path, long long size, const char *digest) {
  char line[MF_PATH_MAX+128]; int length=snprintf(line,sizeof(line),"%c\t%s\t%lld\t%s\n",kind,path,size,digest);
  if(length<=0||(size_t)length>=sizeof(line))mf_die("manifest entry exceeds bound");
  mf_sha256_update(&scan->workspace_hash,line,(size_t)length);
}

static void emit_entry(struct inventory *scan, const char *path, const char *kind, long long size, const char *fingerprint) {
  if(!scan->emit_json)return;
  if(!scan->first)mf_write_all(STDOUT_FILENO,",",1);scan->first=0;
  mf_write_all(STDOUT_FILENO,"{\"relative_path\":",17);mf_json_string(STDOUT_FILENO,path);
  mf_write_all(STDOUT_FILENO,",\"kind\":",8);mf_json_string(STDOUT_FILENO,kind);
  dprintf(STDOUT_FILENO,",\"size_bytes\":\"%lld\",\"fingerprint\":",size);mf_json_string(STDOUT_FILENO,fingerprint);
  mf_write_all(STDOUT_FILENO,"}",1);
}

static void walk_tree(struct inventory *scan, int directory, const char *prefix, int workspace_mode) {
  size_t count=0;char **names=names_at(directory,&count);if(count==SIZE_MAX)mf_die("directory inventory failed");
  for(size_t index=0;index<count;++index){
    if(++scan->entries>scan->maximum_entries)mf_die("inventory entry limit exceeded");
    char relative[MF_PATH_MAX];int length=snprintf(relative,sizeof(relative),"%s%s%s",prefix,*prefix?"/":"",names[index]);
    if(length<=0||(size_t)length>=sizeof(relative))mf_die("inventory path exceeds bound");
    struct stat before;if(fstatat(directory,names[index],&before,AT_SYMLINK_NOFOLLOW))mf_die("inventory entry changed");
    if(S_ISREG(before.st_mode)){
      if(before.st_size<0||before.st_size>scan->maximum_bytes-scan->bytes)mf_die("inventory byte limit exceeded");
      int fd=openat(directory,names[index],O_RDONLY|O_CLOEXEC|O_NOFOLLOW);struct stat opened,after;
      if(fd<0||fstat(fd,&opened)||!S_ISREG(opened.st_mode)||opened.st_dev!=before.st_dev||opened.st_ino!=before.st_ino)mf_die("inventory regular file changed");
      char digest[MF_SHA256_HEX];if(mf_hash_fd(fd,digest,opened.st_size)||fstat(fd,&after)||after.st_size!=opened.st_size||after.st_dev!=opened.st_dev||after.st_ino!=opened.st_ino)mf_die("inventory regular file changed while hashing");
      close(fd);scan->bytes+=opened.st_size;
      if(workspace_mode)hash_manifest_line(scan,'F',relative,opened.st_size,digest);
      emit_entry(scan,relative,"RegularFile",opened.st_size,digest);
    }else if(S_ISDIR(before.st_mode)){
      int child=openat(directory,names[index],O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);if(child<0)mf_die("inventory directory changed");
      if(workspace_mode)hash_manifest_line(scan,'D',relative,0,"-");
      emit_entry(scan,relative,"DirectoryEntry",0,"directory");walk_tree(scan,child,relative,workspace_mode);close(child);
    }else if(S_ISLNK(before.st_mode)&&!workspace_mode){
      char target[PATH_MAX+1];ssize_t used=readlinkat(directory,names[index],target,PATH_MAX);if(used<0||used==PATH_MAX)mf_die("inventory symlink changed");target[used]=0;
      struct mf_sha256 hash;unsigned char raw[32];char digest[MF_SHA256_HEX];mf_sha256_init(&hash);mf_sha256_update(&hash,target,(size_t)used);mf_sha256_finish(&hash,raw);mf_hex(raw,32,digest);
      char fingerprint[80];snprintf(fingerprint,sizeof(fingerprint),"link:%s",digest);emit_entry(scan,relative,"SymbolicLink",0,fingerprint);
    }else mf_die("workspace or scratch contains unsupported file type");
  }
  free_names(names,count);
}

static int mount_is_read_only(const char *path) {
  struct statvfs status;if(statvfs(path,&status)||!(status.f_flag&ST_RDONLY))return 0;
  FILE *stream=fopen("/proc/self/mountinfo","re");if(!stream)return 0;
  char *line=NULL;size_t capacity=0;int found=0;
  while(getline(&line,&capacity,stream)>0){char *save=NULL,*field=strtok_r(line," ",&save);int column=1;const char *mountpoint=NULL;
    while(field){if(column==5)mountpoint=field;if(mountpoint&&!strcmp(mountpoint,path)){found=1;break;}field=strtok_r(NULL," ",&save);++column;}
    if(found)break;
  }
  free(line);fclose(stream);return found;
}

static void verify_root_manifest(const char *expected) {
  char observed[MF_SHA256_HEX];off_t size;if(mf_hash_regular_path(MF_ROOT_MANIFEST,observed,&size)||strcmp(observed,expected))mf_die("executor root manifest digest mismatch");
  if(size<=0||size>1024*1024)mf_die("executor root manifest size invalid");
  FILE *stream=fopen(MF_ROOT_MANIFEST,"re");if(!stream)mf_die("executor root manifest unavailable");
  char *line=NULL;size_t capacity=0;size_t rows=0;
  while(getline(&line,&capacity,stream)>0){
    char kind=0,path[MF_PATH_MAX],digest[MF_SHA256_HEX],extra;long long declared=-1;
    if(sscanf(line,"%c\t%4095[^\t]\t%lld\t%64[a-f0-9]%c",&kind,path,&declared,digest,&extra)!=4||kind!='F'||!mf_canonical_absolute(path)||!mf_valid_digest(digest)||declared<0)mf_die("executor root manifest malformed");
    char actual[MF_SHA256_HEX];off_t size_actual;if(mf_hash_regular_path(path,actual,&size_actual)||size_actual!=declared||strcmp(actual,digest))mf_die("executor root file digest mismatch");
    if(++rows>4096)mf_die("executor root manifest entry limit exceeded");
  }
  free(line);fclose(stream);if(!rows)mf_die("executor root manifest empty");
}

static void ensure_directory(const char *path, mode_t mode) {
  if(mkdir(path,mode)&&errno!=EEXIST)mf_die("runtime directory creation failed");
  struct stat status;if(lstat(path,&status)||!S_ISDIR(status.st_mode)||S_ISLNK(status.st_mode)||(status.st_mode&0022))mf_die("runtime directory is not private");
}

static void prepare_overlay(const char *workspace,const char *scratch,const char *profile) {
  ensure_directory(MF_RUNTIME_DIR,0700);
  char root[MF_PATH_MAX],upper[MF_PATH_MAX],work[MF_PATH_MAX];
  snprintf(root,sizeof(root),MF_RUNTIME_DIR "/overlay-%s",profile);snprintf(upper,sizeof(upper),"%s/upper",root);snprintf(work,sizeof(work),"%s/work",root);
  ensure_directory(root,0700);ensure_directory(upper,0700);ensure_directory(work,0700);
  if(mkdir(scratch,0700)&&errno!=EEXIST)mf_die("scratch mountpoint creation failed");
  int scratch_fd=open(scratch,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);if(scratch_fd<0)mf_die("scratch mountpoint unsafe");
  size_t count=0;char **names=names_at(scratch_fd,&count);close(scratch_fd);if(count==SIZE_MAX)mf_die("scratch mountpoint inventory failed");if(names)free_names(names,count);if(count)mf_die("scratch mountpoint must be empty");
  char options[MF_PATH_MAX*3];int length=snprintf(options,sizeof(options),"lowerdir=%s,upperdir=%s,workdir=%s",workspace,upper,work);
  if(length<=0||(size_t)length>=sizeof(options)||mount("overlay",scratch,"overlay",MS_NODEV|MS_NOSUID,options))mf_die("writable overlay mount failed");
}

static void write_policy(const struct options *o) {
  char path[MF_PATH_MAX],temporary[MF_PATH_MAX],body[MF_PATH_MAX*3];
  snprintf(path,sizeof(path),MF_RUNTIME_DIR "/policy-%s",o->profile_digest);snprintf(temporary,sizeof(temporary),"%s.tmp-%ld",path,(long)getpid());
  int length=snprintf(body,sizeof(body),"%s\n%s\n%lld\n%lld\n%lld\n%s\n%s\n%s\n%s\n",o->contract,o->profile_digest,o->cpu_seconds,o->process_limit,o->scratch_disk_mib,o->scratch,o->supervisor_digest,o->tool_registry_digest,o->executor_root_digest);
  if(length<=0||(size_t)length>=sizeof(body)||mf_write_text_file(temporary,body,0600,1)||rename(temporary,path))mf_die("profile policy persistence failed");
}

static struct options parse_prepare(int argc,char **argv){
  struct options o={0};
  o.contract=argument(argc,argv,"--contract");o.workspace=argument(argc,argv,"--workspace");o.workspace_digest=argument(argc,argv,"--workspace-digest");o.scratch=argument(argc,argv,"--scratch");o.profile_digest=argument(argc,argv,"--profile-digest");o.supervisor=argument(argc,argv,"--supervisor");o.executor_root_digest=argument(argc,argv,"--executor-root-digest");o.attester_digest=argument(argc,argv,"--attester-digest");o.supervisor_digest=argument(argc,argv,"--supervisor-digest");o.tool_registry_digest=argument(argc,argv,"--tool-registry-digest");
  o.cpu_seconds=number_argument(argc,argv,"--cpu-seconds",86400);o.process_limit=number_argument(argc,argv,"--process-limit",4096);o.scratch_disk_mib=number_argument(argc,argv,"--scratch-disk-mib",1048576);
  if(!o.contract||strcmp(o.contract,"moonfort-guest-v1")||!mf_canonical_absolute(o.workspace)||!mf_canonical_absolute(o.scratch)||!mf_canonical_absolute(o.supervisor)||!mf_valid_digest(o.workspace_digest)||!mf_valid_digest(o.profile_digest)||!mf_valid_digest(o.executor_root_digest)||!mf_valid_digest(o.attester_digest)||!mf_valid_digest(o.supervisor_digest)||!mf_valid_digest(o.tool_registry_digest))mf_die("prepare request is malformed");
  return o;
}

static void prepare(int argc,char **argv){
  struct options o=parse_prepare(argc,argv);char self[MF_SHA256_HEX],supervisor[MF_SHA256_HEX],registry[MF_SHA256_HEX];
  if(mf_hash_self(self)||strcmp(self,o.attester_digest)||mf_hash_regular_path(o.supervisor,supervisor,NULL)||strcmp(supervisor,o.supervisor_digest)||mf_hash_regular_path(MF_TOOL_REGISTRY,registry,NULL)||strcmp(registry,o.tool_registry_digest))mf_die("guest runtime or tool registry digest mismatch");
  verify_root_manifest(o.executor_root_digest);if(!mount_is_read_only(o.workspace))mf_die("workspace drive is not independently read-only");
  int root=open(o.workspace,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);if(root<0)mf_die("workspace root is unsafe");
  struct inventory scan={.entries=0,.bytes=0,.maximum_entries=1000000,.maximum_bytes=LLONG_MAX,.emit_json=0,.first=1};mf_sha256_init(&scan.workspace_hash);walk_tree(&scan,root,"",1);close(root);
  unsigned char raw[32];char digest[MF_SHA256_HEX];mf_sha256_finish(&scan.workspace_hash,raw);mf_hex(raw,32,digest);if(strcmp(digest,o.workspace_digest))mf_die("workspace digest does not match provisioner lease");
  prepare_overlay(o.workspace,o.scratch,o.profile_digest);write_policy(&o);
  dprintf(STDOUT_FILENO,"{\"contract\":\"moonfort-guest-v1\",\"profileDigest\":\"%s\",\"executorRootDigest\":\"%s\",\"guestAttesterDigest\":\"%s\",\"guestSupervisorDigest\":\"%s\",\"workspaceDigest\":\"%s\",\"workspacePath\":",o.profile_digest,o.executor_root_digest,self,supervisor,o.workspace_digest);mf_json_string(STDOUT_FILENO,o.workspace);
  dprintf(STDOUT_FILENO,",\"workspaceReadOnly\":true,\"scratchPath\":");mf_json_string(STDOUT_FILENO,o.scratch);
  dprintf(STDOUT_FILENO,",\"scratchWritable\":true,\"scratchIsolated\":true,\"scratchOverlay\":true,\"scratchLowerDigest\":\"%s\",\"scratchBaselineDigest\":\"%s\",\"scratchBaselineEntries\":%lld,\"scratchBaselineBytes\":\"%lld\",\"toolRegistryDigest\":\"%s\",\"supervisorPath\":",digest,digest,scan.entries,scan.bytes,registry);mf_json_string(STDOUT_FILENO,o.supervisor);
  dprintf(STDOUT_FILENO,",\"cpuSeconds\":%lld,\"processLimit\":%lld,\"scratchDiskMiB\":%lld}\n",o.cpu_seconds,o.process_limit,o.scratch_disk_mib);
}

static void inventory_command(int argc,char **argv){
  const char *contract=argument(argc,argv,"--contract"),*scratch=argument(argc,argv,"--scratch"),*profile=argument(argc,argv,"--profile-digest");
  long long disk=number_argument(argc,argv,"--disk-mib",1048576),maximum=number_argument(argc,argv,"--max-entries",4096);
  if(!contract||strcmp(contract,"moonfort-guest-v1")||!mf_canonical_absolute(scratch)||!mf_valid_digest(profile))mf_die("inventory request is malformed");
  char policy[MF_PATH_MAX],state[MF_PATH_MAX*3];snprintf(policy,sizeof(policy),MF_RUNTIME_DIR "/policy-%s",profile);if(mf_read_text_file(policy,state,sizeof(state))<0||!strstr(state,scratch))mf_die("inventory is not bound to a prepared profile");
  char upper[MF_PATH_MAX];snprintf(upper,sizeof(upper),MF_RUNTIME_DIR "/overlay-%s/upper",profile);int root=open(upper,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);if(root<0)mf_die("overlay upper directory unavailable");
  dprintf(STDOUT_FILENO,"{\"contract\":\"moonfort-guest-v1\",\"profileDigest\":\"%s\",\"inventory\":{\"entries\":[",profile);
  struct inventory scan={.entries=0,.bytes=0,.maximum_entries=maximum,.maximum_bytes=disk*1048576LL,.emit_json=1,.first=1};walk_tree(&scan,root,"",0);close(root);
  dprintf(STDOUT_FILENO,"],\"total_bytes\":\"%lld\"}}\n",scan.bytes);
}

int main(int argc,char **argv){
  if(argc<2)mf_die("a fixed operation is required");
  if(!strcmp(argv[1],"prepare-and-attest"))prepare(argc,argv);
  else if(!strcmp(argv[1],"inventory"))inventory_command(argc,argv);
  else mf_die("operation is not allowed");
  return 0;
}
