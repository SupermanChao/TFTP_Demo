//
//  TFTPClient.m
//  TFTP_Demo
//
//  Created by 刘超 on 2017/12/22.
//  Copyright © 2017年 刘超. All rights reserved.
//

#import "TFTPClient.h"
#include <stdio.h>
#include<errno.h>
#include<sys/socket.h>
#import <arpa/inet.h>
#include <sys/time.h>

#define TFTP_RRQ   1   //读请求
#define TFTP_WRQ   2   //写请求
#define TFTP_DATA  3   //数据
#define TFTP_ACK   4   //ACK确认
#define TFTP_ERROR 5   //Error

#define MAX_RETRY          3              //最大重复请求次数
#define TFTP_BlockSize     512            //每个数据包截取文件的大小(相对发送包而言,这个是去掉操作码和块号剩余的大小)

@interface TFTPClientPacket : NSObject
/**
 *  @brief  制作RRQ数据包 -> 文件请求包
 *
 *  @param  filename    文件名
 *  @param  sendBuffer  发送数据包缓冲区
 *  @return 需要发送数据的长度
 */
+ (NSUInteger)makeRRQWithFileName:(NSString *)filename
                       sendBuffer:(char[])sendBuffer;
/**
 *  @brief  制作ACK数据包 -> 文件确认包
 *
 *  @param  blocknum    确认块号
 *  @param  sendBuffer  发送数据包缓冲区
 *  @return 需要发送数据的长度
 */
+ (NSUInteger)makeACKWithBlockNum:(int)blocknum
                       sendBuffer:(char[])sendBuffer;
/**
 *  @brief  填充差错包
 *
 *  @param  code        差错码
 *  @param  reason      差错信息
 *  @param  sendBuffer  要发送数据缓存区
 *  @return 返回取药发送数据包长度
 */
+ (NSUInteger)makeErrorDataWithCode:(ushort)code
                             reason:(char *)reason
                         sendBuffer:(char[])sendBuffer;
@end

@implementation TFTPClientPacket

+ (NSUInteger)makeRRQWithFileName:(NSString *)filename sendBuffer:(char [])sendBuffer
{
    //操作码(2byte) + 文件名(Nbyte) + 模式(N字节)
    
    sendBuffer[0] = 0;
    sendBuffer[1] = TFTP_RRQ;
    
    const char *cFileName = filename.UTF8String;
    NSUInteger cFileLen = strlen(cFileName);
    memcpy(&sendBuffer[2], cFileName, cFileLen);
    
    return (2 + cFileLen);
}

+ (NSUInteger)makeACKWithBlockNum:(int)blocknum sendBuffer:(char[])sendBuffer
{
    //操作码(2byte) + 块号(2byte)
    
    sendBuffer[0] = 0;
    sendBuffer[1] = TFTP_ACK;
    
    sendBuffer[2] = blocknum >> 8;
    sendBuffer[3] = blocknum;
    return 4;
}

+ (NSUInteger)makeErrorDataWithCode:(ushort)code reason:(char *)reason sendBuffer:(char[])sendBuffer
{
    //操作码(2byte) + 差错码(2byte) + 差错信息(N byte)
    sendBuffer[0] = 0;
    sendBuffer[1] = TFTP_ERROR;
    
    sendBuffer[2] = code >> 8;
    sendBuffer[3] = code;
    
    NSUInteger len = strlen(reason);
    memcpy(&sendBuffer[4], reason, len);
    
    return (4 + len);
}
@end


@interface TFTPClient () {
    int _sockfd;
    uint _blocknum;
}
@property (nonatomic, strong) NSMutableData *fileData;
@property (nonatomic, copy) void(^progressBlock)(NSUInteger recvDataLen, int blocknum);
@property (nonatomic, copy) void(^resultBlock)(NSData *fileData, NSError *error);
@end

@implementation TFTPClient

- (void)connectToHost:(NSString *)host port:(uint16_t)port fileName:(NSString *)filename downLoadProgress:(void(^)(NSUInteger recvDataLen, int blocknum))progressBlock result:(void(^)(NSData *fileData, NSError *error))resultBlock
{
    if (host == nil || port == 0 || filename == nil) {
        NSAssert(host && port && filename, @"一些初始化参数不能为空");
        return;
    };
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        
        NSLog(@"[TFTPClient] 开始下载数据");
        _isOpen = YES;
        
        if (progressBlock) self.progressBlock = progressBlock;
        if (resultBlock) self.resultBlock = resultBlock;
        
        //初始化套接字
        _sockfd = socket(AF_INET, SOCK_DGRAM, 0);
        
        if (_sockfd <= 0) {
            [self throwErrorWithCode:errno reason:@"Failed to create socket"];
            return ;
        }
        
        struct sockaddr_in addr_bind;
        addr_bind.sin_len = sizeof(struct sockaddr_in);
        addr_bind.sin_family = AF_INET;
        addr_bind.sin_port = htons(port);
        addr_bind.sin_addr.s_addr = htonl(INADDR_ANY);
        
        if (bind(_sockfd, (struct sockaddr*)&addr_bind, addr_bind.sin_len) < 0) {
            [self throwErrorWithCode:errno reason:@"Binding socket failed"];
            return;
        }

        //注册套接字目的地址
        struct sockaddr_in addr_server;
        addr_server.sin_len = sizeof(struct sockaddr_in);
        addr_server.sin_family = AF_INET;
        addr_server.sin_port = htons(port);
        inet_pton(AF_INET, host.UTF8String, &addr_server.sin_addr);
        
        if (connect(_sockfd, (struct sockaddr*)&addr_server, addr_server.sin_len) < 0) {
            [self throwErrorWithCode:errno reason:@"Registration destination address failed"];
            return;
        }
        
        //设置读取数据超时
        struct timeval timeout = {6, 0};
        if (setsockopt(_sockfd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(struct timeval)) < 0) {
            printf("[TFTPClient] 设置接收数据超时失败：%s",strerror(errno));
        }
        
        //发送文件请求包, 开始下载文件
        [self sendFileRequestDataWithFilename:filename];
    });
}

///外部调用关闭TFTP客户端, 先向服务为推送一个差错包, 然后关闭socket
- (void)closeTFTPClient
{
    if (_sockfd > 0) {
        
        struct sockaddr_in addr_peer;
        socklen_t addr_peer_len = sizeof(addr_peer);
        addr_peer.sin_len = addr_peer_len;
        
        if (getpeername(_sockfd, (struct sockaddr*)&addr_peer, &addr_peer_len) == 0) {
            if (addr_peer.sin_port != 0 && addr_peer.sin_addr.s_addr > 1) {
                char buffer[512];
                NSUInteger len = [TFTPClientPacket makeErrorDataWithCode:1004
                                                                  reason:"Client Close"
                                                              sendBuffer:buffer];
                send(_sockfd, buffer, len, 0);
            }
        }
    }
    [self closeSocket];
}

- (void)closeSocket
{
    if (_sockfd > 0) close(_sockfd);
    _isOpen = NO;
}

///发送请求文件数据包 -> 开始下载文件
- (void)sendFileRequestDataWithFilename:(NSString *)filename
{
    //1. 初始化一些变量
    char sendBuffer[1024];      //发送数据缓存区
    NSUInteger sendLen;         //发送数据长度
    char recvBuffer[1024];      //接收数据缓存区
    _blocknum = 0;              //接收块号记录
    self.fileData.length = 0;   //接收文件缓存区
    int retry = 0;              //记录同一个包的请求次数
    BOOL isLastPacket = false;  //记录是否是最后一个数据包

    //2. 发送文件请求包
    sendLen = [TFTPClientPacket makeRRQWithFileName:filename
                                         sendBuffer:sendBuffer];
    if (send(_sockfd, sendBuffer, sendLen, 0) < 0 && _isOpen) {
        [self throwErrorWithCode:errno reason:@"Read data error"];
        return;
    }
    
    //3. 开始监听数据返回
    while (1) {

        ssize_t result_recv = recv(_sockfd, recvBuffer, sizeof(recvBuffer), 0);
        if (result_recv < 0 && _isOpen) {
            
            if (errno == EAGAIN) { //读取数据超时
                retry++;
                if (retry >= MAX_RETRY) {
                    NSLog(@"[TFTPClient] 请求超时,发送差错包给服务器");
                    sendLen = [TFTPClientPacket makeErrorDataWithCode:1001
                                                               reason:"The maximum number of retransmissions"
                                                           sendBuffer:sendBuffer];
                    send(_sockfd, sendBuffer, sendLen, 0);
                    [self throwErrorWithCode:1001 reason:@"The maximum number of retransmissions"];
                    return;
                }else {
                    //重发上一个ACK确认包
                    NSLog(@"[TFTPClient] 客户端请求数据块超时,重发上个ACK(块号:%u)",_blocknum);
                    if (send(_sockfd, sendBuffer, sendLen, 0) < 0 && _isOpen) {
                        [self throwErrorWithCode:errno reason:@"Send data error"];
                        return;
                    }
                    continue;
                }
            }else {
                [self throwErrorWithCode:errno reason:@"Read data error"];
                return;
            }
        }

        //数据长度过短或不是我们需要服务器地址发送过来的数据都不是我们想要的数据, 直接丢掉
        if (result_recv < 4) continue;

        //解析操作码
        char opCode = recvBuffer[1];
        if (opCode == TFTP_RRQ || opCode == TFTP_WRQ || opCode == TFTP_ACK) {

            NSLog(@"[TFTPClient] 服务器发送了错误数据包(操作码: %d)，不理",opCode);

        }else if (opCode == TFTP_DATA) {
            /* 服务器发送过来数据包 */

            //解析出块号, 与自己的块号作比较, 看看服务器有没有发错
            uint blocknum = (recvBuffer[2]&0xff)<<8 | (recvBuffer[3]&0xff);
            //NSLog(@"[TFTPClient] 服务器发送过来数据包,块号：%u",blocknum);
            
            if (blocknum == (_blocknum + 1)) {

                retry = 0;
                _blocknum = blocknum;

                //解析数据包, 并且判断是否是最后一个数据包
                NSData *data = [NSData dataWithBytes:&recvBuffer[4] length:result_recv-4];
                [self.fileData appendData:data];

                if (data.length < TFTP_BlockSize) isLastPacket = YES;

                //发送ACK确认包
                sendLen = [TFTPClientPacket makeACKWithBlockNum:_blocknum sendBuffer:sendBuffer];
                if (send(_sockfd, sendBuffer, sendLen, 0) < 0 && _isOpen) {
                    [self throwErrorWithCode:errno reason:@"Send data error"];
                    return;
                }
            }else {
                //块号不对,进入重发机制
                retry++;
                if (retry >= MAX_RETRY) {
                    NSLog(@"[TFTPClient] 接收数据包错误次数达到上限,发送差错包给客户端");
                    sendLen = [TFTPClientPacket makeErrorDataWithCode:1001
                                                               reason:"The maximum number of retransmissions"
                                                           sendBuffer:sendBuffer];
                    send(_sockfd, sendBuffer, sendLen, 0);
                    [self throwErrorWithCode:1001 reason:@"The maximum number of retransmissions"];
                    return;
                }else {
                    NSLog(@"[TFTPClient] 服务器发送块号不对(块号:%u), 重发送上个ACK确认包(块号:%u)",blocknum,_blocknum);
                    if (send(_sockfd, sendBuffer, sendLen, 0) < 0 && _isOpen) {
                        [self throwErrorWithCode:errno reason:@"Send data error"];
                        return;
                    }
                }
            }
            
            if (isLastPacket) { //就收完成
                [self recevComplete];
                return;
            }

        }else if (opCode == TFTP_ERROR) {

            NSString *errStr = [[NSString alloc] initWithBytes:&recvBuffer[4] length:result_recv-4 encoding:NSUTF8StringEncoding];
            NSLog(@"[TFTPClient] 服务器传送过来差错信息: 错误码 -> %u 错误信息 -> %@",(((recvBuffer[2] & 0xff) << 8) | (recvBuffer[3] & 0xff)),errStr);
            [self throwErrorWithCode:(((recvBuffer[2] & 0xff) << 8) | (recvBuffer[3] & 0xff)) reason:errStr];
            return;

        }else {

            NSLog(@"[TFTPClient] 服务器传过来不知名的数据包(操作码: %d)",opCode);

        }
        [self callBackProgress];
    }
}

- (void)callBackProgress
{
    if (self.progressBlock) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.progressBlock(self.fileData.length, _blocknum);
        });
    }
}

///传送完成
- (void)recevComplete
{
    [self closeSocket];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.progressBlock) self.progressBlock = nil;
        if (self.resultBlock) {
            self.resultBlock(self.fileData, nil);
            self.resultBlock = nil;
        }
    });
}

///抛出错误 -> 传送失败
- (void)throwErrorWithCode:(int)code reason:(NSString *)reason
{
    NSString *description;
    if (code >= 1000) {
        description = reason;
    }else {
        description = [NSString stringWithFormat:@"%@ -> %s",reason,strerror(errno)];
    }
    NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:description,NSLocalizedDescriptionKey, nil];
    NSError *error = [NSError errorWithDomain:@"TFTPClientError" code:code userInfo:userInfo];
    
    [self closeSocket];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.progressBlock) self.progressBlock = nil;
        if (self.resultBlock) {
            self.resultBlock(nil, error);
            self.resultBlock = nil;
        }
    });
}

- (NSMutableData *)fileData
{
    if (!_fileData) {
        _fileData = [NSMutableData data];
    }
    return _fileData;
}

@end
