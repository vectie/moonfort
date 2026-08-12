#include "runtime.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#ifndef MF_NETWORK_PROBE_IPV4
#error MF_NETWORK_PROBE_IPV4 must be a literal IPv4 address
#endif
#ifndef MF_NETWORK_PROBE_PORT
#error MF_NETWORK_PROBE_PORT must be defined
#endif
#ifndef MF_NETWORK_PROBE_EXPECTED
#error MF_NETWORK_PROBE_EXPECTED must be a fixed response token
#endif

#define REQUEST "MOONFORT_NETWORK_PROBE_V1\n"
#define RESPONSE MF_NETWORK_PROBE_EXPECTED "\n"
#define REACHABLE "MOONFORT_NETWORK_REACHABLE_V1\n"
#define BLOCKED "MOONFORT_NETWORK_BLOCKED_V1\n"

static int fail_kind(const char *kind,int code){dprintf(STDERR_FILENO,"moonfort network proof: %s\n",kind);return code;}
static int blocked(void){mf_write_all(STDOUT_FILENO,BLOCKED,sizeof(BLOCKED)-1);return 90;}

int main(int argc,char **argv){
  if(argc!=2||strcmp(argv[1],"probe"))return fail_kind("closed operation refused",64);
  struct sockaddr_in endpoint={.sin_family=AF_INET,.sin_port=htons(MF_NETWORK_PROBE_PORT)};
  if(inet_pton(AF_INET,MF_NETWORK_PROBE_IPV4,&endpoint.sin_addr)!=1)return fail_kind("compiled IPv4 endpoint invalid",65);
  int socket_fd=socket(AF_INET,SOCK_STREAM,0);if(socket_fd<0)return fail_kind("socket unavailable",66);
  if(fcntl(socket_fd,F_SETFD,FD_CLOEXEC)||fcntl(socket_fd,F_SETFL,O_NONBLOCK)){close(socket_fd);return fail_kind("socket flags unavailable",67);}
  if(connect(socket_fd,(struct sockaddr *)&endpoint,sizeof(endpoint))){
    if(errno==EACCES||errno==EPERM){close(socket_fd);return blocked();}
    if(errno==ECONNREFUSED){close(socket_fd);return fail_kind("connection refused",93);}
    if(errno!=EINPROGRESS){int error=errno;close(socket_fd);return fail_kind(error==ENETUNREACH||error==EHOSTUNREACH?"route unreachable":"connect failed",error==ENETUNREACH||error==EHOSTUNREACH?92:93);}
    struct pollfd poll_fd={.fd=socket_fd,.events=POLLOUT};int ready=poll(&poll_fd,1,2000);
    /* Corroborative only: the canary first proves this compiled endpoint
       reachable with its unrestricted profile. */
    if(ready==0){close(socket_fd);return blocked();}
    if(ready<0){close(socket_fd);return fail_kind("connect poll failed",95);}
    int error=0;socklen_t size=sizeof(error);if(getsockopt(socket_fd,SOL_SOCKET,SO_ERROR,&error,&size)){close(socket_fd);return fail_kind("connect status unavailable",96);}
    if(error==EACCES||error==EPERM){close(socket_fd);return blocked();}
    if(error==ECONNREFUSED){close(socket_fd);return fail_kind("connection refused",93);}
    if(error){close(socket_fd);return fail_kind(error==ENETUNREACH||error==EHOSTUNREACH?"route unreachable":"connect failed",error==ENETUNREACH||error==EHOSTUNREACH?92:93);}
  }
  int flags=fcntl(socket_fd,F_GETFL);if(flags<0||fcntl(socket_fd,F_SETFL,flags&~O_NONBLOCK)){close(socket_fd);return fail_kind("blocking transition failed",97);}
  struct timeval timeout={.tv_sec=2,.tv_usec=0};if(setsockopt(socket_fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout))||setsockopt(socket_fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout))){close(socket_fd);return fail_kind("I/O timeout unavailable",98);}
  if(mf_write_all(socket_fd,REQUEST,sizeof(REQUEST)-1)||shutdown(socket_fd,SHUT_WR)){close(socket_fd);return fail_kind("probe send failed",99);}
  char response[sizeof(RESPONSE)+1]={0};size_t used=0;for(;;){ssize_t count=read(socket_fd,response+used,sizeof(response)-1-used);if(count==0)break;if(count<0){close(socket_fd);return fail_kind(errno==EAGAIN||errno==EWOULDBLOCK?"response timeout":"response read failed",100);}used+=(size_t)count;if(used>=sizeof(response)-1){close(socket_fd);return fail_kind("response exceeds contract",101);}}
  close(socket_fd);if(used!=sizeof(RESPONSE)-1||memcmp(response,RESPONSE,sizeof(RESPONSE)-1))return fail_kind("unexpected endpoint response",102);
  mf_write_all(STDOUT_FILENO,REACHABLE,sizeof(REACHABLE)-1);return 0;
}
