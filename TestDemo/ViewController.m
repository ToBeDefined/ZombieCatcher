//
//  ViewController.m
//  TestDemo
//
//  Created by TBD on 2022/4/28.
//

#import "ViewController.h"
#import <ZombieCatcher/ZombieCatcher.h>

@interface ViewController ()

@end

@implementation ViewController

+ (void)load {
    // open_zombie_catcher();
}

- (void)viewDidLoad {
    [super viewDidLoad];
}

- (IBAction)openCatcher:(UIButton *)sender {
    open_zombie_catcher();
    [sender setTitle:@"ZombieCatcher Is Open" forState:UIControlStateDisabled];
    [sender setTitleColor:UIColor.whiteColor forState:UIControlStateDisabled];
    [sender setBackgroundColor:UIColor.grayColor];
    sender.enabled = NO;
}

- (IBAction)zombieViewCall:(UIButton *)sender {
    UIView *zombieView = [[UIView alloc] init];
    [zombieView release];
    
    for (int i = 0; i < 10000; i++) {
        UIView *testView = [[UIView alloc] init];
        [testView autorelease];
    }
    
    [zombieView setNeedsLayout];
}


@end
