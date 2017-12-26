//
//  TFTPClient.h
//  TFTP_Demo
//
//  Created by 刘超 on 2017/12/22.
//  Copyright © 2017年 刘超. All rights reserved.
//

#import <Foundation/Foundation.h>

#define TFTP_RRQ   1   //读请求
#define TFTP_WRQ   2   //写请求
#define TFTP_DATA  3   //数据
#define TFTP_ACK   4   //ACK确认
#define TFTP_ERROR 5   //Error

#define MAX_RETRY          3              //最大重复请求次数
#define TFTP_BlockSize     512            //每个数据包截取文件的大小(相对发送包而言,这个是去掉操作码和块号剩余的大小)

@interface TFTPClient : NSObject

///TFTP客户端是否打开
@property (nonatomic, assign, readonly) BOOL isOpen;

/**
 *  @brief  连接服务器并下载数据
 *
 *  @param  host            //服务器IP
 *  @param  port            //服务器端口号
 *  @param  filename        //需要下载文件名
 *  @param  progressBlock   //下载进度回调
 *  @param  resultBlock     //结果回调
 */
- (void)connectToHost:(NSString *)host
                 port:(uint16_t)port
             fileName:(NSString *)filename
     downLoadProgress:(void(^)(NSUInteger recvDataLen, int blocknum))progressBlock
               result:(void(^)(NSData *fileData, NSError *error))resultBlock;

///关闭TFTP服务器
- (void)closeTFTPClient;

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
