//
//  ServerViewController.m
//  TFTP_Demo
//
//  Created by 刘超 on 2017/12/22.
//  Copyright © 2017年 刘超. All rights reserved.
//

#import "ServerViewController.h"
#import "TFTPServer.h"
@interface ServerViewController ()
@property (weak, nonatomic) IBOutlet UIProgressView *progressView;
@property (weak, nonatomic) IBOutlet UILabel *stateLable;
@property (weak, nonatomic) IBOutlet UIButton *btn;

@property (nonatomic, strong) TFTPServer *server;

@end

@implementation ServerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view from its nib.
    
    self.navigationItem.title = @"服务器";
}

/**
 *  Demo只是在工程里面放了一个图片, 传入的路径也是工程的文件目录, 实际实验是应该放在文件夹里面, 比方说项目的沙盒文件目录
 *
 *  绑定的端口要与客户端的发送数据端口一致
 */
- (IBAction)clickBtnAction {
    
    if (self.btn.selected == NO)
    {
        //关 -> 开
        if (self.server.isOpen) {
            self.stateLable.text = @"服务器已经开启状态，不能重复开启";
            return;
        }
        
        self.stateLable.text = @"开始传送";
        self.progressView.progress = 0;
        
        //NSString *prePath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"]; //找到供客户端下载文件的文件夹
        NSString *prePath = [NSBundle mainBundle].bundlePath;
        __weak typeof(self) weakSelf = self;
        
        [self.server openTFTPServerWithPrefile:prePath port:10099 sendProgress:^(float progress) {
            
            weakSelf.progressView.progress = progress;
            
        } result:^(BOOL isSuccess, NSError *error) {
            
            if (isSuccess) {
                weakSelf.stateLable.text = @"传输完成";
            }else {
                weakSelf.stateLable.text = [error.userInfo objectForKey:@"description"];
            }
            self.btn.selected = NO;
        }];
        
    }
    else
    {
        //开 -> 关
        if (self.server.isOpen == NO) {
            self.stateLable.text = @"服务器已经关闭，不需要重复关闭";
            return;
        }
        [self.server closeTFTPServer];
    }
    
    self.btn.selected = !self.btn.selected;
}


- (TFTPServer *)server
{
    if (!_server) {
        _server = [[TFTPServer alloc] init];
    }
    return _server;
}

@end
