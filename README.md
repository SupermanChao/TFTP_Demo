# TFTP_Demo
关于TFTP客户端和服务器端代码实现,包括数据块错误重传和超时重传,暂时不支持IPv6的网络,因为TFTP是基于UDP实现,所以需要客户端和服务器在同一个网络下面
具体的步骤实现可以参考我的简述文章: https://www.jianshu.com/p/dd91caeaf80d

### TFTPServer (TFTP服务器端)
```
///TFTP服务器是否打开
@property (nonatomic, assign, readonly) BOOL isOpen;

///开启TFTP服务器
- (void)openTFTPServerWithPrefile:(NSString *)preFile
                             port:(uint16_t)port
                     sendProgress:(void(^)(float progress))progress
                           result:(void(^)(BOOL isSuccess, NSError *error))result;

///关闭TFTP服务器
- (void)closeTFTPServer;
```

### TFTPClient (TFTP客户端)
```
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
```
