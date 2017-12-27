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

typedef enum : NSUInteger {
    TFTPClientErrorCode_Socket_Error            = 0,
    TFTPClientErrorCode_SendData_Fail           = 1,
    TFTPClientErrorCode_RecvData_Fail           = 2,
    TFTPClientErrorCode_RequesrData_Timeout     = 3,
    TFTPClientErrorCode_RecvErrorPacket         = 4,
} TFTPClientErrorCode;

@interface TFTPClientError : NSObject
///根据错误码返回错误
+ (NSError *)errorWithTFTPErrorCode:(TFTPClientErrorCode)errorCode;
@end

@implementation TFTPClientError

+ (NSError *)errorWithTFTPErrorCode:(TFTPClientErrorCode)errorCode
{
    NSString *description;
    
    switch (errorCode) {
        case TFTPClientErrorCode_Socket_Error:
            description = @"套接字发生错误 -> 客户端连接错误";
            break;
        case TFTPClientErrorCode_SendData_Fail:
            description = @"套接字发送数据错误 -> 客户端下载出现错误";
            break;
        case TFTPClientErrorCode_RecvData_Fail:
            description = @"套接字接收数据错误 -> 客户端下载出现错误";
            break;
        case TFTPClientErrorCode_RequesrData_Timeout:
            description = @"对于同一个数据包，请求次数达到上限 -> 客户端下载数据超时";
            break;
        case TFTPClientErrorCode_RecvErrorPacket:
            description = @"收到服务器发送过来的差错包或者是错误数据包";
            break;
            
        default:
            description = @"未知错误";
            break;
    }
    return [NSError errorWithDomain:@"TFTPClientError" code:errorCode userInfo:@{@"description" : description}];
}
@end


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
    struct sockaddr_in *_addr_server;   //指向服务器地址结构体指针
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
        
        //初始化服务器地址信息
        struct sockaddr_in addr_server;
        addr_server.sin_len = sizeof(struct sockaddr_in);
        addr_server.sin_family = AF_INET;
        addr_server.sin_port = htons(port);
        inet_pton(AF_INET, host.UTF8String, &addr_server.sin_addr);
        
        _addr_server = &addr_server;
        
        //初始化套接字
        if ([self initSocket] == NO) {
            [self throwError:TFTPClientErrorCode_Socket_Error];
            return;
        }

        //发送文件请求包, 开始下载文件
        [self sendFileRequestDataWithFilename:filename];
        
    });
}

///外部调用关闭TFTP客户端, 先向服务为推送一个差错包, 然后关闭socket
- (void)closeTFTPClient
{
    if (_sockfd > 0 && _addr_server != NULL) {
        
        char buffer[512];
        NSUInteger len = [TFTPClientPacket makeErrorDataWithCode:3
                                                          reason:"Client Close"
                                                      sendBuffer:buffer];
        sendto(_sockfd, buffer, len, 0, (struct sockaddr*)_addr_server, _addr_server->sin_len);
    }
    [self closeSocket];
}

- (void)closeSocket
{
    if (_sockfd > 0) close(_sockfd);
    _isOpen = NO;
}

///初始化套接字
- (BOOL)initSocket
{
    _sockfd = socket(AF_INET, SOCK_DGRAM, 0);

    if (_sockfd <= 0) return NO;

    struct sockaddr_in addr_server;
    addr_server.sin_len = sizeof(struct sockaddr_in);
    addr_server.sin_family = AF_INET;
    addr_server.sin_port = _addr_server->sin_port;
    addr_server.sin_addr.s_addr = htonl(INADDR_ANY);
    
    if (bind(_sockfd, (struct sockaddr*)&addr_server, addr_server.sin_len) < 0) return NO;

    fd_set readfds, writefds;
    FD_ZERO(&readfds); FD_ZERO(&writefds);
    FD_SET(_sockfd, &readfds);
    FD_SET(_sockfd, &writefds);
    int num = select(FD_SETSIZE, &readfds, &writefds, NULL, NULL);
    if (num <= 0) return NO;

    return YES;
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

    if (sendto(_sockfd, sendBuffer, sendLen, 0, (struct sockaddr*)_addr_server, _addr_server->sin_len) < 0 && _isOpen) {
        [self throwError:TFTPClientErrorCode_SendData_Fail];
        return;
    }

    //3. 开始监听数据返回
    while (1) {

        struct sockaddr_in addr_from;
        socklen_t addr_from_len = sizeof(struct sockaddr_in);
        addr_from.sin_len = addr_from_len;

        ssize_t result_recv = recvfrom(_sockfd, recvBuffer, sizeof(recvBuffer), 0, (struct sockaddr*)&addr_from, &addr_from_len);
        if (result_recv < 0 && _isOpen) {
            [self throwError:TFTPClientErrorCode_RecvData_Fail];
            return;
        }

        //数据长度过短或不是我们需要服务器地址发送过来的数据都不是我们想要的数据, 直接丢掉
        if (result_recv < 4) continue;
        if (addr_from.sin_addr.s_addr != _addr_server->sin_addr.s_addr || addr_from.sin_port != _addr_server->sin_port) continue;

        //解析操作码
        char opCode = recvBuffer[1];
        if (opCode == TFTP_RRQ || opCode == TFTP_WRQ || opCode == TFTP_ACK) {

            NSLog(@"[TFTPClient] 服务器(IP: %s)发送了错误数据包(操作码: %d)，不理",inet_ntoa(addr_from.sin_addr),opCode);

        }else if (opCode == TFTP_DATA) {
            /* 服务器发送过来数据包 */

            //解析出块号, 与自己的块号作比较, 看看服务器有没有发错
            uint blocknum = (recvBuffer[2]&0xff)<<8 | (recvBuffer[3]&0xff);
            if (blocknum == (_blocknum + 1)) {

                retry = 0;
                _blocknum = blocknum;

                //解析数据包, 并且判断是否是最后一个数据包
                NSData *data = [NSData dataWithBytes:&recvBuffer[4] length:result_recv-4];
                [self.fileData appendData:data];

                if (data.length < TFTP_BlockSize) isLastPacket = YES;

                //发送ACK确认包
                sendLen = [TFTPClientPacket makeACKWithBlockNum:_blocknum sendBuffer:sendBuffer];
                if (sendto(_sockfd, sendBuffer, sendLen, 0, (struct sockaddr*)_addr_server, _addr_server->sin_len) < 0 && _isOpen) {
                    [self throwError:TFTPClientErrorCode_SendData_Fail];
                    return;
                }

            }else {

                NSLog(@"[TFTPClient] 服务器发送块号不对, 服务器发送的块号: %d  客户端应该接收到的块号: %d",blocknum,_blocknum);

                if (retry >= MAX_RETRY) {

                    //回个服务器一个差错包 -> 告诉服务器老是发块号错误的, 我不接了
                    sendLen = [TFTPClientPacket makeErrorDataWithCode:1
                                                               reason:"The maximum number of retransmissions"
                                                           sendBuffer:sendBuffer];
                    sendto(_sockfd, sendBuffer, sendLen, 0, (struct sockaddr*)_addr_server, _addr_server->sin_len);

                    [self throwError:TFTPClientErrorCode_RequesrData_Timeout];
                    return;
                }else {
                    //重发上一个ACK确认包
                    if (sendto(_sockfd, sendBuffer, sendLen, 0, (struct sockaddr*)_addr_server, _addr_server->sin_len) < 0 && _isOpen) {
                        [self throwError:TFTPClientErrorCode_SendData_Fail];
                        return;
                    }
                }
                retry++;
            }

            if (isLastPacket) { //就收完成
                [self recevComplete];
                return;
            }

        }else if (opCode == TFTP_ERROR) {

            NSString *errStr = [[NSString alloc] initWithBytes:&recvBuffer[4] length:result_recv-4 encoding:NSUTF8StringEncoding];
            NSLog(@"[TFTPClient] 服务器(IP: %s)传送过来差错信息: 错误码 -> %d 错误信息 -> %@",inet_ntoa(addr_from.sin_addr),((recvBuffer[2] << 8) | recvBuffer[3]),errStr);
            [self throwError:TFTPClientErrorCode_RecvErrorPacket];
            return;

        }else {

            NSLog(@"[TFTPClient] 服务器(IP: %s)传过来不知名的数据包(操作码: %d)",inet_ntoa(addr_from.sin_addr),opCode);

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
- (void)throwError:(TFTPClientErrorCode)code
{
    [self closeSocket];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.progressBlock) self.progressBlock = nil;
        if (self.resultBlock) {
            NSError *error = [TFTPClientError errorWithTFTPErrorCode:code];
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
