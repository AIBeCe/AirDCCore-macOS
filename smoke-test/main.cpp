#include <airdcpp/stdinc.h>
#include <airdcpp/core/version.h>

#include <iostream>
#include <string>

int main() {
    std::string identity = dcpp::getVersionTag();
    if (identity.empty()) {
        identity = dcpp::getGitCommit();
    }
    if (identity.empty()) {
        std::cerr << "AirDC++ Core identity is empty\n";
        return 1;
    }

    std::cout << "AirDC++ Core " << identity << '\n';
    return 0;
}
