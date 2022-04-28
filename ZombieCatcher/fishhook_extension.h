//
//  fishhook_extension.h
//  TestZombie
//
//  Created by TBD on 2022/4/27.
//

#ifndef fishhook_extension_h
#define fishhook_extension_h

#include <stdio.h>

#include "fishhook.h"

void rebind_symbols_for_imagename(struct rebinding rebindings[],
                                  size_t rebindings_nel,
                                  const char *image_name);

#endif /* fishhook_extension_h */
