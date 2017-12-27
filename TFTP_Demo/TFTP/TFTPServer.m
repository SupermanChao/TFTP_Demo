//
//  TFTPServer.m
//  Practice
//
//  Created by 刘超 on 2017/12/20.
//  Copyright © 2017年 刘超. All rights reserved.
//

#import "TFTPServer.h"
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

#define MAX_RETRY          3              //最大重复传送次数
#define TFTP_BlockSize     512            //每个数据包截取文件的大小(相对发送包而言,这个是去掉操作码和块号剩余的大小)

typedef enum : NSUInteger {
    TFTPServerErrorCode_ServerSock_Error      = 0,
    TFTPServerErrorCode_ReadFile_Fail         = 1,
    TFTPServerErrorCode_SendData_Fail         = 2,
    TFTPServerErrorCode_RecvData_Fail         = 3,
    TFTPServerErrorCode_SendData_Timeout      = 4,
    TFTPServerErrorCode_RecvErrorPacket       = 5,
    
} TFTPServerErrorCode;

@interface TFTPError : NSObject
///根据错误码返回错误
+ (NSError *)errorWithTFTPErrorCode:(TFTPServerErrorCode)errorCode;
@end

@implementation TFTPError

+ (NSError *)errorWithTFTPErrorCode:(TFTPServerErrorCode)errorCode
{
    NSString *description;
    switch (errorCode) {
        case TFTPServerErrorCode_ServerSock_Error:
            description = @"套接字发生错误 -> 服务器连接错误";
            break;
        case TFTPServerErrorCode_ReadFile_Fail:
            description = @"根据文件路径没有找到对应文件，应该是文件路径有问题";
            break;
        case TFTPServerErrorCode_SendData_Fail:
            description = @"套接字发送数据错误 -> 服务器发生错误";
            break;
        case TFTPServerErrorCode_RecvData_Fail:
            description = @"套接字读取数据错误-> 服务器发生错误";
            break;
        case TFTPServerErrorCode_SendData_Timeout:
            description = @"套接字重发同一个数据包次数达到上限 -> 服务器发送数据超时";
            break;
        case TFTPServerErrorCode_RecvErrorPacket:
            description = @"套接字接收到差错包或者错误包";
            break;
        default:
            description = @"未知错误";
            break;
    }
    
    NSError *error = [NSError errorWithDomain:@"TFTPServerError" code:errorCode userInfo:@{@"description" : description}];
    return error;
}
@end


@interface TFTPServerPacket : NSObject
/**
 *  @brief  填充Data数据包
 *
 *  @param  totalData       总的数据包
 *  @param  sendBuffer      要发送数据缓存区
 *  @param  location        截取位置
 *  @param  length          截取数据的长度 (0-512之间)
 *  @param  blocknum        块号
 *  @return 返回需要发送数据包的长度
 */
+ (NSUInteger)makeDataWithTotalData:(NSData *)totalData
                         sendBuffer:(char[])sendBuffer
                           location:(NSUInteger)location
                             length:(NSUInteger)length
                           blocknum:(int)blocknum;
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

@implementation TFTPServerPacket

+ (NSUInteger)makeDataWithTotalData:(NSData *)totalData sendBuffer:(char[])sendBuffer location:(NSUInteger)location length:(NSUInteger)length blocknum:(int)blocknum
{
    //操作码(2byte) + 块号(2byte) + 数据(512byte) = 返回数据包(516byte)
    //NSLog(@"[TFTPServer] -------->location:%lu length:%lu",location,length);
    sendBuffer[0] = 0;
    sendBuffer[1] = TFTP_DATA;
    
    sendBuffer[2] = blocknum >> 8;
    sendBuffer[3] = blocknum;
    
    NSData *data;
    if ((location + length) > totalData.length) {
        data = [totalData subdataWithRange:NSMakeRange(location, totalData.length - location)];
    }else {
        data = [totalData subdataWithRange:NSMakeRange(location, length)];
    }
    Byte *temp = (Byte *)data.bytes;
    memcpy(&sendBuffer[4], temp, data.length);
    
    return (4 + data.length);
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


@interface TFTPServer () {
    int _sockfd;                        //套接字
    NSString *_filepath;                //OC字符串文件的前半部分
    NSUInteger _fileTotalLen;           //文件的总长度
    NSUInteger _alreadySendLen;         //已经发送了的长度
    int _blocknum;                      //数据包的块数
    struct sockaddr_in *_addr_client;   //客户端地址结构体指针
}
@property (nonatomic, copy) void(^progressBlock)(float progress);
@property (nonatomic, copy) void(^resultBlock)(BOOL isSuccess, NSError *error);
@property (nonatomic, copy) NSData *fileData; //文件的二进制数据
@end

@implementation TFTPServer

- (void)openTFTPServerWithPrefile:(NSString *)preFile
                             port:(uint16_t)port
                     sendProgress:(void(^)(float progress))progress
                           result:(void(^)(BOOL isSuccess, NSError *error))result
{
    if (port == 0 || preFile == nil || preFile.length == 0) return;
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        
        _filepath = preFile;
        
        if (progress) self.progressBlock = progress;
        if (result) self.resultBlock = result;
        
        [self startMonitorWithBindPort:port];
    });
}

///外部调用, 关闭TFTP服务器, 先像客户端发送一个差错包, 告诉客户端服务器要关了
- (void)closeTFTPServer
{
    if (_sockfd > 0 && _addr_client!=NULL) {
        //先发送一个差错包
        char buffer[512];
        NSUInteger len = [TFTPServerPacket makeErrorDataWithCode:3
                                                          reason:"Server Close"
                                                      sendBuffer:buffer];
        sendto(_sockfd, buffer, len, 0, (struct sockaddr*)_addr_client, _addr_client->sin_len);
    }
    [self closeSocket];
}

///关闭套接字
- (void)closeSocket
{
    _isOpen = NO;
    if (_sockfd > 0) close(_sockfd);
}

///初始化套接字
- (BOOL)initSocketWithBindPort:(uint16_t)bindPort
{
    _sockfd = socket(AF_INET, SOCK_DGRAM, 0);
    
    if (_sockfd <= 0) return NO;
    
    struct sockaddr_in addr_server;
    addr_server.sin_len = sizeof(struct sockaddr_in);
    addr_server.sin_family = AF_INET;
    addr_server.sin_port = htons(bindPort);
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

///开始监听UDP
- (void)startMonitorWithBindPort:(uint16_t)bindPort
{
    NSLog(@"[TFTPServer] 开启服务器");
    _isOpen = YES;
    
    _fileTotalLen = 0;
    _alreadySendLen = 0;
    _blocknum = 0;
    _fileData = nil;
    
    //套接字初始化
    if ([self initSocketWithBindPort:bindPort] == NO) {
        [self throwError:TFTPServerErrorCode_ServerSock_Error];
        return;
    }
    
    //客户端套接字地址
    struct sockaddr_in addr_clict;
    socklen_t addr_clict_len = sizeof(struct sockaddr_in);
    addr_clict.sin_len = addr_clict_len;
    
    while (1) {
        
        if (_isOpen == NO) return; //服务器关闭直接退出
        
        char recv_buffer[1024];     //接收数据缓冲区
        ssize_t result_recv = recvfrom(_sockfd, recv_buffer, sizeof(recv_buffer), 0, (struct sockaddr*)&addr_clict, &addr_clict_len);
        if (result_recv < 0 && _isOpen) {
            [self throwError:TFTPServerErrorCode_RecvData_Fail];
            return;
        }
        if (result_recv < 4) continue; //数据包长度必须大于或等于4,否则不是我们想要的数据
        
        if (recv_buffer[1] == TFTP_RRQ) { //操作码是读请求 -> 有客户端连接
            
            _addr_client = &addr_clict; //记录下客户端地址信息
            
            //1. 解析出文件名
            char* cFileName = &recv_buffer[2];
            NSLog(@"[TFTPServer] 收到第一个请求包IP: %s, 文件名: %s",inet_ntoa(addr_clict.sin_addr),cFileName);
            //2. 拼接路径
            _filepath = [_filepath stringByAppendingPathComponent:[NSString stringWithCString:cFileName encoding:NSUTF8StringEncoding]];
            
            //3. 初始化一些数据
            _fileTotalLen = self.fileData.length;
            NSLog(@"[TFTPServer] 文件长度: %lu",(unsigned long)_fileTotalLen);
            if (_fileTotalLen == 0) {
                
                char send_buffer[512];
                NSUInteger len = [TFTPServerPacket makeErrorDataWithCode:2
                                                                  reason:"Request file name error"
                                                              sendBuffer:send_buffer];
                sendto(_sockfd, send_buffer, len, 0, (struct sockaddr*)&addr_clict, addr_clict.sin_len);
                
                [self throwError:TFTPServerErrorCode_ReadFile_Fail];
                return;
            }
            
            [self beganToTransportData];
            return;
        }
    }
}

///开始传输数据
- (void)beganToTransportData
{
    //1. 局部变量的声明
    char recv_buffer[1024];     //接收数据缓冲区
    char send_buffer[1024];     //发送数据缓冲区
    NSUInteger sendLen = 0;     //发送数据的长度
    
    //2. 初始化一些数据
    _blocknum = 1;
    _alreadySendLen = 0;
    int retry = 0;                  //同一个包重传次数
    BOOL isLastPacket = false;      //记录是否是最后一个数据包
    
    //3. 第一个数据包的发送
    sendLen = [TFTPServerPacket makeDataWithTotalData:self.fileData
                                           sendBuffer:send_buffer
                                             location:_alreadySendLen
                                               length:TFTP_BlockSize
                                             blocknum:_blocknum];
    if (sendLen < (TFTP_BlockSize + 4)) isLastPacket = YES; //记录下是发送的最后一个数据包
    
    if (sendto(_sockfd, send_buffer, sendLen, 0, (struct sockaddr*)_addr_client, _addr_client->sin_len) < 0 && _isOpen) {
        [self throwError:TFTPServerErrorCode_SendData_Fail];
        return;
    }
    _alreadySendLen = sendLen - 4;
    
    //4. while循环监听数据包的返回
    while (1) {
        
        if (_isOpen == NO) return; //服务器关闭直接退出监听
        
        //来者套接字地址
        struct sockaddr_in addr_from;
        socklen_t addr_from_len = sizeof(struct sockaddr_in);
        addr_from.sin_len = addr_from_len;
        
        ssize_t result_recv = recvfrom(_sockfd, recv_buffer, sizeof(recv_buffer), 0, (struct sockaddr*)&addr_from, &addr_from_len);
        if (result_recv < 0 && _isOpen) {
            [self throwError:TFTPServerErrorCode_RecvData_Fail];
            return;
        }
        
        //不是我们连接客户端的地址的数据包 或 数据包长度小于4 都不要
        if (addr_from.sin_addr.s_addr != _addr_client->sin_addr.s_addr || addr_from.sin_port != _addr_client->sin_port) continue;
        if (result_recv < 4) continue;
        
        //先解析操作码
        char opCode = recv_buffer[1];
        if (opCode == TFTP_RRQ || opCode == TFTP_WRQ || opCode == TFTP_DATA) {
            
            NSLog(@"[TFTPServer] 客户端(IP: %s)发错了数据包(操作码: %d), 不理",inet_ntoa(addr_from.sin_addr),opCode);
            
        }else if (opCode == TFTP_ACK) {
            /** 收到ACK数据包 */
            
            //①. 解析出确认块号
            int clict_sureblocknum = ((recv_buffer[2]&0xff)<<8)|((recv_buffer[3]&0xff));
            
            //②. 判断是否是最后一个包的确认
            if (isLastPacket == YES && _blocknum == clict_sureblocknum) { //是最后一个包了
                
                [self sendComplete];
                return;
                
            }else {
                
                if (_blocknum == clict_sureblocknum) {
                    _blocknum ++;
                    retry = 0;
                    
                    sendLen = [TFTPServerPacket makeDataWithTotalData:self.fileData
                                                           sendBuffer:send_buffer
                                                             location:_alreadySendLen
                                                               length:TFTP_BlockSize
                                                             blocknum:_blocknum];
                    
                    if (sendLen < (TFTP_BlockSize + 4)) isLastPacket = YES; //记录下是发送的最后一个数据包
                    
                    if (sendto(_sockfd, send_buffer, sendLen, 0, (struct sockaddr*)_addr_client, _addr_client->sin_len) < 0 && _isOpen) {
                        [self throwError:TFTPServerErrorCode_SendData_Fail];
                        return;
                    }
                    _alreadySendLen += (sendLen - 4);
                    
                }else if (clict_sureblocknum == (_blocknum - 1)) {
                    //上一个数据包客户端接收有误, 重传
                    
                    if (retry >= MAX_RETRY) {
                        //对同一个块, 发送次数达到上限, 先向设备发一个差错包, 然后关掉套接字
                        sendLen = [TFTPServerPacket makeErrorDataWithCode:1
                                                                   reason:"The maximum number of retransmissions"
                                                               sendBuffer:send_buffer];
                        sendto(_sockfd, send_buffer, sendLen, 0, (struct sockaddr*)_addr_client, _addr_client->sin_len);
                        
                        [self throwError:TFTPServerErrorCode_SendData_Timeout];
                        return;
                    }
                    
                    NSLog(@"[TFTPServer] 客户端发送的确认块号错误 -> 重传上次的包 _blocknum:%d clict_sureblocknum:%d",_blocknum,clict_sureblocknum);
                    
                    if (sendto(_sockfd, send_buffer, sendLen, 0, (struct sockaddr*)_addr_client, _addr_client->sin_len) < 0 && _isOpen) {
                        [self throwError:TFTPServerErrorCode_SendData_Fail];
                        return;
                    }
                    retry ++;
                    
                }else {
                    
                    NSLog(@"[TFTPServer] 客户端返回的确认块号不对 _blocknum:%d clict_sureblocknum:%d",_blocknum,clict_sureblocknum);
                    [self throwError:TFTPServerErrorCode_RecvErrorPacket];
                    return;
                }
            }
        }else if (opCode == TFTP_ERROR) {
            
            //客户端那边发送过来了错误包
            NSString *errStr = [[NSString alloc] initWithBytes:&recv_buffer[4] length:result_recv-4 encoding:NSUTF8StringEncoding];
            NSLog(@"[TFTPServer] 客户端(IP: %s)传送过来差错信息:  错误码 -> %d 错误信息 -> %@",inet_ntoa(addr_from.sin_addr),((recv_buffer[2] << 8) | recv_buffer[3]),errStr);
            [self throwError:TFTPServerErrorCode_RecvErrorPacket];
            return;
            
        }else {
            
            NSLog(@"[TFTPServer] 客户端(IP: %s)发错了数据包(操作码: %d), 不理",inet_ntoa(addr_from.sin_addr),opCode);
            
        }
        
        [self callBackProgress];
    }
}

///回调进度
- (void)callBackProgress
{
    if (self.progressBlock) {
        
        dispatch_async(dispatch_get_main_queue(), ^{
           
            if (_fileTotalLen == 0) _fileTotalLen = 1;
            
            float progress = (float)_alreadySendLen / (float)_fileTotalLen;
            self.progressBlock(progress);
        });
    }
}

///抛出错误 -> 传送失败
- (void)throwError:(TFTPServerErrorCode)code
{
    [self closeSocket];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.progressBlock) self.progressBlock = nil;
        if (self.resultBlock) {
            NSError *error = [TFTPError errorWithTFTPErrorCode:code];
            self.resultBlock(NO, error);
            self.resultBlock = nil;
        }
    });
}

///传送完成
- (void)sendComplete
{
    [self closeSocket];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.progressBlock) self.progressBlock = nil;
        if (self.resultBlock) self.resultBlock(YES, nil);
    });
}

- (NSData *)fileData
{
    if (!_fileData) {
        if (_filepath.length > 0) {
            NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:_filepath];
            _fileData  = [handle readDataToEndOfFile];
        }
    }
    return _fileData;
}

@end

