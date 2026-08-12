#include "runtime.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define WORKSPACE "/workspace"
#define SCRATCH "/scratch"
#define LINK_NAME "moonfort-canary-symlink-proof"
#define DENIED "MOONFORT_SYMLINK_POLICY_DENIED_V1\n"

static int safe_relative(const char *path){
  if(!path||!*path||*path=='/'||strlen(path)>=MF_PATH_MAX||strstr(path,"//"))return 0;
  const char *part=path;for(const char *cursor=path;;++cursor)if(*cursor=='/'||!*cursor){size_t length=(size_t)(cursor-part);if(!length||(length==1&&part[0]=='.')||(length==2&&part[0]=='.'&&part[1]=='.'))return 0;if(!*cursor)break;part=cursor+1;}
  return 1;
}

static int generic(const char *reason,int code){dprintf(STDERR_FILENO,"moonfort symlink proof: %s\n",reason);return code;}

int main(int argc,char **argv){
  if(argc!=3||strcmp(argv[1],"probe")||!safe_relative(argv[2]))return generic("closed operation refused",64);
  int scratch=open(SCRATCH,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);if(scratch<0)return generic("fixed scratch unavailable",65);
  struct stat existing;if(!fstatat(scratch,LINK_NAME,&existing,AT_SYMLINK_NOFOLLOW)){close(scratch);return generic("fixed proof link already exists",66);}if(errno!=ENOENT){close(scratch);return generic("fixed proof link state unavailable",67);}
  if(symlinkat(WORKSPACE,scratch,LINK_NAME)){close(scratch);return generic("proof link creation failed",68);}
  char target[MF_PATH_MAX];int length=snprintf(target,sizeof(target),"%s/%s",LINK_NAME,argv[2]);if(length<=0||(size_t)length>=sizeof(target)){unlinkat(scratch,LINK_NAME,0);close(scratch);return generic("target exceeds bound",69);}
  int output=openat(scratch,target,O_WRONLY|O_TRUNC|O_CLOEXEC|O_NOFOLLOW);int saved=errno;
  if(output>=0){mf_write_all(output,"moonfort-canary",15);close(output);unlinkat(scratch,LINK_NAME,0);close(scratch);return generic("canonical mutation unexpectedly succeeded",92);}
  unlinkat(scratch,LINK_NAME,0);close(scratch);
  if(saved==EROFS||saved==EACCES||saved==EPERM){mf_write_all(STDOUT_FILENO,DENIED,sizeof(DENIED)-1);return 91;}
  return generic("write failed without policy-denial evidence",93);
}
