//
//  ClientViewController.m
//  TFTP_Demo
//
//  Created by 刘超 on 2017/12/22.
//  Copyright © 2017年 刘超. All rights reserved.
//

#import "ClientViewController.h"
#import "ShowViewController.h"
#import "TFTPClient.h"
@interface ClientViewController ()

@property (weak, nonatomic) IBOutlet UITextField *tf_ip;
@property (weak, nonatomic) IBOutlet UITextField *tf_filename;
@property (weak, nonatomic) IBOutlet UILabel *stateLable;
@property (weak, nonatomic) IBOutlet UIButton *btn;

@property (nonatomic, strong) TFTPClient *client;
@end

@implementation ClientViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view from its nib.
    
    self.navigationItem.title = @"客户端";
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    self.tf_ip.text = [[NSUserDefaults standardUserDefaults] objectForKey:@"Server_IP"];
    self.tf_filename.text = @"1.JPG";
}

/**
 *  本Demo是在工程里面放了一张“1.JPG”的图片，供客户端下载， 所以上面已经填写
 *  注意服务器的地址信息，IP不能错，我的效果里面用了一个模拟器一个真机，模拟器为服务器，IP在电脑的网络里面能看到，注意不能同时用两个模拟器，因为IP可能重复，自己发给自己会出问题
 *  绑定端口和发送数据端口要跟服务器对应
 */
- (IBAction)clickBtnAction {
    
    if (self.btn.selected == NO)
    {
        if (self.client.isOpen) {
            self.stateLable.text = @"客户端已经打开了，正在下载";
            return;
        }
        
        if (self.tf_ip.text.length == 0 || self.tf_filename.text.length == 0) {
            self.stateLable.text = @"请填写IP地址和需要下载的文件名";
            return;
        }
        
        self.stateLable.text= @"开始下载";
        [[NSUserDefaults standardUserDefaults] setObject:self.tf_ip.text forKey:@"Server_IP"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        
        __weak typeof(self) weakSelf = self;
        [self.client connectToHost:self.tf_ip.text port:10099 fileName:self.tf_filename.text
                  downLoadProgress:^(NSUInteger recvDataLen, int blocknum) {
                      
                      if (recvDataLen < 1024) {
                          weakSelf.stateLable.text = [NSString stringWithFormat:@"已经接收: %lu k",(unsigned long)recvDataLen];
                      }else if (recvDataLen >= 1024 && recvDataLen < 1024*1024) {
                          weakSelf.stateLable.text = [NSString stringWithFormat:@"已经接收: %.1f kb",recvDataLen/1024.0];
                      }else {
                          weakSelf.stateLable.text = [NSString stringWithFormat:@"已经接收: %.3f M",recvDataLen/(1024.0 * 1024.0)];
                      }
                      
                  } result:^(NSData *fileData, NSError *error) {
                      
                      if (error) {
                          weakSelf.stateLable.text = [error.userInfo objectForKey:NSLocalizedDescriptionKey];
                      }else {
                          weakSelf.stateLable.text = @"本次下载完成!";
                          ShowViewController *vc = [[ShowViewController alloc] init];
                          vc.image = [UIImage imageWithData:fileData];
                          [weakSelf presentViewController:vc animated:YES completion:nil];
                      }
                      self.btn.selected = NO;
                  }];
        
    }
    else
    {
        if (self.client.isOpen == NO) {
            self.stateLable.text = @"客户端本身已经关闭，没有必要重关";
            return;
        }
        [self.client closeTFTPClient];
    }
        
    self.btn.selected = !self.btn.selected;
}

- (TFTPClient *)client
{
    if (!_client) {
        _client = [[TFTPClient alloc] init];
    }
    return _client;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    [self.view endEditing:YES];
}

@end
