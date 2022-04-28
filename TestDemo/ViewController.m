//
//  ViewController.m
//  TestDemo
//
//  Created by TBD on 2022/4/28.
//

#import "ViewController.h"
#import <ZombieCatcher/ZombieCatcher.h>

@interface ViewController ()
@property (nonatomic, assign) BOOL isOpen;
@end

@implementation ViewController

+ (void)load {
    // open_zombie_catcher();
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.isOpen = NO;
}

- (IBAction)openCatcher:(UIButton *)sender {
    open_zombie_catcher(^(void * _Nonnull ptr, const char * _Nonnull className, const char * _Nullable classSubName, SEL  _Nonnull selector) {
        NSString *message = nil;
        if (classSubName) {
            message = [NSString stringWithFormat:@"发现 ZombieObject 调用: <%p : %s : %s>, selector: %s", ptr, className, classSubName, sel_getName(selector)];
        } else {
            message = [NSString stringWithFormat:@"发现 ZombieObject 调用: <%p : %s>, selector: %s", ptr, className, sel_getName(selector)];
        }
        UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"ZombieCatcher"
                                                                                 message:message preferredStyle:UIAlertControllerStyleAlert];
        [alertController addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDestructive handler:nil]];
        [self presentViewController:alertController animated:YES completion:nil];
    });
    
    [sender setTitle:@"ZombieCatcher Is Open" forState:UIControlStateDisabled];
    [sender setTitleColor:UIColor.whiteColor forState:UIControlStateDisabled];
    [sender setBackgroundColor:UIColor.grayColor];
    sender.enabled = NO;
    self.isOpen = YES;
}

- (IBAction)zombieViewCall:(UIButton *)sender {
    UIView *zombieView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 100, 100)];
    [zombieView release];
    
    for (int i = 0; i < 10000; i++) {
        UIView *testView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 200, 200)];
        [testView autorelease];
    }
    
    /// random call function
    int i = arc4random() % 5;
    switch (i) {
        case 0:
            [zombieView setNeedsLayout];
            break;
            
        case 1:
            [zombieView layoutSubviews];
            break;
            
        case 2: {
            CALayer *layer = zombieView.layer;
            NSLog(@"zombieView layer is: %@", layer);
            break;
        }
            
        case 3: {
            CGRect frame = [zombieView frame];
            /// 如果不进行捕获这里极有可能打印的是 {0, 0, 200, 200}, 因为 zombieView 被释放了, for 循环中复用了这块内存创建了 200 宽高的 view
            NSLog(@"zombieView frame is: {%f, %f, %f, %f}", frame.origin.x, frame.origin.y, frame.size.width, frame.size.height);
            break;
        }
            
        default: {
            if (!self.isOpen) {
                /// 没开启情况下, 再次 release 会闪退
                [zombieView layoutIfNeeded];
            } else{
                /// 开启时候检测 release 的调用
                [zombieView release];
            }
            break;
        }
    }
}


@end
