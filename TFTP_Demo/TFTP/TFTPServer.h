//
//  TFTPServer.h
//  Practice
//
//  Created by 刘超 on 2017/12/20.
//  Copyright © 2017年 刘超. All rights reserved.
//

#import <Foundation/Foundation.h>

#define TFTP_RRQ   1   //读请求
#define TFTP_WRQ   2   //写请求
#define TFTP_DATA  3   //数据
#define TFTP_ACK   4   //ACK确认
#define TFTP_ERROR 5   //Error

#define MAX_RETRY          3              //最大重复传送次数
#define TFTP_BlockSize     512            //每个数据包截取文件的大小(相对发送包而言,这个是去掉操作码和块号剩余的大小)

@interface TFTPServer : NSObject

///TFTP服务器是否打开
@property (nonatomic, assign, readonly) BOOL isOpen;

///开启TFTP服务器
- (void)openTFTPServerWithPrefile:(NSString *)preFile
                             port:(uint16_t)port
                     sendProgress:(void(^)(float progress))progress
                           result:(void(^)(BOOL isSuccess, NSError *error))result;

///关闭TFTP服务器
- (void)closeTFTPServer;

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
