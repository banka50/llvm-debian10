#include <cstdio>

struct A {
    virtual void f() { std::puts("A::f"); }
    virtual ~A() = default;
};
struct B {
    virtual void g() { std::puts("B::g"); }
    virtual ~B() = default;
};

int main() {
    A a;
    B *b = reinterpret_cast<B *>(&a);
    b->g(); // bad cast: CFI must stop this virtual call
    return 0;
}
