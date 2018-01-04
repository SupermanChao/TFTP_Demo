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
#include <string.h>

#define TFTP_RRQ   1   //读请求
#define TFTP_WRQ   2   //写请求
#define TFTP_DATA  3   //数据
#define TFTP_ACK   4   //ACK确认
#define TFTP_ERROR 5   //Error

#define MAX_RETRY          3              //最大重复传送次数
#define TFTP_BlockSize     512            //每个数据包截取文件的大小(相对发送包而言,这个是去掉操作码和块号剩余的大小)

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
    uint _blocknum;                     //数据包的块数
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
    if (_sockfd > 0) {
        
        struct sockaddr_in addr_peer;
        socklen_t addr_peer_len = sizeof(addr_peer);
        addr_peer.sin_len = addr_peer_len;
        
        if (getpeername(_sockfd, (struct sockaddr*)&addr_peer, &addr_peer_len) == 0) {
            
            if (addr_peer.sin_port != 0 && addr_peer.sin_addr.s_addr > 1) {
                char buffer[512];
                NSUInteger len = [TFTPServerPacket makeErrorDataWithCode:1003
                                                                  reason:"Server Close"
                                                              sendBuffer:buffer];
                send(_sockfd, buffer, len, 0);
            }
        }
    }
    [self closeSocket];
}

///关闭套接字
- (void)closeSocket
{
    _isOpen = NO;
    if (_sockfd > 0) close(_sockfd);
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
    
    //套接字初始化(Create Socket)
    _sockfd = socket(AF_INET, SOCK_DGRAM, 0);
    if (_sockfd <= 0) {
        [self throwErrorWithCode:errno reason:@"Failed to create socket"];
        return;
    }
    
    //绑定监听地址
    struct sockaddr_in addr_server;
    addr_server.sin_len = sizeof(struct sockaddr_in);
    addr_server.sin_family = AF_INET;
    addr_server.sin_port = htons(bindPort);
    addr_server.sin_addr.s_addr = htonl(INADDR_ANY);
    
    if (bind(_sockfd, (struct sockaddr*)&addr_server, addr_server.sin_len) < 0) {
        [self throwErrorWithCode:errno reason:@"Binding socket failed"];
        return;
    }
    
    //客户端套接字地址
    struct sockaddr_in addr_clict;
    socklen_t addr_clict_len = sizeof(struct sockaddr_in);
    addr_clict.sin_len = addr_clict_len;
    
    //设置接收请求连接超时时间为30s
    struct timeval timeout = {30,0};
    if (setsockopt(_sockfd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(struct timeval)) < 0) {
        printf("开始设置Socket服务器接收连接超时失败: %s\n",strerror(errno));
    }
    
    while (1) {
        
        if (_isOpen == NO) return; //服务器关闭直接退出
        
        char recv_buffer[1024];     //接收数据缓冲区
        ssize_t result_recv = recvfrom(_sockfd, recv_buffer, sizeof(recv_buffer), 0, (struct sockaddr*)&addr_clict, &addr_clict_len);
        if (result_recv < 0 && _isOpen) {
            [self throwErrorWithCode:errno reason:@"Read data error"];
            return;
        }
        
        if (result_recv < 4) continue; //数据包长度必须大于或等于4,否则不是我们想要的数据
        
        if (recv_buffer[1] == TFTP_RRQ) { //操作码是读请求 -> 有客户端连接
            
            //注册客户端地址信息
            if (connect(_sockfd, (struct sockaddr*)&addr_clict, sizeof(addr_clict)) != 0) {
                [self throwErrorWithCode:errno reason:@"Registration destination address failed"];
                return;
            }
            
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
                NSUInteger len = [TFTPServerPacket makeErrorDataWithCode:1000
                                                                  reason:"Request file name error"
                                                              sendBuffer:send_buffer];
                sendto(_sockfd, send_buffer, len, 0, (struct sockaddr*)&addr_clict, addr_clict.sin_len);
                
                [self throwErrorWithCode:errno reason:@"Request file name error"];
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
    
    if (send(_sockfd, send_buffer, sendLen, 0) < 0 && _isOpen) {
        [self throwErrorWithCode:errno reason:@"Send data error"];
        return;
    }
    _alreadySendLen = sendLen - 4;
    
    //开始传输数据时，定个数据包接收超时时间段为6s
    struct timeval timeout = {6,0};
    if (setsockopt(_sockfd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(struct timeval)) < 0) {
        printf("设置Socket通信过程中，接收客户端数据超时失败：%s\n",strerror(errno));
    }
    
    //4. while循环监听数据包的返回
    while (1) {
        
        if (_isOpen == NO) return; //服务器关闭直接退出监听
        
        ssize_t result_recv = recv(_sockfd, recv_buffer, sizeof(recv_buffer), 0);
        if (result_recv < 0 && _isOpen) {
            if (errno == EAGAIN) { //接收超时重传
                retry ++;
                if (retry >= MAX_RETRY) {
                    NSLog(@"[TFTPServer] 接收ACK超时,发送差错包给客户端");
                    sendLen = [TFTPServerPacket makeErrorDataWithCode:1001
                                                               reason:"The maximum number of retransmissions"
                                                           sendBuffer:send_buffer];
                    send(_sockfd, send_buffer, sendLen, 0);
                    [self throwErrorWithCode:1001 reason:@"The maximum number of retransmissions"];
                    return;
                }else {
                    NSLog(@"[TFTPServer] 接收客户端确认包超时 -> 重传上次的包(块号:%u)",_blocknum);
                    if (send(_sockfd, send_buffer, sendLen, 0) < 0 && _isOpen) {
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
        
        //数据包长度小于4不要
        if (result_recv < 4) continue;
        
        //先解析操作码
        char opCode = recv_buffer[1];
        if (opCode == TFTP_RRQ || opCode == TFTP_WRQ || opCode == TFTP_DATA) {
            
            NSLog(@"[TFTPServer] 客户端发错了数据包(操作码: %d), 不理",opCode);
            
        }else if (opCode == TFTP_ACK) { //收到ACK数据包
            
            //①. 解析出确认块号
            uint clict_sureblocknum = ((recv_buffer[2]&0xff)<<8)|((recv_buffer[3]&0xff));
            //NSLog(@"[TFTPServer] 收到客户端的ACK数据包,块号：%d",clict_sureblocknum);
            
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
                    
                    if (send(_sockfd, send_buffer, sendLen, 0) < 0 && _isOpen) {
                        [self throwErrorWithCode:errno reason:@"Send data error"];
                        return;
                    }
                    _alreadySendLen += (sendLen - 4);
                    
                }else if (clict_sureblocknum == (_blocknum - 1)) {
                    //ACK块号不对,进入重发机制
                    retry ++;
                    if (retry >= MAX_RETRY) {
                        NSLog(@"[TFTPServer] 接收ACK错误次数达到上限,发送差错包给客户端");
                        sendLen = [TFTPServerPacket makeErrorDataWithCode:1001
                                                                   reason:"The maximum number of retransmissions"
                                                               sendBuffer:send_buffer];
                        
                        send(_sockfd, send_buffer, sendLen, 0);
                        [self throwErrorWithCode:1001 reason:@"The maximum number of retransmissions"];
                        return;
                    }else {
                        NSLog(@"[TFTPServer] 客户端发送ACK块号有误(块号:%u), 重传上次的包(块号:%u)",_blocknum,clict_sureblocknum);
                        if (send(_sockfd, send_buffer, sendLen, 0) < 0 && _isOpen) {
                            [self throwErrorWithCode:errno reason:@"Send data error"];
                            return;
                        }
                    }
                }else {
                    
                    NSLog(@"[TFTPServer] 客户端返回的确认块号不对 _blocknum:%u clict_sureblocknum:%u",_blocknum,clict_sureblocknum);
                    [self throwErrorWithCode:1002 reason:@"Request block number error"];
                    return;
                }
            }
        }else if (opCode == TFTP_ERROR) {
            
            //客户端那边发送过来了错误包
            NSString *errStr = [[NSString alloc] initWithBytes:&recv_buffer[4] length:result_recv-4 encoding:NSUTF8StringEncoding];
            NSLog(@"[TFTPServer] 客户端传送过来差错信息:  错误码 -> %u 错误信息 -> %@",(((recv_buffer[2] & 0xff) << 8) | (recv_buffer[3] & 0xff)),errStr);
            [self throwErrorWithCode:(((recv_buffer[2] & 0xff) << 8) | (recv_buffer[3] & 0xff)) reason:errStr];
            return;
            
        }else {
            
            NSLog(@"[TFTPServer] 客户端发错了数据包(操作码: %d), 不理",opCode);
            
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
- (void)throwErrorWithCode:(int)code reason:(NSString *)reason
{
    NSString *description;
    if (code >= 1000) {
        description = reason;
    }else {
        description = [NSString stringWithFormat:@"%@ -> %s",reason,strerror(errno)];
    }
    NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:description,NSLocalizedDescriptionKey, nil];
    NSError *error = [NSError errorWithDomain:@"TFTPServerError" code:code userInfo:userInfo];
    
    [self closeSocket];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.progressBlock) self.progressBlock = nil;
        if (self.resultBlock) {
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

