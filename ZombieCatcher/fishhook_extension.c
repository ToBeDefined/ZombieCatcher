//
//  fishhook_extension.c
//  TestZombie
//
//  Created by TBD on 2022/4/27.
//

#include "fishhook_extension.h"
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>


#ifdef __LP64__
typedef struct mach_header_64 mach_header_t;
typedef struct segment_command_64 segment_command_t;
typedef struct section_64 section_t;
#else
typedef struct mach_header mach_header_t;
typedef struct segment_command segment_command_t;
typedef struct section section_t;
#endif


void rebind_symbols_for_imagename(struct rebinding rebindings[],
                                  size_t rebindings_nel,
                                  const char *image_name) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const mach_header_t* header = (const mach_header_t*)_dyld_get_image_header(i);
        const char *name = _dyld_get_image_name(i);
        const char *tmp = strrchr(name, '/');
        long slide = _dyld_get_image_vmaddr_slide(i);
        if (tmp) {
            name = tmp + 1;
        }
        if (strcmp(name, image_name) == 0){
            rebind_symbols_image((void *)header,
                                 slide,
                                 rebindings,
                                 rebindings_nel);
            break;
        }
    }
}
