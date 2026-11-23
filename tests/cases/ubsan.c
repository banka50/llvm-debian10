#include <limits.h>

int main(int argc, char **argv) {
    (void)argv;
    int x = INT_MAX;
    x += argc; /* signed integer overflow */
    return x == 0;
}
