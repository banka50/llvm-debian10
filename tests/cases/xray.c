#include <stdio.h>

__attribute__((xray_always_instrument, noinline)) int twice(int x) { return x * 2; }

int main(void) {
    int s = 0;
    for (int i = 0; i < 10; i++)
        s += twice(i);
    printf("%d\n", s);
    return 0;
}
