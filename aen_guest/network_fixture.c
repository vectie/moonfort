#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define REQUEST "MOONFORT_NETWORK_PROBE_V1\n"
#define RESPONSE "MOONFORT_NETWORK_ENDPOINT_V1\n"

static int write_all(int fd,const char *data,size_t length){while(length){ssize_t count=write(fd,data,length);if(count<0&&errno==EINTR)continue;if(count<=0)return -1;data+=count;length-=(size_t)count;}return 0;}

int main(int argc,char **argv){
  if(argc!=3||(strcmp(argv[2],"exact")&&strcmp(argv[2],"bad")))return 64;
  char *end=NULL;long port=strtol(argv[1],&end,10);if(!end||*end||port<1||port>65535)return 64;
  int listener=socket(AF_INET,SOCK_STREAM,0);if(listener<0)return 65;
  int reuse=1;if(setsockopt(listener,SOL_SOCKET,SO_REUSEADDR,&reuse,sizeof(reuse)))return 65;
  struct sockaddr_in address={.sin_family=AF_INET,.sin_port=htons((unsigned short)port)};
  if(inet_pton(AF_INET,"127.0.0.1",&address.sin_addr)!=1||bind(listener,(struct sockaddr *)&address,sizeof(address))||listen(listener,1))return 65;
  int client=accept(listener,NULL,NULL);if(client<0)return 66;
  char request[sizeof(REQUEST)]={0};size_t used=0;
  while(used<sizeof(REQUEST)-1){ssize_t count=read(client,request+used,sizeof(REQUEST)-1-used);if(count<0&&errno==EINTR)continue;if(count<=0)return 67;used+=(size_t)count;}
  if(memcmp(request,REQUEST,sizeof(REQUEST)-1))return 68;
  const char *response=strcmp(argv[2],"exact")?"WRONG\n":RESPONSE;
  int result=write_all(client,response,strlen(response));close(client);close(listener);return result?69:0;
}
