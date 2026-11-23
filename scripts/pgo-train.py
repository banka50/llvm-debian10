#!/usr/bin/env python3
"""Deterministic PGO training run for clang.

Replays compile commands from a CMake compilation database (configured with
an ordinary, non-instrumented compiler) using the instrumented clang and
merges the resulting profiles into one .profdata file.

Profile counters must come out identical on every run, otherwise the final
PGO-optimised compiler is not reproducible. Hence:
  * ASLR is disabled for the compiler (`setarch -R`): clang hashes pointers in
    many tables, so the number of probes, and thus branch counts, would
    otherwise depend on where the heap ends up;
  * every compile runs with the same minimal environment;
  * nothing random (like CMake's try_compile directories) is compiled;
  * profiles are merged in job order, in chunks of a fixed size that does
    not depend on the number of parallel jobs (each raw profile is ~60 MB,
    so they cannot all be kept until the end);
  * functions templated on llvm::sys::fs::UniqueID are dropped: clang's
    FileManager keys maps by device + inode, so their counts depend on the
    inode numbers of the source files, which differ on every checkout.
"""

import argparse
import concurrent.futures
import json
import os
import platform
import shlex
import shutil
import subprocess
import sys

# Sources compiled during training, relative to the llvm-project root:
# plain C++ (Support), IR-heavy code (IR) and template-heavy code (Sema).
TRAINING_DIRS = ("llvm/lib/Support/", "llvm/lib/IR/", "clang/lib/Sema/")
# These are additionally compiled as a debug build (-O0 -g).
DEBUG_DIRS = ("llvm/lib/Support/",)
# Compiles per merge step. Fixed, so the result does not depend on --jobs.
CHUNK = 64
# Profile entries whose counts depend on file inode numbers (see above).
NONDETERMINISTIC_FUNCTIONS = "8UniqueID"


def strip_dep_flags(args):
    """Drops -MD/-MF/-MT/-MQ and the output so jobs never write the same file."""
    out, skip = [], False
    for a in args:
        if skip:
            skip = False
            continue
        if a in ("-MF", "-MT", "-MQ", "-o"):
            skip = True
            continue
        if a in ("-MD", "-MMD"):
            continue
        out.append(a)
    return out + ["-o", os.devnull]


def debug_variant(args):
    out = [a for a in args if not (a.startswith("-O") or a == "-DNDEBUG")]
    return out[:1] + ["-O0", "-g"] + out[1:]


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--clang-dir", required=True, help="bin/ of the instrumented build")
    p.add_argument("--compdb", required=True, help="compile_commands.json")
    p.add_argument("--src", required=True, help="llvm-project source root")
    p.add_argument("--profiles", required=True, help="scratch directory for .profraw files")
    p.add_argument("--llvm-profdata", required=True, help="llvm-profdata of the same LLVM version")
    p.add_argument("--output", required=True, help="merged .profdata to write")
    p.add_argument("--jobs", type=int, default=os.cpu_count())
    opts = p.parse_args()

    with open(opts.compdb) as f:
        entries = json.load(f)

    jobs = []
    for e in sorted(entries, key=lambda e: e["file"]):
        rel = os.path.relpath(e["file"], opts.src)
        if not rel.startswith(TRAINING_DIRS) or not rel.endswith((".c", ".cpp")):
            continue
        args = e["arguments"] if "arguments" in e else shlex.split(e["command"])
        driver = "clang++" if os.path.basename(args[0]).endswith("++") else "clang"
        args = strip_dep_flags([os.path.join(opts.clang_dir, driver)] + args[1:])
        jobs.append((e["directory"], args))
        if rel.startswith(DEBUG_DIRS):
            jobs.append((e["directory"], debug_variant(args)))
    if not jobs:
        sys.exit("no training sources found in " + opts.compdb)

    shutil.rmtree(opts.profiles, ignore_errors=True)
    os.makedirs(opts.profiles)
    setarch = ["setarch", platform.machine(), "-R"]
    raw = lambda index: os.path.join(opts.profiles, "%05d.profraw" % index)

    def run(index, job):
        cwd, args = job
        env = {
            "PATH": "/usr/bin:/bin",
            "LC_ALL": "C",
            "LLVM_PROFILE_FILE": raw(index),
        }
        r = subprocess.run(setarch + args, cwd=cwd, env=env,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        return index, r.returncode, r.stdout.decode(errors="replace")

    print("training: %d compiles, %d parallel" % (len(jobs), opts.jobs), flush=True)
    merged = os.path.join(opts.profiles, "merged.profdata")
    with concurrent.futures.ThreadPoolExecutor(opts.jobs) as pool:
        for start in range(0, len(jobs), CHUNK):
            indices = range(start, min(start + CHUNK, len(jobs)))
            failed = 0
            for index, rc, output in pool.map(lambda i: run(i, jobs[i]), indices):
                if rc != 0:
                    failed += 1
                    print("FAILED: %s\n%s" % (shlex.join(jobs[index][1]), output), file=sys.stderr)
            if failed:
                sys.exit("%d training compiles failed" % failed)
            inputs = ([merged] if start else []) + [raw(i) for i in indices]
            subprocess.run([opts.llvm_profdata, "merge", "--num-threads=1",
                            "--no-function=" + NONDETERMINISTIC_FUNCTIONS,
                            "-o", merged + ".new"] + inputs,
                           check=True, stdout=subprocess.DEVNULL)
            os.replace(merged + ".new", merged)
            for i in indices:
                os.remove(raw(i))
            print("  %d/%d" % (indices[-1] + 1, len(jobs)), flush=True)
    os.replace(merged, opts.output)
    shutil.rmtree(opts.profiles)


if __name__ == "__main__":
    main()
