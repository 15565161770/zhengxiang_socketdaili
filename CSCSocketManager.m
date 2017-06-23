//
//  CSCSocketManager.m
//  cn.cloudScreen
//
//  Created by 丁祎 on 2017/3/29.
//  Copyright © 2017年 云屏科技. All rights reserved.
//

#import "CSCSocketManager.h"
#include <string.h>
#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <errno.h>
#import "HomeModel.h"
int g_fd;

int g_chclientfd = 0;

@implementation CSCSocketManager

+ (instancetype) sharedInstance {
    static CSCSocketManager * instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc]init];
    });
    return instance;
}


-(BOOL)startListen:(HomeModel *)homeModel {
    [self socket_init];
    self.homeModel = homeModel;
    NSLog(@"========startListen=======%@", homeModel.proxy_host);
    return YES;
}

- (void) stopListen {
    close(g_fd);
    NSLog(@"-----close g_fd = %d", g_fd);
}


// socket 初始化
-(void) socket_init
{
    int iret = 0 ;
    int on =1;
    
    NSLog(@"socket 初始化 =====%@", UserDefaultsGet(@"proxyModel"));
    struct sockaddr_in stLocal;
    socklen_t  socklen = sizeof(stLocal);

    g_fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (g_fd <= 0 ) {
        printf("socket create error!\n");
        return;
    }
    else
    {
        printf("socket create ok!fd=%d\n", g_fd);
    }
    
    setsockopt(g_fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
    
    setsockopt(g_fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
    
    stLocal.sin_family = AF_INET;
    stLocal.sin_addr.s_addr = inet_addr("127.0.0.1");
    
    stLocal.sin_port = htons(LOCALPORT);
    
    iret = bind(g_fd, (struct sockaddr *)&stLocal , socklen);
    if (iret != 0) {
        printf("bind error!iret=%d\n",iret);
    }
    else{
        printf("accept server bind ok!\n");
    }
    
    iret = listen(g_fd, 50);
    if (iret != 0) {
        printf("listen error!iret=%d\n",iret);
    }
    
    NSThread *threadtest = [[NSThread alloc]initWithTarget:self selector:@selector(sockaccept) object:@"nspthreadtest"];
    //启动线程
    [threadtest start];
}

// seversocket开始监听
-(void) sockaccept
{
    int localfd = 0;
    struct sockaddr_in stclient ;
    socklen_t socklen = sizeof(stclient);
    
    printf("waiting for accept...\n");
    while(1)
    {
        localfd = accept(g_fd, (struct sockaddr *)&stclient, &socklen );
        if (localfd <= 0 ) {
            printf("accept error!\n");
            close(g_fd);
            [NSThread exit];
            return;
        }
        else{
            printf("accept a new client addr=\n%s:%d, localfd=%d\n", inet_ntoa(stclient.sin_addr), ntohs(stclient.sin_port), localfd);
            
            //和真正的代理，建立一个TCP的链接
            NSThread *threadtest11 = [[NSThread alloc]initWithTarget:self selector:@selector(sockrecvlocal:) object: [NSNumber numberWithInt:localfd]];
            // 反向代理
//            NSThread *threadtest11 = [[NSThread alloc]initWithTarget:self selector:@selector(sockrecvlocalReverseProxy:) object: [NSNumber numberWithInt:localfd]];
            //启动线程
            [threadtest11 start];
        }
    }
}

// 接收到本地发出的http请求  正向代理
-(void)sockrecvlocal: (NSNumber *) localfd
{
    int newlocalfd = localfd.intValue;
    char acbuf[16384] = {0};
    int iret = 0;
    int isend = 0;
    int ileft = 0;
    int clientfd = 0;
    int on = 1;
    
    setsockopt(newlocalfd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
    
    NSLog(@"sockrecv client , newlocalfd=%d\n", newlocalfd);
    iret = [self proxyclient2server_init:newlocalfd newfd:&clientfd];
    if (0 != iret) {
        printf("proxyclient2server_init error, close newlocalfd=%d\n",  newlocalfd);
        close(newlocalfd);
        [NSThread exit];
        return;
    }
    
    while (1) {
        memset(acbuf, 0,16384);
        //signal(SIGPIPE, SIG_IGN);
        iret  = (int)recv(newlocalfd, acbuf, 16384, 0);
        if (iret <= 0) {
            printf("local socket recv error=%d, close localfd=%d, clientfd=%d\n", iret, newlocalfd, clientfd);
            close(newlocalfd);
            close(clientfd);
            [NSThread exit];
            return;
        } else {
            printf("local recv [buf]::\n%s, iret=%d\n",acbuf, iret);
            
            ileft = iret;
            char * newBuf = [self addHTTPHeaderWithPacketChar: acbuf];
            if (newBuf) {
                NSString * additionStr = [NSString stringWithFormat: @"\r\nProxy-Session-Id: %@", self.homeModel.proxy_token];
                
                ileft = iret + (int)strlen([additionStr UTF8String]);
                
                isend = proxyclientsend(clientfd, newBuf, ileft);
            }
            else
                isend = proxyclientsend(clientfd, acbuf, ileft);
            
            if (0 > isend) {
                printf("client socket send error=%d,close localfd=%d, clientfd=%d\n", isend, newlocalfd, clientfd);
                close(newlocalfd);
                close(clientfd);
                [NSThread exit];
                return;
            }
            else
            {
                ileft -=isend;
                if (ileft == 0) {
                    printf("send charles ok!ileft=%d, clientfd=%d, isend=%d\n", ileft, clientfd, isend);
                }
            }
        }
    }
}

// 接收到本地发出的http请求  反向代理模式处理
-(void)sockrecvlocalReverseProxy: (NSNumber *) localfd
{
    int newlocalfd = localfd.intValue;
    char acbuf[16384] = {0};
    int iret = 0;
    int isend = 0;
    int ileft = 0;
    int clientfd = 0;
    int on = 1;
    int flags = 0;
    
    setsockopt(newlocalfd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
    
    NSLog(@"sockrecv client , newlocalfd=%d\n", newlocalfd);
    iret = [self proxyclient2server_init:newlocalfd newfd:&clientfd];
    if (0 != iret) {
        printf("proxyclient2server_init error, close newlocalfd=%d\n",  newlocalfd);
        close(newlocalfd);
        [NSThread exit];
        return;
    }
    
    while (1) {
        memset(acbuf, 0,16384);
        //signal(SIGPIPE, SIG_IGN);
        iret  = (int)recv(newlocalfd, acbuf, 16384, 0);
        if (iret <= 0) {
            printf("local socket recv error=%d, close localfd=%d, clientfd=%d\n", iret, newlocalfd, clientfd);
            close(newlocalfd);
            close(clientfd);
            [NSThread exit];
            return;
        } else {
            printf("local recv [buf]::\n%s, iret=%d\n",acbuf, iret);
            
            NSString * acceptStr = [NSString stringWithUTF8String:acbuf];
            if (acceptStr.length > 7) {
                if ([[acceptStr substringToIndex: 7] isEqualToString: @"CONNECT"]) {
                    char * establishBuf = "HTTP/1.1 200 Connection established\r\n\r\n";
                    proxyclientsend(newlocalfd, establishBuf, (int)strlen(establishBuf));
                    continue;
                }
            }
            
            ileft = iret;
            
            char * newBuf;
            
            if (0 == flags) {       // 一条连接只加一次
                newBuf = [self addTCPHeaderWithPacketChar: acbuf];
                flags = 1;
            } else {
                newBuf = acbuf;
            }

            if (newBuf != acbuf) {
                ileft = iret + 8;
                isend = proxyclientsend(clientfd, newBuf, ileft);
            }
            else
                isend = proxyclientsend(clientfd, acbuf, ileft);
            
            if (0 > isend) {
                printf("client socket send error=%d,close localfd=%d, clientfd=%d\n", isend, newlocalfd, clientfd);
                close(newlocalfd);
                close(clientfd);
                [NSThread exit];
                return;
            }
            else
            {
                ileft -=isend;
                if (ileft == 0) {
                    printf("send charles ok!ileft=%d, clientfd=%d, isend=%d\n", ileft, clientfd, isend);
                }
            }
        }
    }
}

// 建立客户端socket连接到服务器
-(int)proxyclient2server_init: (int )localfd  newfd:(int *)newclientfd
{
    int iret = 0 ;
    struct sockaddr_in stLocal;
    socklen_t  socklen = sizeof(stLocal);
    int clientfd = 0;
    NSDictionary *dicarrinfo  = [[NSDictionary alloc] init];
    
    
    clientfd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (clientfd <= 0 ) {
        printf("client socket create error!\n");
        return -1;
    }
    else
    {
        printf("ch socket create ok!fd=%d, localfd=%d\n", clientfd,  localfd);
    }
    
    int on = 1;
    
    setsockopt(clientfd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
    
    NSString *stringOBJ = self.homeModel.proxy_host;
    const char *resultCString = NULL;
    if ([stringOBJ canBeConvertedToEncoding:NSUTF8StringEncoding]) {
        resultCString = [stringOBJ cStringUsingEncoding:NSUTF8StringEncoding];
    }
    
    stLocal.sin_family = AF_INET;
    stLocal.sin_addr.s_addr = inet_addr(resultCString);
    stLocal.sin_port = htons([self.homeModel.proxy_port intValue]);
    
    iret = connect(clientfd, (struct sockaddr *)&stLocal, socklen);
    if (0 != iret) {
        printf("connect err!\n");
        close(clientfd);
        [NSThread exit];
        return -1;
    }
    else
    {
        
        *newclientfd = clientfd;
        printf("connect ok!clientfd=%d\n", clientfd);
    }
    
    dicarrinfo= @{@"client": [NSNumber numberWithInt:clientfd], @"local": [NSNumber numberWithInt:localfd]};
    
    
    NSThread *threadtestrecv = [[NSThread alloc]initWithTarget:self selector:@selector(proxyclient2server_recv:) object: dicarrinfo];
    //启动线程
    [threadtestrecv start];
    
    return 0;
    
}

// 客户端接受到服务器返回的数据
-(void)proxyclient2server_recv: (NSDictionary *)arrayinfo
{
    int iret  = 0;
    char acbuf[16384]={0};
    int clientfd = 0;
    int localfd = 0;
    int ileft = 0;
    int isend = 0;
    NSNumber * clientNum = arrayinfo[@"client"];
    NSNumber * localNum = arrayinfo[@"local"];
    
    clientfd = clientNum.intValue;
    localfd = localNum.intValue;
    
    printf("client2server recv, clientfd=%d, localfd=%d\n", clientfd, localfd);
    
    while (1) {
        
        memset(acbuf, 0 , 16384);
        
        iret = (int)recv(clientfd,acbuf, 16384,0);
        if (0 >= iret) {
            printf("charles server recv error!iret=%d,errno=%d, clientfd=%d\n", iret, errno,  clientfd);
            if (0 == iret) {
                printf("charles server close connect!clientfd=%d\n", clientfd);
            }
            close(clientfd);
            close(localfd);
            [NSThread exit];
            return;
        }
        else
        {
            printf("recv charles buf=\n%s, len=%d\n", acbuf, iret);
            ileft = iret;
            while(1)
            {
                isend = proxyclientsend(localfd, acbuf, ileft);
                if (0 > isend) {
                    printf("client socket send error=%d, clientfd=%d, localfd=%d\n", isend, clientfd, localfd);
                    close(localfd);
                    close(clientfd);
                    [NSThread exit];
                    return;
                }
                else
                {
                    ileft -=isend;
                    if (ileft == 0) {
                        printf("send ok!ileft=%d\n", ileft);
                        break;
                    }
                }
            }
        }
    }
}

// 客户端转发接收到的请求数据
int proxyclientsend(int sockfd, char *pcbuf, int len)
{
    int iret  =0;
    int ileft =0;
    int icount = 0;
    
    if (NULL == pcbuf) {
        return -1;
    }

    ileft = len;
    while(1)
    {
        iret = (int)send(sockfd, pcbuf, ileft, 0 );
        
        printf("send [buf]::\n%s, iret=%d, errno=%d, len=%d\n",pcbuf, iret, errno,len);
        
        if (0 >= iret && errno != 0) {
            
            printf("forward to the charles server error!iret= %d\n", iret);
            if (-35 == iret) {
                continue;
            }
            close(sockfd);
            [NSThread exit];
            
            return -1;
        }
        else{
            icount++;
            if (icount > 10) {
                break;
            }
            ileft -= iret;
            printf("forward to the charles server successful! iret= %d, ileft=%d\n", iret, ileft);
            if (ileft == 0) {
                printf("left is zero!\n");
                break;
            }
        }
        
    }
    
    return iret;
}

//#pragma mark --  判断请求
//- (BOOL)JudgeRequests:(char [])acbuf {
//    NSLog(@"判断请求=========%s", acbuf);
//    // 逻辑判断
//    
//    char *strChar;
//    strChar = (char *)malloc(sizeof(char) * (sizeof(acbuf) + 1));
//    
//    strncpy(strChar, acbuf, sizeof(acbuf));
//    
//    NSString *str = [NSString stringWithCString:strChar encoding:NSUTF8StringEncoding];
//    if([str rangeOfString:@"CONNECT"].location !=NSNotFound){
//        return YES;
//    } else if ([str rangeOfString:@"GET"].location !=NSNotFound){
//        return YES;
//    } else if ([str rangeOfString:@"POST"].location !=NSNotFound) {
//        return  YES;
//    }
//    return NO;
//}

#pragma mark -- http头出添加信息

- (char *) addHTTPHeaderWithPacketChar: (char *) packet {
    
    NSString * resultStr;
    
    NSString * packetStr = [NSString stringWithUTF8String:packet];
    
    NSString * additionStr = [NSString stringWithFormat: @"\r\nProxy-Session-Id: %@", self.homeModel.proxy_token];
    
    if (packetStr) {
        if ([packetStr containsString:@"Connection: keep-alive\r\n"]
            && ([packetStr containsString:@"CONNECT "]
                || [packetStr containsString:@"GET "] || [packetStr containsString:@"POST "] )) {
                resultStr = [packetStr stringByReplacingOccurrencesOfString:@"\r\nConnection: keep-alive" withString:[NSString stringWithFormat: @"%@\r\nConnection: keep-alive", additionStr] ];
                
                char * packetedChar = (char *)[resultStr UTF8String];
                
                return packetedChar;
            }
        
        return nil;
    } else {
        return nil;
    }
}

- (char *) addTCPHeaderWithPacketChar: (char *) packet {
    
    NSString * resultStr;
    
    NSString * packetStr = [NSString stringWithUTF8String:packet];
    
    NSString * additionStr = @"12345678";
    
    if (packetStr) {
        resultStr = [NSString stringWithFormat:@"%@%@", additionStr, packetStr];
        char * packetedChar = (char *)[resultStr UTF8String];
        return packetedChar;
    } else {
        return nil;
    }
}


@end
