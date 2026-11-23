#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    (void)argv;
    int *a = malloc(10 * sizeof(int));
    a[5] = 0;
    if (a[argc]) /* a[1] is uninitialized */
        printf("xx\n");
    free(a);
    return 0;
}
