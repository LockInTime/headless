#include "headless_version.h"

#ifndef HEADLESS_PRODUCT_VERSION
#error "HEADLESS_PRODUCT_VERSION must be defined by Package.swift"
#endif

const char *headless_product_version(void) {
    return HEADLESS_PRODUCT_VERSION;
}
