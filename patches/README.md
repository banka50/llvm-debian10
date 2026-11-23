# Patches

Patches in `patches/<llvm major version>/*.patch` are applied in name order
(`patch -p1`, from the root of the llvm-project source tree) right after the
source tarball is extracted. They are part of the build inputs: their
checksums are recorded in `BUILD-INFO.txt`, and changing any of them
triggers a clean rebuild.

None are needed for LLVM 23 on the supported Debian releases.
