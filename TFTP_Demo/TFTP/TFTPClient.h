//
//  TFTPClient.h
//  TFTP_Demo
//
//  Created by 刘超 on 2017/12/22.
//  Copyright © 2017年 刘超. All rights reserved.
//

#import <Foundation/Foundation.h>

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
