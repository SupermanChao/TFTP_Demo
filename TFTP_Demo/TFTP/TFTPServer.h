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
