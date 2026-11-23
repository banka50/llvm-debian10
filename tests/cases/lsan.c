#include <stdlib.h>

void *volatile p;

int main(void) {
    p = malloc(7);
    p = 0; /* leak */
    return 0;
}
