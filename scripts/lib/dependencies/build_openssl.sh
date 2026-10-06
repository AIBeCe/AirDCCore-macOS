#!/bin/sh
set -eu

die() { printf '%s\n' "openssl adapter: $*" >&2; exit 2; }
helper=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)/network_adapter.py
run() { purpose=$1; shift; set +e; python3 "$helper" run "$purpose" "$@"; status=$?; set -e; return "$status"; }
[ "$#" -eq 5 ] || die 'expected SOURCE BUILD STAGE JOBS EPOCH'
source=$1; build=$2; stage=$3; jobs=$4; epoch=$5
for path in "$source" "$build" "$stage"; do
  [ -d "$path" ] && [ ! -L "$path" ] || die "missing or unsafe directory: $path"
  case "$path" in /*) ;; *) die "path must be absolute: $path" ;; esac
done
source=$(CDPATH= cd -- "$source" && pwd -P); build=$(CDPATH= cd -- "$build" && pwd -P); stage=$(CDPATH= cd -- "$stage" && pwd -P)
[ "$source" != "$build" ] && [ "$source" != "$stage" ] && [ "$build" != "$stage" ] || die 'directories must be distinct'
case "$build/" in "$source/"*) die 'build must be outside source' ;; esac
case "$stage/" in "$source/"*|"$build/"*) die 'stage must be outside source and build' ;; esac
case "$jobs" in ''|*[!0-9]*|0) die 'JOBS must be a positive integer' ;; esac
case "$epoch" in ''|*[!0-9]*) die 'EPOCH must be a nonnegative integer' ;; esac
[ "${SOURCE_DATE_EPOCH:-}" = "$epoch" ] || die 'epoch disagrees with build environment'
: "${CC:?CC is required}"
[ -f "$source/Configure" ] && [ -f "$source/LICENSE.txt" ] || die 'missing OpenSSL source input'
cp -R "$source/." "$build/"
(CDPATH= cd -- "$build" && run configure perl "$build/Configure" darwin64-arm64-cc no-shared no-pinshared "--prefix=$stage" "--openssldir=$stage/ssl" "-arch arm64" -mmacosx-version-min=14.0)
# Runtime defaults match the pinned Darwin target; INSTALLTOP/libdir still
# point only at STAGE. Apply the same values to every possible make compile.
set -- OPENSSLDIR=/usr/local/ssl ENGINESDIR=/usr/local/lib/engines-3 MODULESDIR=/usr/local/lib/ossl-modules
run build make -C "$build" "-j$jobs" "$@"
run test make -C "$build" "-j$jobs" "$@" test
run install make -C "$build" install_dev "$@"
cp "$source/LICENSE.txt" "$stage/LICENSE.txt"
python3 "$helper" relocate-pc "$stage/lib/pkgconfig/openssl.pc" "$stage/lib/pkgconfig/libssl.pc" "$stage/lib/pkgconfig/libcrypto.pc"
# install_dev's complete static development metadata is retained.
for relative in include/openssl/ssl.h include/openssl/crypto.h lib/libssl.a lib/libcrypto.a \
    lib/pkgconfig/openssl.pc lib/pkgconfig/libssl.pc lib/pkgconfig/libcrypto.pc \
    lib/cmake/OpenSSL/OpenSSLConfig.cmake lib/cmake/OpenSSL/OpenSSLConfigVersion.cmake LICENSE.txt; do
  [ -f "$stage/$relative" ] && [ ! -L "$stage/$relative" ] || die "missing installed output: $relative"
done
cat > "$build/openssl-consumer.c" <<'C'
#include <openssl/evp.h>
#include <openssl/ssl.h>
int main(void) {
    unsigned char out[EVP_MAX_MD_SIZE]; unsigned int length = 0;
    SSL_CTX *ctx;
    if (OPENSSL_init_ssl(0, NULL) != 1) return 1;
    ctx = SSL_CTX_new(TLS_method()); if (ctx == NULL) return 2; SSL_CTX_free(ctx);
    if (EVP_Digest("AirDCCore", 9, out, &length, EVP_sha256(), NULL) != 1) return 3;
    return length == 32 ? 0 : 4;
}
C
run consumer-compile "$CC" -arch arm64 -mmacosx-version-min=14.0 "-I$stage/include" "$build/openssl-consumer.c" "$stage/lib/libssl.a" "$stage/lib/libcrypto.a" -o "$build/openssl-consumer"
run consumer-run "$build/openssl-consumer"
