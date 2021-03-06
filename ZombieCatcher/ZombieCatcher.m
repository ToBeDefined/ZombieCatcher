//
//  ZombieCatcher.m
//  TestZombie
//
//  Created by TBD on 2022/4/27.
//

#import <Foundation/Foundation.h>
#import <libkern/OSAtomicQueue.h>
#import <os/base.h>
#import <os/lock.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <malloc/malloc.h>

#import "ZombieCatcher.h"
#import "ZombiCrashTaker.h"
#import "fishhook.h"
#import "fishhook_extension.h"

#pragma mark - statement
static void _open_zombie_catcher(void);

static void _recorder_memory_ptr(void *ptr);

static void _free_some_memory(size_t freeNum);

static NSLock *callbackArrayLock = nil;
static NSMutableArray *callbackArray = nil;
void open_zombie_catcher(ZombieCatcherCallback callback) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        callbackArrayLock = [[NSLock alloc] init];
        callbackArray = [[NSMutableArray alloc] init];
    });
    
    if (callback) {
        [callbackArrayLock lock];
        [callbackArray addObject:[callback copy]];
        [callbackArrayLock unlock];
    }
    
    _open_zombie_catcher();
}

void free_some_memory(size_t size) {
    _free_some_memory(size);
}

#pragma mark - Global

typedef void (*free_func_type)(void *);

typedef struct {
    void *ptr;
    void *next;
} MemNode;

static BOOL             IsHooked                  = NO;
static BOOL             IsUseFreeHook             = NO;
static BOOL             IsPreDestructObject       = NO;
static IMP              OriginDeallocIMP          = NULL;
static free_func_type   OriginFreeFunc            = NULL;

static malloc_zone_t    *MemNodeZone              = NULL;
static OSQueueHead      StealPtrQueue             = OS_ATOMIC_QUEUE_INIT;
static size_t           StealPtrQueueSize         = 0;
static size_t           StealPtrMemSize           = 0;

static CFMutableSetRef  RegisteredClasses         = NULL;

static Class            ZombieCatcherClass        = NULL;
static size_t           ZombieCatcherMinByte      = 16;

static const char       *ZombieCatcherPrefix      = "__ZombieCatcher_";
static size_t           ZombieCatcherPrefixLength = 16;

#define MAX_STEAL_PTR_NUM                           (10 * 1024 * 1024)
#define MAX_STEAL_MEM_SIZE                          (100 * 1024 * 1024)
#define BATCH_FREE_NUM                              (100)



#pragma mark - hook free
void _hooked_free(void *ptr) {
    _recorder_memory_ptr(ptr);
}

bool hook_free_function_for_objc(void) {
    struct rebinding rebind_free [] = {
        {
            .name = "free",
            .replacement = (void *)_hooked_free,
            .replaced = (void **)&OriginFreeFunc,
        }
    };
    
    /// ?????? dyld_shared_cache, ?????? libobjc ?????????????????? free ??????????????????????????????, ?????????????????? hook ??????, ????????????, ??? dealloc ?????? hook ?????????
    rebind_symbols_for_imagename(rebind_free, sizeof(rebind_free) / sizeof(struct rebinding), "libobjc.A.dylib");
    return OriginFreeFunc != NULL;
}

#pragma mark - HookDealloc Placeholder
@interface NSObject(HookDealloc)

@end

@implementation NSObject(HookDealloc)

- (void)HookedDealloc {
    /// `objc_destructInstance(id)` ????????????????????????????????? weak ???????????????,
    /// ?????????????????? free ????????????, ?????????????????????????????????????????? free ??????,
    /// ???????????????????????????, ?????????????????????????????????, ??????????????????????????????,
    /// ??????????????????, ???????????????????????????????????????????????????, ???????????? zombie ??????,
    /// ????????????????????????????????????????????????????????????????????????, ????????????????????????
    if (OS_EXPECT(IsPreDestructObject, YES)) {
        objc_destructInstance(self);
    }
    _recorder_memory_ptr((__bridge void *)self);
}

@end


#pragma mark - ZombieCatcher

#ifdef __LP64__
#define CLASS_OR_CF_ID_MASK         0x7FFFFFFFFFFFFFFFULL
typedef union ClassOrCFType {
    uintptr_t bits;
    struct {
        uintptr_t clsOrTypeID       : 63;
        uintptr_t isCFType          : 1;
    };
} ClassOrCFType;
#else
#define CLASS_OR_CF_ID_MASK         0x7FFFFFFF
typedef union ClassOrCFType {
    uintptr_t bits;
    struct {
        uintptr_t clsOrTypeID       : 31;
        uintptr_t isCFType          : 1;
    };
} ClassOrCFType;
#endif

static inline void LoggingAndCallback(void *ptr, Class cls, ClassOrCFType type, SEL selector) {
    const char *className = NULL;
    CFStringRef cfTypeString = NULL;
    
    if (!IsUseFreeHook && !IsPreDestructObject) {
        const char *name = class_getName(cls);
        if (strncmp(name, ZombieCatcherPrefix, ZombieCatcherPrefixLength) == 0) {
            className = name + ZombieCatcherPrefixLength;
        } else {
            className = name;
        }
    } else {
        if (type.isCFType) {
            className = "__NSCFType";
            cfTypeString = CFCopyTypeIDDescription(type.bits & CLASS_OR_CF_ID_MASK);
        } else {
            className = class_getName((__bridge Class)(void *)(type.bits & CLASS_OR_CF_ID_MASK));
        }
    }
    
    /// Log
    if (cfTypeString) {
        NSLog(@"?????? ZombieObject ??????: <%p : %s : %@>, selector: %s", ptr, className, (__bridge NSString *)cfTypeString, sel_getName(selector));
    } else {
        NSLog(@"?????? ZombieObject ??????: <%p : %s>, selector: %s", ptr, className, sel_getName(selector));
    }
    
    /// callback
    [callbackArrayLock lock];
    for (ZombieCatcherCallback block in callbackArray) {
        block(ptr, className, [(__bridge NSString *)cfTypeString UTF8String], selector);
    }
    [callbackArrayLock unlock];
    
    /// release CFStringRef
    if (cfTypeString) {
        CFRelease(cfTypeString);
    }
}

@interface ZombieCatcher : NSObject

@property (nonatomic, assign) ClassOrCFType typeInfo;

@end

@implementation ZombieCatcher

- (id)forwardingTargetForSelector:(SEL)aSelector {
    LoggingAndCallback((__bridge void *)self, self.class, _typeInfo, aSelector);
    return ZombiCrashTaker.shared;
}

- (void)dealloc {
    LoggingAndCallback((__bridge void *)self, self.class, _typeInfo, _cmd);
    [super dealloc];
}

- (instancetype)copyWithZone:(NSZone *)zone {
    LoggingAndCallback((__bridge void *)self, self.class, _typeInfo, _cmd);
    return nil;
}

- (instancetype)mutableCopyWithZone:(NSZone *)zone {
    LoggingAndCallback((__bridge void *)self, self.class, _typeInfo, _cmd);
    return nil;
}

- (instancetype)retain {
    LoggingAndCallback((__bridge void *)self, self.class, _typeInfo, _cmd);
    return nil;
}

- (NSUInteger)retainCount {
    LoggingAndCallback((__bridge void *)self, self.class, _typeInfo, _cmd);
    return 0;
}

- (oneway void)release {
    LoggingAndCallback((__bridge void *)self, self.class, _typeInfo, _cmd);
}

- (instancetype)autorelease {
    LoggingAndCallback((__bridge void *)self, self.class, _typeInfo, _cmd);
    return nil;
}

@end

static os_unfair_lock InitLock = OS_UNFAIR_LOCK_INIT;
static void _open_zombie_catcher(void) {
    os_unfair_lock_lock(&InitLock);
    if (IsHooked) {
        os_unfair_lock_unlock(&InitLock);
        return;
    }
    ZombieCatcherPrefixLength = strlen(ZombieCatcherPrefix);
    ZombieCatcherClass = ZombieCatcher.class;
    ZombieCatcherMinByte = class_getInstanceSize(ZombieCatcher.class);
    
    RegisteredClasses = CFSetCreateMutable(NULL, 0, NULL);
    
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    for (unsigned int i = 0; i < count; i++) {
        CFSetAddValue(RegisteredClasses, (__bridge const void *)(classes[i]));
    }
    
    free(classes);
    
    if (MemNodeZone == NULL) {
        MemNodeZone = malloc_create_zone(0, 0);
        malloc_set_zone_name(MemNodeZone, "ZOMBIE_CATCHER_MEM_NODE_ZONE");
    }
    
    BOOL isSuccess = hook_free_function_for_objc();
    if (isSuccess) {
        // hook `free`
        IsUseFreeHook = YES;
    } else {
        // hook `-dealloc`
        IsUseFreeHook = NO;
        IsPreDestructObject = YES;
        
        Method deallocMethod = class_getInstanceMethod(NSObject.class, @selector(dealloc));
        OriginDeallocIMP = method_getImplementation(deallocMethod);
        
        Method hookedDeallocMethod = class_getInstanceMethod(NSObject.class, @selector(HookedDealloc));
        method_exchangeImplementations(deallocMethod, hookedDeallocMethod);
    }
    
    IsHooked = YES;
    os_unfair_lock_unlock(&InitLock);
}

#pragma mark - recorder_memory_ptr
typedef struct {
    Class isa;
} objc_object_simulate;

static void _recorder_memory_ptr(void *ptr) {
    /// ????????????????????????, ??????????????????
    if (StealPtrQueueSize > MAX_STEAL_PTR_NUM * 0.9 || StealPtrMemSize > MAX_STEAL_MEM_SIZE) {
        _free_some_memory(BATCH_FREE_NUM);
    }
    
    if (ptr == NULL) {
        return;
    }
    
    size_t memSize = malloc_size(ptr);
    ClassOrCFType typeInfo;
    typeInfo.bits = 0x00;
    if (memSize >= ZombieCatcherMinByte) {
        objc_object_simulate *object = (objc_object_simulate *)ptr;
        
#ifdef __arm64__
        /// ???????????????????????????, isa mask
        // See http://www.sealiesoftware.com/blog/archive/2013/09/24/objc_explain_Non-pointer_isa.html
        extern uint64_t objc_debug_isa_class_mask WEAK_IMPORT_ATTRIBUTE;
        Class origClass = (__bridge Class)(void *)((uint64_t)object->isa & objc_debug_isa_class_mask);
#else
        Class origClass = object->isa;
#endif
        /// ?????????????????? hook dealloc ??????, ??????????????????????????????????????????????????????
        if (!IsUseFreeHook || CFSetContainsValue(RegisteredClasses, (__bridge void *)origClass)) {
            if (strcmp(class_getName(origClass), "__NSCFType") == 0) {
                CFTypeID cfTypeID = CFGetTypeID(ptr);
                NSCAssert((cfTypeID & ~CLASS_OR_CF_ID_MASK) == 0x00, @"ERROR: CFTypeID too big");
                typeInfo.isCFType = true;
                typeInfo.clsOrTypeID = cfTypeID;
                // printf("hook memory: %s\n", [(__bridge NSString *)CFCopyTypeIDDescription(cfTypeID) UTF8String]);
            } else {
                NSCAssert(((uintptr_t)origClass & ~CLASS_OR_CF_ID_MASK) == 0x00, @"ERROR: Class ptr error");
                typeInfo.isCFType = false;
                typeInfo.clsOrTypeID = (uintptr_t)origClass;
                // printf("hook memory: %s\n", class_getName(origClass));
            }
        }
    }
    
    if (OS_EXPECT(IsUseFreeHook || IsPreDestructObject, YES)) {
        /// ???????????? free hook ??????, ???????????????????????????, ?????????????????????
        memset(ptr, 0x55, memSize);
        
        /// ???????????????????????? Class
        if (typeInfo.bits) {
            /// ??? isa ????????? zombie class
            memcpy(ptr, &ZombieCatcherClass, sizeof(void *));
            
            /// ??????????????????????????? zombie ?????????
            ZombieCatcher *zombieObject = (__bridge ZombieCatcher *)ptr;
            zombieObject.typeInfo = typeInfo;
        }
    } else {
        /// ??? hook dealloc ?????????, ????????????????????????????????????, ??????????????????????????????, ?????????????????????
        char newClsName[256] = { 0 };
        strcpy(newClsName, ZombieCatcherPrefix);
        strcpy(newClsName + ZombieCatcherPrefixLength, class_getName((__bridge Class)(void *)typeInfo.clsOrTypeID));
        Class newCls = objc_getClass(newClsName);
        if (newCls == NULL) {
            newCls = objc_duplicateClass(ZombieCatcherClass, newClsName, 0);
        }
        object_setClass((__bridge id)ptr, newCls);
    }
    
    /// ??????
    MemNode *node = (MemNode *)malloc_zone_malloc(MemNodeZone, sizeof(MemNode));
    *node = (MemNode){ptr, NULL};
    OSAtomicEnqueue(&StealPtrQueue, node, offsetof(MemNode, next));
    __sync_fetch_and_add(&StealPtrQueueSize, 1);
    __sync_fetch_and_add(&StealPtrMemSize, memSize);
}


#pragma mark - free_some_memory
/// dequeue ????????????????????????????????????
static void _free_some_memory(size_t freeNum) {
    if (!IsHooked) {
        return;
    }
    size_t size = StealPtrQueueSize;
    size_t realFreeCount = freeNum > size ? size : freeNum;
    for (int i = 0; i < realFreeCount; ++i) {
        MemNode *node = (MemNode *)OSAtomicDequeue(&StealPtrQueue, offsetof(MemNode, next));
        if (node == NULL) {
            return;
        }
        void *obj_ptr = node->ptr;
        malloc_zone_free(MemNodeZone, node);
        
        size_t memSize = malloc_size(obj_ptr);
        __sync_fetch_and_sub(&StealPtrQueueSize, 1);
        __sync_fetch_and_sub(&StealPtrMemSize, memSize);
        
        /// ????????? hook free ?????????????????????, ?????? orig_free ????????????
        if (IsUseFreeHook) {
            OriginFreeFunc(obj_ptr);
            continue;
        }
        
        /// ????????? hook free ??????, ?????????????????????????????????, ?????? free ????????????
        if (IsPreDestructObject) {
            free(obj_ptr);
            continue;
        }
        
        /// ????????? hook free ??????, ????????????????????????, ????????????????????? isa ??????, ????????????????????? dealloc ??????
        id obj = (__bridge id)obj_ptr;
        Class cls = object_getClass(obj);
        const char *name = class_getName(cls);
        if (strncmp(name, ZombieCatcherPrefix, ZombieCatcherPrefixLength) == 0) {
            cls = objc_getClass(name + ZombieCatcherPrefixLength);
        }
        object_setClass(obj, cls);
        // [obj HookedDealloc];
        ((void(*)(id))OriginDeallocIMP)(obj);
    }
}

