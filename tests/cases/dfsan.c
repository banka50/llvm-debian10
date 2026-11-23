#include <sanitizer/dfsan_interface.h>

int main(void) {
    int i = 1;
    dfsan_set_label(1, &i, sizeof(i));
    int j = i + 1;
    return dfsan_get_label(j) == 1 ? 0 : 1;
}
