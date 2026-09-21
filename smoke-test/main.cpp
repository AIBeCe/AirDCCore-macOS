#include <airdcpp/stdinc.h>
#include <airdcpp/core/version.h>

#include <iostream>
#include <string>

int main() {
    const std::string version = dcpp::getVersionTag();
    if (version.empty()) {
        std::cerr << "AirDC++ Core version is empty\n";
        return 1;
    }

    std::cout << "AirDC++ Core " << version << '\n';
    return 0;
}
