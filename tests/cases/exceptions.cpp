#include <cstdio>
#include <stdexcept>

static int unwound = 0;
struct Guard {
    ~Guard() { ++unwound; }
};

[[gnu::noinline]] static void thrower(int depth) {
    Guard g;
    if (depth == 0)
        throw std::runtime_error("boom");
    thrower(depth - 1);
}

int main() {
    try {
        thrower(5);
    } catch (const std::exception &e) {
        std::printf("caught '%s', %d frames unwound\n", e.what(), unwound);
        return unwound == 6 ? 0 : 1;
    }
    return 1;
}
