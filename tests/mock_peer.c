/* Independent test-only TLS peer; never linked into the Lean listener. */
#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE
#include <openssl/ssl.h>
#include <openssl/ec.h>
#include <openssl/ecdsa.h>
#include <openssl/sha.h>
#include <openssl/bn.h>
#include <openssl/pem.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <signal.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <poll.h>

static const char *alphabet = "rpshnaf39wBUDNEGHJKLM4PQRST7VWXYZ2bcdeCg65jkm8oFqi1tuvAxyz";
static void require(int ok, const char *message) { if (!ok) { fprintf(stderr, "%s\n", message); exit(1); } }
static void pub58(const unsigned char *pub, char *out) {
  unsigned char body[38], hash[32]; body[0] = 28; memcpy(body+1,pub,33);
  SHA256(body,34,hash); SHA256(hash,32,hash); memcpy(body+34,hash,4);
  BIGNUM *n=BN_bin2bn(body,38,NULL); char rev[100]; int count=0;
  while (!BN_is_zero(n)) rev[count++]=alphabet[BN_div_word(n,58)];
  for (int i=0;i<count;i++) out[i]=rev[count-i-1]; out[count]=0; BN_free(n);
}
static EC_KEY *decode_pub58(const char *str) {
  BIGNUM *n=BN_new(); BN_zero(n); unsigned char body[38],hash[32];
  for (const char *p=str;*p;p++) {
    const char *ch=strchr(alphabet,*p); require(ch!=NULL,"bad client base58");
    BN_mul_word(n,58); BN_add_word(n,(BN_ULONG)(ch-alphabet));
  }
  require(BN_num_bytes(n)==38,"bad client key length"); BN_bn2bin(n,body); BN_free(n);
  SHA256(body,34,hash); SHA256(hash,32,hash);
  require(body[0]==28 && memcmp(body+34,hash,4)==0,"bad client checksum");
  EC_KEY *key=EC_KEY_new_by_curve_name(NID_secp256k1); const unsigned char *p=body+1;
  require(o2i_ECPublicKey(&key,&p,33)!=NULL,"invalid client public key"); return key;
}
static void header(const char *request, const char *name, char *out, size_t cap) {
  char prefix[80]; snprintf(prefix,sizeof prefix,"\r\n%s: ",name);
  const char *p=strstr(request,prefix); require(p!=NULL,"missing client handshake header"); p+=strlen(prefix);
  const char *end=strstr(p,"\r\n"); require(end && (size_t)(end-p)<cap,"bad client header length");
  memcpy(out,p,(size_t)(end-p)); out[end-p]=0;
}
static void write_all(SSL *ssl,const unsigned char *data,size_t n) {
  while(n) { int wrote=SSL_write(ssl,data,(int)n); require(wrote>0,"TLS write failed"); data+=wrote;n-=wrote; }
}
static size_t frame(unsigned char *out,unsigned type,const unsigned char *payload,size_t n) {
  out[0]=(unsigned char)(n>>24); out[1]=(unsigned char)(n>>16); out[2]=(unsigned char)(n>>8); out[3]=(unsigned char)n;
  out[4]=(unsigned char)(type>>8);out[5]=(unsigned char)type;memcpy(out+6,payload,n);return n+6;
}
static size_t varint(unsigned char *out,size_t n) {
  size_t i=0; do {out[i++]=(unsigned char)((n&127)|(n>=128?128:0));n>>=7;}while(n);return i;
}
static const char *ledger_folder;
static int state_hash_only;
static int state_capped;
static int state_sync_mode;
static int storage_probe_mode;
static int probe_round_announced;
static int sync_reset_remaining;
static char sync_advanced[64][65];
static size_t sync_advanced_count;
static uint64_t monotonic_ms(void) {
  struct timespec t;require(clock_gettime(CLOCK_MONOTONIC,&t)==0,"clock failed");
  return (uint64_t)t.tv_sec*1000+(uint64_t)t.tv_nsec/1000000;
}
static void send_file(SSL *ssl, const char *path) {
  FILE *file=fopen(path,"rb");require(file!=NULL,"ledger fixture file missing");
  unsigned char buffer[8192];size_t n;
  while((n=fread(buffer,1,sizeof buffer,file)))write_all(ssl,buffer,n);
  require(!ferror(file),"ledger fixture read failed");fclose(file);
}
static void ledger_reply(SSL *ssl,const unsigned char *p,size_t n) {
  require(n>=36 && p[0]==8 && p[1]<=2 && p[2]==26 && p[3]==32,"forbidden ledger query");
  unsigned kind=p[1];char hash[65],path[1024];
  for(int i=0;i<32;i++)sprintf(hash+2*i,"%02X",p[4+i]);
  if(kind==0)require(n==36,"base query has unexpected fields");
  else {
    size_t at=36,ids=0;
    if(kind==2) {
      require(at<n && p[at++]==32,"state query omitted sequence");
      uint64_t seq=0;unsigned shift=0,byte;
      do {require(at<n && shift<35,"bad state sequence");byte=p[at++];seq|=(uint64_t)(byte&127)<<shift;shift+=7;} while(byte&128);
      require(seq>0 && seq<=UINT32_MAX,"invalid state sequence");
    }
    size_t first_id=at+2;
    while(at+35<=n && p[at]==42){require(p[at+1]==33 && p[at+34]<=64,"bad node query ID");at+=35;ids++;}
    if(kind==2) {require(at+2<n && p[at]==56 && p[at+1]==0,"state query omitted indirect routing");at+=2;}
    require(ids>=1 && ids<=(kind==2?256:16) && at+2==n && p[at]==64 &&
      (kind==2?p[at+1]<=3:p[at+1]==2),"forbidden tree query fields");
    if(kind==2 && state_capped) {
      char ident[67];for(int i=0;i<33;i++)sprintf(ident+2*i,"%02X",p[first_id+i]);
      snprintf(path,sizeof path,"%s/capped-%s.bin",ledger_folder,ident);
      send_file(ssl,path);return;
    }
  }
  snprintf(path,sizeof path,"%s/%s-%s.bin",ledger_folder,kind==0?"base":kind==2?"state":"tree",hash);
  if(kind==2 && state_hash_only)return;
  if(kind==2) {
    char hold[1024];snprintf(hold,sizeof hold,"%s/hold-state-%s",ledger_folder,hash);
    if(access(hold,F_OK)==0)return;
  }
  send_file(ssl,path);
  if(state_sync_mode && kind==0 && !(storage_probe_mode && probe_round_announced)) {
    snprintf(path,sizeof path,"%s/advance-%s.bin",ledger_folder,hash);
    FILE *next=fopen(path,"rb");
    if(next) {
      fclose(next);int sent=0;
      for(size_t i=0;i<sync_advanced_count;i++)if(!strcmp(sync_advanced[i],hash))sent=1;
      if(!sent){require(sync_advanced_count<64,"too many sync advances");strcpy(sync_advanced[sync_advanced_count++],hash);sleep(1);send_file(ssl,path);}
    }
  }
}
static uint64_t take_varint(const unsigned char *p,size_t *at,size_t n) {
  uint64_t value=0;unsigned shift=0,byte;
  do {require(*at<n && shift<35,"bad object query varint");byte=p[(*at)++];value|=(uint64_t)(byte&127)<<shift;shift+=7;}while(byte&128);
  return value;
}
static void object_reply(SSL *ssl,const unsigned char *p,size_t n) {
  require(n>=38 && p[0]==8 && p[1]==4 && p[2]==16 && p[3]==1 && p[4]==34 && p[5]==32,"forbidden object query");
  size_t at=38,count=0;
  while(at<n) {
    require(p[at++]==50,"bad object field");size_t len=take_varint(p,&at,n),end=at+len;
    require(end<=n && len>=70 && p[at]==10 && p[at+1]==32,"bad object hash");
    char hash[65],path[1024];for(int i=0;i<32;i++)sprintf(hash+2*i,"%02X",p[at+2+i]);at+=34;
    require(at+35<=end && p[at]==18 && p[at+1]==33 && p[at+34]<=64,"bad object node ID");at+=35;
    require(at<end && p[at++]==40,"object query omitted sequence");uint64_t seq=take_varint(p,&at,end);
    require(seq>0 && seq<=UINT32_MAX && at==end && ++count<=64,"forbidden object query fields");
    snprintf(path,sizeof path,"%s/object-%s.bin",ledger_folder,hash);send_file(ssl,path);
  }
  require(count>0,"empty object query");
}
static void session(SSL_CTX *ctx,int fd,EC_KEY *node,const unsigned char *tx,size_t txlen,const char *mode) {
  struct timeval timeout={(!strcmp(mode,"keepalive")||!strcmp(mode,"hash-only")||state_sync_mode)?70:5,0}; setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof timeout);
  SSL *ssl=SSL_new(ctx); SSL_set_fd(ssl,fd);require(SSL_accept(ssl)==1,"TLS accept failed");
  unsigned char a[1024],b[1024],ha[64],hb[64],mix[64],digest[64];
  size_t na=SSL_get_finished(ssl,a,sizeof a),nb=SSL_get_peer_finished(ssl,b,sizeof b);
  require(na>=12 && nb>=12,"Finished missing");SHA512(a,na,ha);SHA512(b,nb,hb);
  for(int i=0;i<64;i++)mix[i]=ha[i]^hb[i];SHA512(mix,64,digest);
  char req[32768]={0};size_t used=0;
  while(!strstr(req,"\r\n\r\n")) {int n=SSL_read(ssl,req+used,(int)(sizeof req-used-1));require(n>0,"HTTP request read failed");used+=(size_t)n;req[used]=0;require(used<sizeof req-1,"HTTP request too big");}
  require(strstr(req,"\r\nCrawl: private\r\n")!=NULL,"listener must request private crawl");
  require(strstr(req,"\r\nX-Protocol-Ctl:\r\n")!=NULL,"features must be disabled");
  char pk[128],encoded[128];header(req,"Public-Key",pk,sizeof pk);header(req,"Session-Signature",encoded,sizeof encoded);
  EC_KEY *client=decode_pub58(pk);unsigned char sig[100];
  int siglen=EVP_DecodeBlock(sig,(const unsigned char*)encoded,(int)strlen(encoded));
  size_t encodedlen=strlen(encoded);if(encodedlen&&encoded[encodedlen-1]=='=')siglen--;if(encodedlen>1&&encoded[encodedlen-2]=='=')siglen--;
  require(siglen>0 && ECDSA_verify(0,digest,32,sig,siglen,client)==1,"client session signature invalid");EC_KEY_free(client);
  unsigned char pub[33];EC_POINT_point2oct(EC_KEY_get0_group(node),EC_KEY_get0_public_key(node),POINT_CONVERSION_COMPRESSED,pub,sizeof pub,NULL);
  char pubstr[100];pub58(pub,pubstr);unsigned int slen=0;
  require(ECDSA_sign(0,digest,32,sig,&slen,node)==1,"server signature failed");
  if(!strcmp(mode,"bad-signature"))sig[slen-1]^=1;
  EVP_EncodeBlock((unsigned char*)encoded,sig,(int)slen);
  char response[2048];int n=snprintf(response,sizeof response,
    "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: XRPL/2.2\r\nConnect-As: Peer\r\nPublic-Key: %s\r\nSession-Signature: %s\r\nNetwork-ID: 0\r\nNetwork-Time: %ld\r\n%s\r\n",
    pubstr,encoded,(long)time(NULL)-946684800,!strcmp(mode,"features")?"X-Protocol-Ctl: compr=lz4\r\n":"");
  unsigned char *packet=malloc(txlen*4+4096),*payload=malloc(txlen+64);require(packet&&payload,"test allocation failed");
  memcpy(packet,response,(size_t)n);size_t total=(size_t)n;
  payload[0]=10;size_t plen=1+varint(payload+1,txlen);memcpy(payload+plen,tx,txlen);plen+=txlen;
  payload[plen++]=16;payload[plen++]=2; /* TMTransaction status current */
  total+=frame(packet+total,30,payload,plen);
  unsigned char *batch=malloc(plen*2+32);size_t blen=0;
  for(int i=0;i<2;i++){batch[blen++]=10;blen+=varint(batch+blen,plen);memcpy(batch+blen,payload,plen);blen+=plen;}
  total+=frame(packet+total,64,batch,blen);free(batch);
  unsigned char ping[]={8,0,16,42};total+=frame(packet+total,3,ping,sizeof ping);
  unsigned char unknown[]={10,1,0};total+=frame(packet+total,99,unknown,sizeof unknown);
  /* Fragment the HTTP prefix, then coalesce its remainder with overlay frames. */
  write_all(ssl,packet,3);write_all(ssl,packet+3,total-3);free(packet);free(payload);
  if(ledger_folder){char path[1024];snprintf(path,sizeof path,"%s/validations.bin",ledger_folder);send_file(ssl,path);}
  unsigned char incoming[131072];size_t have=0;unsigned controls=0,ledger_requests=0;
  uint64_t probe_sent=0;int probe_done=0;
  while(1){
    if(storage_probe_mode) {
      char path[1024];snprintf(path,sizeof path,"%s/storage-probe",ledger_folder);
      if(!probe_sent && access(path,F_OK)==0) {
        unlink(path);
        /* A new validation round exercises a database-writing peer callback. */
        snprintf(path,sizeof path,"%s/votes-126.bin",ledger_folder);send_file(ssl,path);
        probe_round_announced=1;
        snprintf(path,sizeof path,"%s/probe-state.bin",ledger_folder);
        if(access(path,F_OK)==0)send_file(ssl,path);
        unsigned char p[]={8,0,16,43},out[10];probe_sent=monotonic_ms();
        write_all(ssl,out,frame(out,3,p,sizeof p));
        snprintf(path,sizeof path,"%s/probe-sent",ledger_folder);
        FILE *f=fopen(path,"w");require(f!=NULL,"probe marker failed");fclose(f);
      }
      if(!SSL_pending(ssl)) {
        struct pollfd p={fd,POLLIN,0};int ready=poll(&p,1,50);
        require(ready>=0,"probe poll failed");if(!ready)continue;
      }
    }
    int count=SSL_read(ssl,incoming+have,(int)(sizeof incoming-have));if(count<=0)break;have+=(size_t)count;
    while(have>=6){
      size_t len=((size_t)incoming[0]<<24)|((size_t)incoming[1]<<16)|((size_t)incoming[2]<<8)|incoming[3];
      unsigned type=((unsigned)incoming[4]<<8)|incoming[5];require(len<sizeof incoming-6,"oversize client frame");if(have<len+6)break;
      if(type==31 && ledger_folder){
        if(sync_reset_remaining){
          sync_reset_remaining=0;struct linger rst={1,0};
          require(setsockopt(fd,SOL_SOCKET,SO_LINGER,&rst,sizeof rst)==0,"set reset linger failed");
          puts("sync_connection_reset=1");fflush(stdout);have=0;goto finished;
        }
        ledger_reply(ssl,incoming+6,len);ledger_requests++;memmove(incoming,incoming+len+6,have-len-6);have-=len+6;continue;
      }
      if(type==42 && ledger_folder){object_reply(ssl,incoming+6,len);ledger_requests++;memmove(incoming,incoming+len+6,have-len-6);have-=len+6;continue;}
      require(type==3,"listener sent a forbidden outbound overlay message");
      require(len>=4 && incoming[6]==8 && incoming[7]<=1 && incoming[8]==16,"invalid ping/pong payload");
      if(incoming[7]==1) {
        require(len==4 && (incoming[9]==42 || (storage_probe_mode && probe_sent && incoming[9]==43)),"expected sequence-matching pong");
        if(incoming[9]==43){
          char path[1024];snprintf(path,sizeof path,"%s/probe-pong",ledger_folder);
          FILE *f=fopen(path,"w");require(f!=NULL,"probe pong marker failed");
          fprintf(f,"%llu\n",(unsigned long long)(monotonic_ms()-probe_sent));fclose(f);probe_done=1;
        }
      }
      else {require(!strcmp(mode,"keepalive"),"unexpected proactive ping");incoming[7]=1;write_all(ssl,incoming,len+6);}
      controls++;memmove(incoming,incoming+len+6,have-len-6);have-=len+6;
      if(!strcmp(mode,"reconnect")){have=0;goto finished;}
    }
  }
finished:
  if(storage_probe_mode)require(controls==2 && probe_done,"expected both pongs during blocked storage");
  else if(ledger_folder)require(controls==1,"expected sequence-matching pong in ledger mode");
  else if(!strcmp(mode,"good")||!strcmp(mode,"reconnect"))require(controls==1,"expected exactly one pong");
  else if(!strcmp(mode,"keepalive"))require(controls>=2,"expected pong and periodic ping");
  else require(controls==0,"unauthenticated peer elicited overlay writes");
  printf("client_signature=valid outbound_controls=%u ledger_requests=%u\n",controls,ledger_requests);fflush(stdout);
  SSL_free(ssl);close(fd);
}
int main(int argc,char **argv){
  require(argc==7||argc==8,"usage: mock_peer PORT CERT KEY TX MODE CONNECTIONS [LEDGER_FIXTURES]");signal(SIGPIPE,SIG_IGN);
  if(argc==8)ledger_folder=argv[7];
  state_hash_only=!strcmp(argv[5],"hash-only");
  state_capped=!strcmp(argv[5],"capped");
  storage_probe_mode=!strcmp(argv[5],"storage-probe");
  state_sync_mode=!strcmp(argv[5],"state-sync")||!strcmp(argv[5],"state-sync-reset")||storage_probe_mode;
  sync_reset_remaining=!strcmp(argv[5],"state-sync-reset");
  SSL_CTX *ctx=SSL_CTX_new(TLS_server_method());SSL_CTX_set_min_proto_version(ctx,TLS1_2_VERSION);SSL_CTX_set_max_proto_version(ctx,TLS1_2_VERSION);
  require(SSL_CTX_use_certificate_file(ctx,argv[2],SSL_FILETYPE_PEM)==1,"certificate failed");
  require(SSL_CTX_use_PrivateKey_file(ctx,argv[3],SSL_FILETYPE_PEM)==1,"certificate key failed");
  EC_KEY *node=EC_KEY_new_by_curve_name(NID_secp256k1);require(EC_KEY_generate_key(node)==1,"node generation failed");
  FILE *f=fopen(argv[4],"rb");require(f!=NULL,"transaction file missing");unsigned char tx[4096];size_t txlen=fread(tx,1,sizeof tx,f);fclose(f);
  int server=socket(AF_INET,SOCK_STREAM,0),one=1;setsockopt(server,SOL_SOCKET,SO_REUSEADDR,&one,sizeof one);
  struct sockaddr_in addr={0};addr.sin_family=AF_INET;addr.sin_addr.s_addr=htonl(INADDR_LOOPBACK);addr.sin_port=htons((uint16_t)atoi(argv[1]));
  require(bind(server,(struct sockaddr*)&addr,sizeof addr)==0 && listen(server,4)==0,"test listener bind failed");
  socklen_t alen=sizeof addr;getsockname(server,(struct sockaddr*)&addr,&alen);printf("port=%u\n",ntohs(addr.sin_port));fflush(stdout);
  for(int i=0;i<atoi(argv[6]);i++){int fd=accept(server,NULL,NULL);require(fd>=0,"accept failed");session(ctx,fd,node,tx,txlen,argv[5]);}
  close(server);EC_KEY_free(node);SSL_CTX_free(ctx);return 0;
}
