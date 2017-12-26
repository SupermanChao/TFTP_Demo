//
//  ViewController.m
//  TFTP_Demo
//
//  Created by 刘超 on 2017/12/22.
//  Copyright © 2017年 刘超. All rights reserved.
//

#import "ViewController.h"
#import "ClientViewController.h"
#import "ServerViewController.h"

@interface ViewController ()

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view, typically from a nib.
    NSLog(@"%@",NSHomeDirectory());
}

- (IBAction)goServerAction:(id)sender {
    ServerViewController *server = [[ServerViewController alloc] init];
    [self.navigationController pushViewController:server animated:YES];
}

- (IBAction)goClientAction:(id)sender {
    ClientViewController *client = [[ClientViewController alloc] init];
    [self.navigationController pushViewController:client animated:YES];
}


- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}


@end
