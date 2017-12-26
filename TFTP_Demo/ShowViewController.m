//
//  ShowViewController.m
//  TFTP_Demo
//
//  Created by 刘超 on 2017/12/22.
//  Copyright © 2017年 刘超. All rights reserved.
//

#import "ShowViewController.h"

@interface ShowViewController ()

@end

@implementation ShowViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view.
    
    self.view.backgroundColor = [UIColor whiteColor];
    
    UIImageView *img = [[UIImageView alloc] initWithFrame:self.view.bounds];
    img.image = self.image;
    img.userInteractionEnabled = YES;
    [self.view addSubview:img];
    
    [img addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(clickImgAction)]];
}

- (void)clickImgAction
{
    [self dismissViewControllerAnimated:YES completion:nil];
}


@end
