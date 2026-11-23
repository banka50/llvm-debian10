#include <iostream>
#include <map>
#include <string>
#include <vector>

int main() {
    std::map<std::string, std::vector<int>> m{{"a", {1, 2}}, {"b", {3}}};
    int sum = 0;
    for (const auto &[k, v] : m)
        for (int x : v)
            sum += x;
    std::cout << "sum=" << sum << '\n';
    return sum == 6 ? 0 : 1;
}
