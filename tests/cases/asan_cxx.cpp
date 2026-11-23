#include <vector>

int main() {
    std::vector<int> v(10, 1);
    int *p = v.data();
    v.clear();
    v.shrink_to_fit();
    return p[0]; // heap-use-after-free
}
