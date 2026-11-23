/* No headers, so it compiles for any target without a sysroot. */
unsigned long long fnv1a(const unsigned char *p, unsigned long n) {
    unsigned long long h = 1469598103934665603ull;
    while (n--)
        h = (h ^ *p++) * 1099511628211ull;
    return h;
}
