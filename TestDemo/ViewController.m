//
//  ViewController.m
//  TestDemo
//
//  Created by TBD on 2022/4/28.
//

#import "ViewController.h"

@interface ViewController ()

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
}


- (IBAction)createZombieViews:(id)sender {
    int nums = 10000;
    NSLog(@"create %d views", nums);
    for (int i = 0; i < nums; ++i) {
        UIView *testView = [[UIView alloc] init];
        [testView release];
    }
}

- (IBAction)zombieViewCall:(id)sender {
    UIView *zombieView = [[UIView alloc] init];
    [zombieView release];
    for (int i = 0; i < 100; ++i) {
        UIView *testView = [[UIView alloc] init];
        [testView release];
    }
    [zombieView setNeedsLayout];
}


@end
