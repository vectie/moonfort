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

static long long nonnegative_argument(int argc, char **argv, const char *name, long long maximum) {
  const char *text=argument(argc,argv,name);char *end=NULL;
  if(!text||!*text||text[0]=='-'||strlen(text)>20)mf_die("missing nonnegative numeric argument");
  errno=0;long long value=strtoll(text,&end,10);
  if(errno||*end||value<0||value>maximum)mf_die("nonnegative numeric argument is outside its fixed bound");
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
  if(!scan->first)mf_write_all(STDOUT_FILENO,",",1);
  scan->first=0;
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
    int fields=sscanf(line,"%c\t%4095[^\t]\t%lld\t%64[a-f0-9]%c",&kind,path,&declared,digest,&extra);
    if(fields!=5||extra!='\n'||kind!='F'||!mf_canonical_absolute(path)||!mf_valid_digest(digest)||declared<0)mf_die("executor root manifest malformed");
    char actual[MF_SHA256_HEX];off_t size_actual;if(mf_hash_regular_path(path,actual,&size_actual)||size_actual!=declared||strcmp(actual,digest))mf_die("executor root file digest mismatch");
    if(++rows>4096)mf_die("executor root manifest entry limit exceeded");
  }
  free(line);fclose(stream);if(!rows)mf_die("executor root manifest empty");
}

static void ensure_directory(const char *path, mode_t mode) {
  if(mkdir(path,mode)&&errno!=EEXIST)mf_die("runtime directory creation failed");
  struct stat status;if(lstat(path,&status)||!S_ISDIR(status.st_mode)||S_ISLNK(status.st_mode)||(status.st_mode&0022))mf_die("runtime directory is not private");
}

static void prepare_overlay(const char *workspace,const char *scratch,const char *profile,long long disk_mib) {
  ensure_directory(MF_RUNTIME_DIR,0700);
  char root[MF_PATH_MAX],upper[MF_PATH_MAX],work[MF_PATH_MAX];
  char root_name[80];int root_name_length=snprintf(root_name,sizeof(root_name),"overlay-%s",profile);
  if(root_name_length<=0||(size_t)root_name_length>=sizeof(root_name)||mf_join_path(root,sizeof(root),MF_RUNTIME_DIR,root_name))mf_die("overlay path exceeds bound");
  ensure_directory(root,0700);
  char quota[128];long long inodes=(disk_mib*1024*1024)/4096+1024;int quota_length=snprintf(quota,sizeof(quota),"size=%lldm,nr_inodes=%lld,mode=0700",disk_mib,inodes);
  if(quota_length<=0||(size_t)quota_length>=sizeof(quota)||mount("tmpfs",root,"tmpfs",MS_NODEV|MS_NOSUID|MS_NOEXEC,quota))mf_die("quota-bounded scratch filesystem unavailable");
  if(mf_join_path(upper,sizeof(upper),root,"upper")||mf_join_path(work,sizeof(work),root,"work"))mf_die("overlay child path exceeds bound");
  ensure_directory(upper,0700);ensure_directory(work,0700);
  if(mkdir(scratch,0700)&&errno!=EEXIST)mf_die("scratch mountpoint creation failed");
  int scratch_fd=open(scratch,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);if(scratch_fd<0)mf_die("scratch mountpoint unsafe");
  size_t count=0;char **names=names_at(scratch_fd,&count);close(scratch_fd);if(count==SIZE_MAX)mf_die("scratch mountpoint inventory failed");if(names)free_names(names,count);if(count)mf_die("scratch mountpoint must be empty");
  char options[MF_PATH_MAX*3];int length=snprintf(options,sizeof(options),"lowerdir=%s,upperdir=%s,workdir=%s",workspace,upper,work);
  if(length<=0||(size_t)length>=sizeof(options)||mount("overlay",scratch,"overlay",MS_NODEV|MS_NOSUID,options)||chown(scratch,65534,65534)||chmod(scratch,0700))mf_die("writable overlay mount failed");
}

static void write_policy(const struct options *o) {
  char path[MF_PATH_MAX],temporary[MF_PATH_MAX],body[MF_PATH_MAX*3];
  char policy_name[80],temporary_name[128];int policy_length=snprintf(policy_name,sizeof(policy_name),"policy-%s",o->profile_digest);int temporary_length=snprintf(temporary_name,sizeof(temporary_name),"policy-%s.tmp-%ld",o->profile_digest,(long)getpid());
  if(policy_length<=0||(size_t)policy_length>=sizeof(policy_name)||temporary_length<=0||(size_t)temporary_length>=sizeof(temporary_name)||mf_join_path(path,sizeof(path),MF_RUNTIME_DIR,policy_name)||mf_join_path(temporary,sizeof(temporary),MF_RUNTIME_DIR,temporary_name))mf_die("profile policy path exceeds bound");
  int length=snprintf(body,sizeof(body),"%s\n%s\n%lld\n%lld\n%lld\n%s\n%s\n%s\n%s\n%s\n",o->contract,o->profile_digest,o->cpu_seconds,o->process_limit,o->scratch_disk_mib,o->workspace,o->scratch,o->supervisor_digest,o->tool_registry_digest,o->executor_root_digest);
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
  prepare_overlay(o.workspace,o.scratch,o.profile_digest,o.scratch_disk_mib);write_policy(&o);
  dprintf(STDOUT_FILENO,"{\"contract\":\"moonfort-guest-v1\",\"profileDigest\":\"%s\",\"executorRootDigest\":\"%s\",\"guestAttesterDigest\":\"%s\",\"guestSupervisorDigest\":\"%s\",\"workspaceDigest\":\"%s\",\"workspacePath\":",o.profile_digest,o.executor_root_digest,self,supervisor,o.workspace_digest);mf_json_string(STDOUT_FILENO,o.workspace);
  dprintf(STDOUT_FILENO,",\"workspaceReadOnly\":true,\"scratchPath\":");mf_json_string(STDOUT_FILENO,o.scratch);
  dprintf(STDOUT_FILENO,",\"scratchWritable\":true,\"scratchIsolated\":true,\"scratchOverlay\":true,\"scratchLowerDigest\":\"%s\",\"scratchBaselineDigest\":\"%s\",\"scratchBaselineEntries\":%lld,\"scratchBaselineBytes\":\"%lld\",\"toolRegistryDigest\":\"%s\",\"supervisorPath\":",digest,digest,scan.entries,scan.bytes,registry);mf_json_string(STDOUT_FILENO,o.supervisor);
  dprintf(STDOUT_FILENO,",\"cpuSeconds\":%lld,\"processLimit\":%lld,\"scratchDiskMiB\":%lld}\n",o.cpu_seconds,o.process_limit,o.scratch_disk_mib);
}

static void inventory_command(int argc,char **argv){
  const char *contract=argument(argc,argv,"--contract"),*scratch=argument(argc,argv,"--scratch"),*profile=argument(argc,argv,"--profile-digest");
  long long disk=number_argument(argc,argv,"--disk-mib",1048576),maximum=number_argument(argc,argv,"--max-entries",4096);
  long long baseline_bytes=number_argument(argc,argv,"--baseline-bytes",LLONG_MAX),baseline_entries=number_argument(argc,argv,"--baseline-entries",1000000);
  if(!contract||strcmp(contract,"moonfort-guest-v1")||!mf_canonical_absolute(scratch)||!mf_valid_digest(profile))mf_die("inventory request is malformed");
  char policy[MF_PATH_MAX],policy_name[80],state[MF_PATH_MAX*3];
  int policy_name_length=snprintf(policy_name,sizeof(policy_name),"policy-%s",profile);
  if(policy_name_length<=0||(size_t)policy_name_length>=sizeof(policy_name)||mf_join_path(policy,sizeof(policy),MF_RUNTIME_DIR,policy_name)||mf_read_text_file(policy,state,sizeof(state))<0)mf_die("inventory policy unavailable");
  char saved_contract[64],saved_profile[MF_SHA256_HEX],workspace[MF_PATH_MAX],saved_scratch[MF_PATH_MAX],supervisor_digest[MF_SHA256_HEX],registry_digest[MF_SHA256_HEX],root_digest[MF_SHA256_HEX],extra;
  long long cpu=0,processes=0,saved_disk=0;
  int fields=sscanf(state,"%63[^\n]\n%64[a-f0-9]\n%lld\n%lld\n%lld\n%4095[^\n]\n%4095[^\n]\n%64[a-f0-9]\n%64[a-f0-9]\n%64[a-f0-9]\n%c",saved_contract,saved_profile,&cpu,&processes,&saved_disk,workspace,saved_scratch,supervisor_digest,registry_digest,root_digest,&extra);
  if(fields!=10||strcmp(saved_contract,contract)||strcmp(saved_profile,profile)||strcmp(saved_scratch,scratch)||saved_disk!=disk||!mf_canonical_absolute(workspace))mf_die("inventory is not bound to a prepared profile");
  int baseline_root=open(workspace,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);if(baseline_root<0)mf_die("workspace baseline unavailable");
  dprintf(STDOUT_FILENO,"{\"contract\":\"moonfort-guest-v1\",\"profileDigest\":\"%s\",\"baseline\":{\"entries\":[",profile);
  struct inventory baseline={.entries=0,.bytes=0,.maximum_entries=baseline_entries,.maximum_bytes=baseline_bytes,.emit_json=1,.first=1};walk_tree(&baseline,baseline_root,"",0);close(baseline_root);
  dprintf(STDOUT_FILENO,"],\"total_bytes\":\"%lld\"},\"inventory\":{\"entries\":[",baseline.bytes);
  int merged_root=open(scratch,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);if(merged_root<0)mf_die("merged scratch view unavailable");
  struct inventory current={.entries=0,.bytes=0,.maximum_entries=maximum,.maximum_bytes=disk*1048576LL,.emit_json=1,.first=1};walk_tree(&current,merged_root,"",0);close(merged_root);
  dprintf(STDOUT_FILENO,"],\"total_bytes\":\"%lld\"}}\n",current.bytes);
}

static int safe_relative_path(const char *path){
  if(!path||!*path||*path=='/'||strlen(path)>=MF_PATH_MAX||strchr(path,'\\')||strchr(path,'\n')||strchr(path,'\t'))return 0;
  const char *component=path;
  for(const char *cursor=path;;++cursor){
    if(*cursor=='/'||!*cursor){
      size_t length=(size_t)(cursor-component);
      if(!length||(length==1&&component[0]=='.')||(length==2&&component[0]=='.'&&component[1]=='.'))return 0;
      if(!*cursor)break;
      component=cursor+1;
    }
  }
  return 1;
}

static int open_regular_beneath(int root,const char *relative){
  char path[MF_PATH_MAX];size_t length=strlen(relative);memcpy(path,relative,length+1);
  int directory=dup(root);if(directory<0)return -1;
  char *save=NULL,*component=strtok_r(path,"/",&save);
  while(component){
    char *next=strtok_r(NULL,"/",&save);
    if(!next){int file=openat(directory,component,O_RDONLY|O_CLOEXEC|O_NOFOLLOW);close(directory);return file;}
    int child=openat(directory,component,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);close(directory);
    if(child<0)return -1;
    directory=child;component=next;
  }
  close(directory);return -1;
}

static void write_base64(const unsigned char *input,size_t length){
  static const char alphabet[]="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  size_t encoded_length=((length+2)/3)*4;char *encoded=malloc(encoded_length+1);if(!encoded)mf_die("export encoding allocation failed");
  size_t source=0,target=0;
  while(source<length){
    unsigned int value=(unsigned int)input[source++]<<16;int remaining=1;
    if(source<length){value|=(unsigned int)input[source++]<<8;++remaining;}
    if(source<length){value|=input[source++];++remaining;}
    encoded[target++]=alphabet[(value>>18)&63];encoded[target++]=alphabet[(value>>12)&63];
    encoded[target++]=remaining>=2?alphabet[(value>>6)&63]:'=';encoded[target++]=remaining==3?alphabet[value&63]:'=';
  }
  encoded[target]=0;mf_write_all(STDOUT_FILENO,encoded,target);free(encoded);
}

static void export_file(int argc,char **argv){
  const char *contract=argument(argc,argv,"--contract"),*scratch=argument(argc,argv,"--scratch"),*profile=argument(argc,argv,"--profile-digest"),*path=argument(argc,argv,"--path"),*fingerprint=argument(argc,argv,"--fingerprint"),*attester=argument(argc,argv,"--attester-digest");
  long long size=nonnegative_argument(argc,argv,"--size",8388608),maximum=number_argument(argc,argv,"--max-bytes",8388608);
  if(!contract||strcmp(contract,"moonfort-guest-v1")||!mf_canonical_absolute(scratch)||!mf_valid_digest(profile)||!safe_relative_path(path)||!mf_valid_digest(fingerprint)||!mf_valid_digest(attester)||size>maximum)mf_die("export request is malformed");
  char self[MF_SHA256_HEX];if(mf_hash_self(self)||strcmp(self,attester))mf_die("guest attester digest mismatch");
  char policy[MF_PATH_MAX],policy_name[80],state[MF_PATH_MAX*3];int policy_name_length=snprintf(policy_name,sizeof(policy_name),"policy-%s",profile);
  if(policy_name_length<=0||(size_t)policy_name_length>=sizeof(policy_name)||mf_join_path(policy,sizeof(policy),MF_RUNTIME_DIR,policy_name)||mf_read_text_file(policy,state,sizeof(state))<0)mf_die("export policy unavailable");
  char saved_contract[64],saved_profile[MF_SHA256_HEX],workspace[MF_PATH_MAX],saved_scratch[MF_PATH_MAX],supervisor_digest[MF_SHA256_HEX],registry_digest[MF_SHA256_HEX],root_digest[MF_SHA256_HEX],extra;long long cpu=0,processes=0,saved_disk=0;
  int fields=sscanf(state,"%63[^\n]\n%64[a-f0-9]\n%lld\n%lld\n%lld\n%4095[^\n]\n%4095[^\n]\n%64[a-f0-9]\n%64[a-f0-9]\n%64[a-f0-9]\n%c",saved_contract,saved_profile,&cpu,&processes,&saved_disk,workspace,saved_scratch,supervisor_digest,registry_digest,root_digest,&extra);
  if(fields!=10||strcmp(saved_contract,contract)||strcmp(saved_profile,profile)||strcmp(saved_scratch,scratch))mf_die("export is not bound to a prepared profile");
  int root=open(scratch,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);if(root<0)mf_die("export scratch root is unsafe");
  int file=open_regular_beneath(root,path);close(root);struct stat before,after;
  if(file<0||fstat(file,&before)||!S_ISREG(before.st_mode)||before.st_size!=size)mf_die("export source is not the expected regular file");
  char digest[MF_SHA256_HEX];if(mf_hash_fd(file,digest,before.st_size)||strcmp(digest,fingerprint))mf_die("export source fingerprint changed");
  size_t wanted=(size_t)size;unsigned char *chunk=malloc(wanted?wanted:1);if(!chunk)mf_die("export allocation failed");
  size_t used=0;while(used<wanted){ssize_t count=pread(file,chunk+used,wanted-used,(off_t)used);if(count<0&&errno==EINTR)continue;if(count<=0)mf_die("export source ended unexpectedly");used+=(size_t)count;}
  struct mf_sha256 payload_hash;unsigned char payload_raw[32];char payload_digest[MF_SHA256_HEX];mf_sha256_init(&payload_hash);mf_sha256_update(&payload_hash,chunk,used);mf_sha256_finish(&payload_hash,payload_raw);mf_hex(payload_raw,32,payload_digest);
  if(strcmp(payload_digest,fingerprint)||fstat(file,&after)||after.st_dev!=before.st_dev||after.st_ino!=before.st_ino||after.st_size!=before.st_size)mf_die("export source changed while reading");
  close(file);
  dprintf(STDOUT_FILENO,"{\"contract\":\"moonfort-guest-v1\",\"profileDigest\":\"%s\",\"guestAttesterDigest\":\"%s\",\"path\":",profile,self);mf_json_string(STDOUT_FILENO,path);
  dprintf(STDOUT_FILENO,",\"size\":\"%lld\",\"fingerprint\":\"%s\",\"payload\":\"",size,fingerprint);write_base64(chunk,used);mf_write_all(STDOUT_FILENO,"\"}\n",3);free(chunk);
}

static int sysctl_is_one(int directory,const char *name){
  int child=openat(directory,name,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);if(child<0)return 0;
  int file=openat(child,"disable_ipv6",O_RDONLY|O_CLOEXEC|O_NOFOLLOW);close(child);if(file<0)return 0;
  char value[4]={0};ssize_t used=read(file,value,sizeof(value));int saved=errno;close(file);errno=saved;
  return used==2&&value[0]=='1'&&value[1]=='\n';
}

static void network_attest(int argc,char **argv){
  const char *contract=argument(argc,argv,"--contract"),*expected=argument(argc,argv,"--attester-digest");
  if(!contract||strcmp(contract,"moonfort-guest-v1")||!mf_valid_digest(expected))mf_die("network attestation request is malformed");
  char self[MF_SHA256_HEX];if(mf_hash_self(self)||strcmp(self,expected))mf_die("guest attester digest mismatch");
  int root=open("/proc/sys/net/ipv6/conf",O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);
  if(root>=0){
    size_t count=0;char **names=names_at(root,&count);if(count==SIZE_MAX||!count)mf_die("IPv6 kernel state inventory failed");
    for(size_t index=0;index<count;++index)if(!sysctl_is_one(root,names[index]))mf_die("IPv6 is not disabled for every interface");
    free_names(names,count);close(root);
  }else if(errno!=ENOENT)mf_die("IPv6 kernel state is unavailable");
  dprintf(STDOUT_FILENO,"{\"contract\":\"moonfort-guest-v1\",\"guestAttesterDigest\":\"%s\",\"ipv6Disabled\":true}\n",self);
}

int main(int argc,char **argv){
  if(argc<2)mf_die("a fixed operation is required");
  if(!strcmp(argv[1],"prepare-and-attest"))prepare(argc,argv);
  else if(!strcmp(argv[1],"inventory"))inventory_command(argc,argv);
  else if(!strcmp(argv[1],"export-file"))export_file(argc,argv);
  else if(!strcmp(argv[1],"network-attest"))network_attest(argc,argv);
  else mf_die("operation is not allowed");
  return 0;
}
