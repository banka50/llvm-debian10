#include <stdlib.h>

int main(int argc, char **argv) {
    (void)argv;
    int *a = malloc(10 * sizeof(int));
    int r = a[argc + 9]; /* heap-buffer-overflow: a[10] */
    free(a);
    return r;
}
