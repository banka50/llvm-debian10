#include <thread>

static int counter;

int main() {
    auto work = [] {
        for (int i = 0; i < 100000; i++)
            counter++; // data race
    };
    std::thread a(work), b(work);
    a.join();
    b.join();
    return 0;
}
