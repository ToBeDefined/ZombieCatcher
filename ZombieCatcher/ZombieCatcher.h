//
//  ZombieCatcher.h
//  ZombieCatcher
//
//  Created by TBD on 2022/4/28.
//

#import <Foundation/Foundation.h>

//! Project version number for ZombieCatcher.
FOUNDATION_EXPORT double ZombieCatcherVersionNumber;

//! Project version string for ZombieCatcher.
FOUNDATION_EXPORT const unsigned char ZombieCatcherVersionString[];

// In this header, you should import all the public headers of your framework using statements like #import <ZombieCatcher/PublicHeader.h>



#ifdef __cplusplus
extern "C" {
#endif

void open_zombie_catcher(void);

void free_some_memory(size_t freeNum);

#ifdef __cplusplus
}
#endif
