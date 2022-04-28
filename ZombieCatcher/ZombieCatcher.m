//
//  ZombieCatcher.m
//  TestZombie
//
//  Created by TBD on 2022/4/27.
//

#import <Foundation/Foundation.h>
#import <libkern/OSAtomicQueue.h>
#import <pthread.h>
#import <objc/runtime.h>
#import <malloc/malloc.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import "fishhook.h"
#import "fishhook_extension.h"
#import "AppDelegate.h"

#pragma mark - statement

static void _recorder_memory_ptr(void *ptr);

static void _free_some_memory(size_t freeNum);

void free_some_memory(size_t size) {
    _free_some_memory(size);
}

#pragma mark - hook free

typedef void (*free_func_type)(void *);

static free_func_type orig_free = NULL;

void _hooked_free(void *ptr) {
    _recorder_memory_ptr(ptr);
}

bool hook_free_function_for_objc(void) {
    struct rebinding rebind_infos [] = {
        {
            .name = "free",
            .replacement = (void *)_hooked_free,
            .replaced = (void **)&orig_free,
        }
    };
    
    /// 因为 dyld_shared_cache, 可能 libobjc 中直接调用的 free 内存而不是查找符号表, 此时返回是否 hook 成功, 如果失败, 走 dealloc 方法 hook 的方式
    rebind_symbols_for_imagename(rebind_infos, sizeof(rebind_infos) / sizeof(struct rebinding), "libobjc.A.dylib");
    return orig_free != NULL;
}

#pragma mark - HookDealloc Placeholder
static BOOL UseDestructInstanceBefore = true;
static IMP  OriginDeallocIMP          = NULL;

@interface NSObject(HookDealloc)

@end

@implementation NSObject(HookDealloc)

- (void)HookedDealloc {
    // /// 需要对应将 UseDestructInstanceBefore 标记置为 false
    // /// 如果不调用 objc_destructInstance适当对象，而只记录内存,
    // /// 需要在之后释放时调用真正的 dealloc 方法进行完整释放, 防止泄露
    // _recorder_memory_ptr((__bridge void *)self);

    /// 需要对应将 UseDestructInstanceBefore 标记置为 true
    /// objc_destructInstance 可以释放所有的关联以及 weak 等处理造作,
    /// 但是不会调用 free 释放内存, 后续释放内存的处理只需要调用 free 操作,
    /// 提前析构对象的好处是这片内存之后可以随意操作, 这里采用提前析构
    void *ptr = objc_destructInstance(self);
    _recorder_memory_ptr(ptr);
}

@end


#pragma mark - Memory Pointer Queue
static OSQueueHead freePtrQueue = OS_ATOMIC_QUEUE_INIT;

typedef struct {
    void *ptr;
    void *next;
} MemNode;

static size_t queueSize = 0;
static size_t unfreeMemSize = 0;

#define MAX_STEAL_MEM_SIZE  (1024 * 1024 * 100)
#define MAX_STEAL_MEM_NUM   (1024 * 1024 * 10)
#define BATCH_FREE_NUM      (100)

static malloc_zone_t *zombie_node_zone = NULL;

void initialize_recorder_memory_zone(void) {
    if (zombie_node_zone == NULL) {
        zombie_node_zone = malloc_create_zone(0, 0);
        malloc_set_zone_name(zombie_node_zone, "ZOMBIE_NODE_ZONE");
    }
}


#pragma mark - ZombieCatcher

#ifdef __LP64__
#define CLASS_WITH_CF_ID_MASK        0x7FFFFFFFFFFFFFFFULL
typedef union ClassOrCFType {
    uintptr_t bits;
    struct {
        uintptr_t clsOrTypeID       : 61;
        uintptr_t isCFType          : 1;
    };
} ClassOrCFType;
#else
#define CLASS_WITH_CF_ID_MASK        0x7FFFFFFFULL
typedef union ClassOrCFType {
    uintptr_t bits;
    struct {
        uintptr_t clsOrTypeID       : 31;
        uintptr_t isCFType          : 1;
    };
} ClassOrCFType;
#endif

static CFMutableSetRef  registeredClasses      = NULL;

static Class            ZombieCatcherClass     = NULL;
static size_t           ZombieCatcherMinByte   = 16;
static BOOL             UseDeallocHook         = false;

static const char       *ZombieCatcherPrefix   = "__ZombieCatcher_";
static size_t           ZombieCatcherPrefixLen = 16;

static inline
void LogErrorWithAbort(void *ptr, Class cls, ClassOrCFType type, const char *selectorName) {
    if (UseDeallocHook && !UseDestructInstanceBefore) {
        const char *name = class_getName(cls);
        if (strncmp(name, ZombieCatcherPrefix, ZombieCatcherPrefixLen) == 0) {
            NSLog(@"发现野指针调用: <%p, %s>, selector: %s", ptr, name + ZombieCatcherPrefixLen, selectorName);
        }
    } else {
        if (type.isCFType) {
            NSLog(@"发现野指针调用: <%p, __NSCFType : %@>, selector: %s", ptr, (__bridge NSString *)CFCopyTypeIDDescription(type.bits & CLASS_WITH_CF_ID_MASK), selectorName);
        } else {
            NSLog(@"发现野指针调用: <%p, %s>, selector: %s", ptr, class_getName((__bridge Class)(void *)(type.bits & CLASS_WITH_CF_ID_MASK)), selectorName);
        }
    }
    abort();
}

@interface ZombieCatcher : NSObject

@property (nonatomic, assign) ClassOrCFType typeInfo;

@end

@implementation ZombieCatcher

+ (void)load {
    ZombieCatcherPrefixLen = strlen(ZombieCatcherPrefix);
    ZombieCatcherClass = self;
    ZombieCatcherMinByte = class_getInstanceSize(self);
    
    registeredClasses = CFSetCreateMutable(NULL, 0, NULL);
    
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    for (unsigned int i = 0; i < count; i++) {
        CFSetAddValue(registeredClasses, (__bridge const void *)(classes[i]));
    }
    
    free(classes);
    
    initialize_recorder_memory_zone();
    BOOL isSuccess = hook_free_function_for_objc();
    if (!isSuccess) {
        // HOOK DEALLOC FUNCTION
        UseDeallocHook = true;
        Method origDealloc = class_getInstanceMethod(NSObject.class, @selector(dealloc));
        OriginDeallocIMP = method_getImplementation(origDealloc);
        Method newDealloc = class_getInstanceMethod(NSObject.class, @selector(HookedDealloc));
        method_exchangeImplementations(origDealloc, newDealloc);
    }
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
    LogErrorWithAbort((__bridge void *)self, self.class, _typeInfo, sel_getName(aSelector));
    return nil;
}

- (void)dealloc {
    LogErrorWithAbort((__bridge void *)self, self.class, _typeInfo, "dealloc");
    [super dealloc];
}

- (instancetype)copyWithZone:(NSZone *)zone {
    LogErrorWithAbort((__bridge void *)self, self.class, _typeInfo, "copyWithZone:");
    return nil;
}

- (instancetype)mutableCopyWithZone:(NSZone *)zone {
    LogErrorWithAbort((__bridge void *)self, self.class, _typeInfo, "mutableCopyWithZone:");
    return nil;
}

- (instancetype)retain {
    LogErrorWithAbort((__bridge void *)self, self.class, _typeInfo, "retain");
    return nil;
}

- (NSUInteger)retainCount {
    LogErrorWithAbort((__bridge void *)self, self.class, _typeInfo, "retainCount");
    return 0;
}

- (oneway void)release {
    LogErrorWithAbort((__bridge void *)self, self.class, _typeInfo, "release");
}

- (instancetype)autorelease {
    LogErrorWithAbort((__bridge void *)self, self.class, _typeInfo, "autorelease");
    return nil;
}

@end


#pragma mark - recorder_memory_ptr

typedef struct {
    Class isa;
} objc_object_simulate;

static void _recorder_memory_ptr(void *ptr) {
    /// 如果超过内存限制, 释放部分内存
    if (queueSize > MAX_STEAL_MEM_NUM * 0.9 || unfreeMemSize > MAX_STEAL_MEM_SIZE) {
        _free_some_memory(BATCH_FREE_NUM);
    }
    
    if (ptr == NULL) {
        return;
    }
    
    size_t memSize = malloc_size(ptr);
    Class origClass = NULL;
    ClassOrCFType typeInfo;
    typeInfo.bits = 0x00;
    if (memSize >= ZombieCatcherMinByte) {
        objc_object_simulate *object = (objc_object_simulate *)ptr;
        
#ifdef __arm64__
        /// 系统内部定义的变量, isa mask
        // See http://www.sealiesoftware.com/blog/archive/2013/09/24/objc_explain_Non-pointer_isa.html
        extern uint64_t objc_debug_isa_class_mask WEAK_IMPORT_ATTRIBUTE;
        origClass = (__bridge Class)(void *)((uint64_t)object->isa & objc_debug_isa_class_mask);
#else
        origClass = object->isa;
#endif
        if (CFSetContainsValue(registeredClasses, (__bridge void *)origClass)) {
            if (strcmp(class_getName(origClass), "__NSCFType") == 0) {
                CFTypeID cfTypeID = CFGetTypeID(ptr);
                typeInfo.isCFType = true;
                typeInfo.clsOrTypeID = cfTypeID;
                // printf("hook memory: %s\n", [(__bridge NSString *)CFCopyTypeIDDescription(cfTypeID) UTF8String]);
            } else {
                typeInfo.isCFType = false;
                typeInfo.clsOrTypeID = (uintptr_t)origClass;
                // printf("hook memory: %s\n", class_getName(origClass));
            }
        }
    }
    
    if (!UseDestructInstanceBefore && UseDeallocHook && origClass) {
        /// 没有提前析构对象的话, 不能随意操作这篇内存
        char newClsName[256] = { 0 };
        strcpy(newClsName, ZombieCatcherPrefix);
        strcpy(newClsName + ZombieCatcherPrefixLen, class_getName(origClass));
        Class newCls = objc_getClass(newClsName);
        if (newCls == NULL) {
            newCls = objc_duplicateClass(ZombieCatcherClass, newClsName, 0);
        }
        /// Hook dealloc 方式不写入脏内存
        object_setClass((__bridge id)ptr, newCls);
    } else {
        /// 写入脏内存
        memset(ptr, 0x55, memSize);
        
        /// 判断是否是注册的 Class
        if (typeInfo.bits) {
            /// 将 isa 指向为 zombie class
            memcpy(ptr, &ZombieCatcherClass, sizeof(void *));
            
            /// 将内存原始信息放到 zombie 对象中
            ZombieCatcher *zombieObject = (__bridge ZombieCatcher *)ptr;
            zombieObject.typeInfo = typeInfo;
        }
    }
    
    /// 入队
    MemNode *node = (MemNode *)malloc_zone_malloc(zombie_node_zone, sizeof(MemNode));
    *node = (MemNode){ptr, NULL};
    OSAtomicEnqueue(&freePtrQueue, node, offsetof(MemNode, next));
    __sync_fetch_and_add(&queueSize, 1);
    __sync_fetch_and_add(&unfreeMemSize, memSize);
}



#pragma mark - free_some_memory
/// dequeue 取出内存地址进行释放操作
static void _free_some_memory(size_t freeNum) {
    size_t realFreeCount = freeNum > queueSize ? queueSize : freeNum;
    for (int i = 0; i < realFreeCount; ++i) {
        MemNode *node = (MemNode *)OSAtomicDequeue(&freePtrQueue, offsetof(MemNode, next));
        if (node == NULL) {
            return;
        }
        void *obj_ptr = node->ptr;
        malloc_zone_free(zombie_node_zone, node);
        
        size_t memSize = malloc_size(obj_ptr);
        __sync_fetch_and_sub(&queueSize, 1);
        __sync_fetch_and_sub(&unfreeMemSize, memSize);
        
        /// 使用了 hook free 形式并且成功了, 调用 orig_free 进行释放
        if (!UseDeallocHook) {
            orig_free(obj_ptr);
            continue;
        }
        
        /// 没使用 hook free 形式, 如果之前已经析构了对象, 调用 free 进行释放
        if (UseDestructInstanceBefore) {
            free(obj_ptr);
            continue;
        }
        
        /// 没使用 hook free 形式, 也没提前析构对象, 需要还原对象的 isa 指针, 同时调用原始的 dealloc 方法
        id obj = (__bridge id)obj_ptr;
        Class cls = object_getClass(obj);
        const char *name = class_getName(cls);
        if (strncmp(name, ZombieCatcherPrefix, ZombieCatcherPrefixLen) == 0) {
            cls = objc_getClass(name + ZombieCatcherPrefixLen);
        }
        object_setClass(obj, cls);
        // [obj HookedDealloc];
        ((void(*)(id))OriginDeallocIMP)(obj);
    }
}

