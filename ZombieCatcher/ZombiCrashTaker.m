//
//  ZombiCrashTaker.m
//  ZombieCatcher
//
//  Created by TBD on 2022/4/29.
//

#import "ZombiCrashTaker.h"


@interface ZombiCrashTaker () <NSCopying, NSMutableCopying>

@end

@implementation ZombiCrashTaker

#pragma mark - Singletion
#pragma mark -

static ZombiCrashTaker *_instance;
+ (ZombiCrashTaker *)shared {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
#if __has_feature(objc_arc)
        _instance = [[self alloc] init];
#else
        _instance = [[[self alloc] init] autorelease];
#endif
    });
    return _instance;
}

+ (instancetype)allocWithZone:(struct _NSZone *)zone {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _instance = [super allocWithZone:zone];
    });
    return _instance;
}

- (instancetype)init {
    self = [super init];
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (self) {
            /// init
        }
    });
    return self;
}

- (instancetype)copyWithZone:(NSZone *)zone {
    return _instance;
}

- (instancetype)mutableCopyWithZone:(NSZone *)zone {
    return _instance;
}

#if !__has_feature(objc_arc)
- (instancetype)retain { return self; }
- (NSUInteger)retainCount { return NSUIntegerMax; }
- (oneway void)release {}
- (instancetype)autorelease{ return self; }
#endif

#pragma mark - Function
#pragma mark -
- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector {
    return [NSObject instanceMethodSignatureForSelector:@selector(init)];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    void *null = NULL;
    [invocation setReturnValue:&null];
}

@end
