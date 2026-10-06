#include <airdcpp/stdinc.h>
#include <airdcpp/core/version.h>

#include <iostream>
#include <string>

#ifndef AIRDCCORE_EXPECTED_VERSION_TAG
#error Validated Core version tag is required
#endif
#ifndef AIRDCCORE_EXPECTED_GIT_COMMIT
#error Validated Core commit is required
#endif

int main() {
    const std::string tag = dcpp::getVersionTag();
    const std::string commit = dcpp::getGitCommit();
    if (tag != AIRDCCORE_EXPECTED_VERSION_TAG) {
        std::cerr << "AirDC++ Core version tag differs from validated authority\n";
        return 1;
    }
    if (commit != AIRDCCORE_EXPECTED_GIT_COMMIT) {
        std::cerr << "AirDC++ Core commit differs from validated authority\n";
        return 1;
    }
    std::cout << "AirDC++ Core " << commit << '\n';
    return 0;
}
