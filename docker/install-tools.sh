#!/bin/sh
# Installs pinned build tools into the builder image. Runs during `docker build`.
# Inputs (from Dockerfile ARGs): ARCH CMAKE_VERSION NINJA_VERSION ZSTD_VERSION
#                                PYTHON_VERSION BUILD_PYTHON
set -eux

D=/tmp/deps
T=/opt/tools
JOBS=$(nproc)
mkdir -p "$T/bin"

# --- CMake: official Kitware binary release ---------------------------------
mkdir -p "$T/cmake"
tar -C "$T/cmake" --strip-components=1 -xzf "$D/cmake-$CMAKE_VERSION-linux-$ARCH.tar.gz"
for t in cmake ctest cpack; do ln -s "../cmake/bin/$t" "$T/bin/$t"; done

# --- Ninja: built from source (upstream binaries need a newer glibc) ---------
tar -C /tmp -xzf "$D/ninja-$NINJA_VERSION.tar.gz"
cmake -S "/tmp/ninja-$NINJA_VERSION" -B /tmp/ninja-build \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF
cmake --build /tmp/ninja-build -j"$JOBS"
install -m 755 /tmp/ninja-build/ninja "$T/bin/ninja"
rm -rf "/tmp/ninja-$NINJA_VERSION" /tmp/ninja-build

# --- zstd: static PIC library (Debian 10 ships 1.3.8, LLVM needs >= 1.4) -----
# Installed into /usr/local so LLVM's Findzstd picks it up; only the static
# library is installed, so the toolchain does not depend on libzstd.so.
tar -C /tmp -xzf "$D/zstd-$ZSTD_VERSION.tar.gz"
make -C "/tmp/zstd-$ZSTD_VERSION/lib" -j"$JOBS" libzstd.a CFLAGS="-O2 -fPIC"
install -m 644 "/tmp/zstd-$ZSTD_VERSION/lib/libzstd.a" /usr/local/lib/
install -m 644 "/tmp/zstd-$ZSTD_VERSION/lib/zstd.h" \
               "/tmp/zstd-$ZSTD_VERSION/lib/zdict.h" \
               "/tmp/zstd-$ZSTD_VERSION/lib/zstd_errors.h" /usr/local/include/
rm -rf "/tmp/zstd-$ZSTD_VERSION"

# --- Python: only where the system python3 is too old -----------------------
if [ "$BUILD_PYTHON" = 1 ]; then
    tar -C /tmp -xJf "$D/Python-$PYTHON_VERSION.tar.xz"
    cd "/tmp/Python-$PYTHON_VERSION"
    ./configure --prefix="$T/python" --without-ensurepip --disable-test-modules
    make -j"$JOBS"
    make install
    cd /
    ln -s ../python/bin/python3 "$T/bin/python3"
    rm -rf "/tmp/Python-$PYTHON_VERSION"
fi

# --- Record what is in the image (copied into BUILD-INFO of every build) ----
{
    echo "cc:      $(gcc --version | head -n1)"
    echo "c++:     $(g++ --version | head -n1)"
    echo "ld:      $(ld --version | head -n1)"
    echo "libc:    $(ldd --version | head -n1)"
    echo "cmake:   $(cmake --version | head -n1)"
    echo "ninja:   $(ninja --version)"
    echo "python:  $(python3 --version) ($(command -v python3))"
    echo "zstd:    $ZSTD_VERSION (static, /usr/local/lib/libzstd.a)"
} > "$T/TOOLS.txt"
dpkg-query -W -f '${Package} ${Version} ${Architecture}\n' | sort > "$T/PACKAGES.txt"
cat "$T/TOOLS.txt"
