#include <stddef.h>
#include <stdint.h>

int LLVMFuzzerTestOneInput(const uint8_t *d, size_t n) {
    if (n >= 4 && d[0] == 'F' && d[1] == 'U' && d[2] == 'Z' && d[3] == 'Z')
        __builtin_trap();
    return 0;
}
