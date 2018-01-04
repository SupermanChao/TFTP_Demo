//
//  TFTPServer.h
//  Practice
//
//  Created by 刘超 on 2017/12/20.
//  Copyright © 2017年 刘超. All rights reserved.
//

#import <Foundation/Foundation.h>

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
/**
 *  1000 请求文件错误,文件不存在
 *  1001 超过最大传输次数,传送文件超时
 *  1002 客户端请求块号错误
 *  1003 服务器主动关闭Socket
 *  1004 客户端主动关闭
 */
