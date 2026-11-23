// Exercises recent libc++ features (not available in Debian 10's libstdc++).
#include <algorithm>
#include <expected>
#include <format>
#include <print>
#include <ranges>
#include <string>
#include <string_view>
#include <vector>

static std::expected<int, std::string> parse(std::string_view s) {
    int v = 0;
    for (char c : s) {
        if (c < '0' || c > '9')
            return std::unexpected(std::format("bad digit '{}'", c));
        v = v * 10 + (c - '0');
    }
    return v;
}

int main() {
    std::vector<int> v{5, 3, 1, 4, 2};
    std::ranges::sort(v);
    auto squares = v | std::views::transform([](int x) { return x * x; });
    std::println("squares: {}", squares);
    auto bad = parse("12x");
    if (bad || bad.error() != "bad digit 'x'")
        return 1;
    std::println("parsed: {}", *parse("42"));
    return 0;
}
