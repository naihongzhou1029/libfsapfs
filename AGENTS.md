# libfsapfs - AGENTS.md

**Project**: C library to access Apple File System (APFS), version 2 (read-only). Status: experimental. License: LGPL-3.0-or-later.

## Build System
### Unix (Autotools)
Standard workflow:
```sh
./configure [options]    # Run from repo root after autoreconf -fi if needed
make                     # Builds all subdirectories
make check               # Run full test suite (requires build first)
```

### Windows (PowerShell)
Use `devops.ps1` to manage the toolchain environment and build tasks:
```powershell
.\devops.ps1 env        # Pre-flight check and build local dependencies (zlib, dokan)
.\devops.ps1 build      # Build release artifacts into build/
.\devops.ps1 rebuild    # Clean and rebuild the project
.\devops.ps1 probe      # List disks/partitions and detect APFS container candidates
.\devops.ps1 mount -PhysicalDrive 1 -Offset 135266304 -MountPoint X:   # Mount via fsapfsmount.exe (Dokan)
.\devops.ps1 unmount -MountPoint X:                                    # Unmount via dokanctl.exe
.\devops.ps1 gui                                                      # Mount/unmount from a window instead
```
Available options for `devops.ps1`:
- `-Configuration <Release|Debug>` (default: Release)
- `-Platform <x64|Win32|ARM64>` (default: x64)
- `-VisualStudioVersion <2019|2022>` (default: auto-detected)
- `-BuildDir <path>` (default: build)

`probe`/`mount`/`unmount` are read-only-mount helpers built on top of `fsapfsmount.exe` and `dokanctl.exe`:
- `probe` lists disks via `Get-Disk`/`Get-Partition` and flags GPT partitions whose type GUID is `7c3457ef-0000-11aa-aa11-00306543ecac` (Apple APFS) as mount candidates, printing the ready-to-use `mount` command for each (and, if `fsapfsinfo.exe` is built and the session is elevated, the container/volume identifiers).
- `mount` requires an elevated (Administrator) session and the Dokan kernel driver installed (see below); it launches `fsapfsmount.exe` detached (it blocks in `DokanMain()` for the life of the mount and never daemonizes on Windows) and logs stdout/stderr under `build\mount-logs\`.
- `unmount` requires an elevated session and shells out to `dokanctl.exe /u` (auto-located under `Program Files\Dokan\*\dokanctl.exe`).
- `gui` opens a small fixed-size window (mountable disks on top, mounted/unmountable disks below, each with its own Mount/UnMount button) built on `Get-MountableApfsDisks`/`Get-FsApfsMountInstances`, for picking a disk instead of typing `-PhysicalDrive`/`-Offset`/`-MountPoint`. `mount-gui.bat` (repo root, next to `devops.ps1`) is a double-click launcher for it that auto-elevates via UAC (checks `net session`, then relaunches itself elevated if needed) so a non-technical user never has to open PowerShell manually; it resolves `devops.ps1` relative to its own folder (`%~dp0`), so the two files must stay side by side.

**Key configure options** (see `configure.ac`):
- `--enable-python` / `--disable-python` - Python bindings (pyfsapfs)
- `--enable-fuse` / `--disable-fuse` - FUSE mount tool (fsapfsmount)
- `--enable-static-executables` - Build tools as static binaries
- `--enable-debug-output` / `--enable-verbose-output` - Debug/verbose logging
- `--enable-asan` / `--enable-ubsan` - Sanitizers
- `--enable-code-coverage` - Coverage instrumentation
- Many `AX_*` macros for optional dependencies (zlib, libhmac, libcaes, etc.)

## Repository Structure
```
├── libfsapfs/           # Main library (~50 C source files)
├── pyfsapfs/            # Python C extension (pyfsapfs.so)
├── fsapfstools/         # CLI tools: fsapfsinfo, fsapfsmount
├── tests/               # Autotest suite (.at) + Python unittests
├── include/             # Public headers (generated from .in templates)
├── common/              # Shared config.h, types.h
├── libcerror/           # Error handling library
├── libcthreads/         # Threading library
├── libcdata/            # Data handling library
├── libclocale/          # Locale library
├── libcnotify/          # Notification library
├── libcsplit/           # String splitting library
├── libuna/              # Unicode normalization
├── libcfile/            # File I/O abstraction
├── libcpath/            # Path handling
├── libbfio/             # Buffered I/O
├── libfcache/           # File cache
├── libfdata/            # Data structures
├── libfdatetime/        # Date/time handling
├── libfguid/            # GUID handling
├── libfmos/             # Memory-mapped I/O
├── libhmac/             # HMAC (MD5, SHA256)
├── libcaes/             # AES encryption (ECB, XTS)
├── pyproject.toml.in    # Python package template (generates pyproject.toml)
├── configure.ac         # Autoconf configuration
├── Makefile.am          # Top-level automake (SUBDIRS order matters)
└── tox.ini              # Python test matrix (py310-py314)
```

**Dependency order in Makefile.am matters** - libraries must be listed before dependents (e.g., `common` before `libcerror` before `libfsapfs`).

## Testing
### C Tests (Autotest)
```sh
# From repo root:
make check-build         # Build test binaries only
make check               # Run all test suites (library, tools, manpages, python)

# Or from tests/:
make check-build
make check

# Run single test suite:
./tests/test_library       # Library unit tests
./tests/test_tools         # CLI tool integration tests
./tests/test_manpages      # Manpage syntax checks
```

Test infrastructure:
- `.at` files in `tests/` define test cases via m4/Autotest
- `generate_test_inputs.sh` auto-generates `test_inputs_*.at` from `tests/input/` test data
- Test data in `tests/input/` organized by test profile (e.g., `fsapfsinfo`, `pyfsapfs`)
- Run `./tests/runtests.sh` for full suite with macOS dylib fix

### Python Tests
```sh
# Via tox (recommended - handles build isolation):
tox                      # Tests py310-py314

# Direct (requires built lib + pyfsapfs.so):
python tests/runtests.py
```

Python test discovery: `tests/runtests.py` uses `unittest` to discover `tests/*.py` (currently `pyfsapfs_test_*.py`).

## Python Packaging
- `pyproject.toml.in` → `pyproject.toml` (generated by configure)
- Custom `setuptools` build in `_build.py` (`custom_build_ext`, `custom_sdist`)
- Extension module: `pyfsapfs` (C sources in `pyfsapfs/`)
- Build: `python -m build --no-isolation --wheel` (as in `tox.ini`)
- Install: `pip install --find-links=dist libfsapfs-python`

## Common Tasks
| Task | Command |
|------|---------|
| Configure with Python bindings | `./configure --enable-python` (Unix) or `.\devops.ps1 env` (Windows) |
| Build everything | `make` (Unix) or `.\devops.ps1 build` (Windows) |
| Run all tests | `make check` (Unix) or `.\runtests.ps1` (Windows) |
| Run Python tests only | `tox` or `python tests/runtests.py` |
| Build Python wheel | `python -m build --wheel --no-isolation` |
| Clean build artifacts | `make clean` (Unix) or `.\devops.ps1 clean` (Windows) |
| Regenerate configure | `autoreconf -fi` |

## Platform Notes
- Windows: Uses `msvscpp/` for Visual Studio project; `LT_INIT([win32-dll])` in configure.ac enables DLL support. The build can be fully driven on Windows via `devops.ps1`. If MSBuild is present but C++ workload, compiler tools, or Windows 10 SDK (10.0.19041.0) is missing, run `.\devops.ps1 env -InstallVisualStudio` to automatically modify or install the required components.
- macOS: `runtests.sh` fixes `install_name_tool` for dylib paths.
- Linux: Standard autotools; pkg-config via `libfsapfs.pc`.
- Test inputs in `tests/input/` are not in git (see `.gitignore`) - must be generated/downloaded separately.
- Dokan Driver Requirement: To build and run `fsapfsmount.exe` successfully, `.\devops.ps1 env` will sync and build a compatible version of Dokany (`v1.5.1.1000` to match `dokan1.lib` naming conventions). However, the Dokan kernel driver (e.g., `Dokan_x64.msi`) must be manually installed from https://github.com/dokan-dev/dokany/releases using the matching version, as kernel driver installation requires administrator privileges.

## Key Files to Know
- `configure.ac` - All feature flags, dependency checks, version (20260626)
- `Makefile.am` - SUBDIRS build order, pkgconfig, spec/dpkg files
- `tests/Makefile.am` - 100+ test programs, Autotest suites, Python test integration
- `tests/runtests.py` - Python test runner with profile/option handling
- `pyproject.toml.in` - Python package metadata template
- `README` - Supported/unsupported APFS features list

## Gotchas
- Generated files: `configure`, `Makefile.in`, `include/*.h`, `libfsapfs.pc`, `libfsapfs.spec`, `pyproject.toml`, `common/config.h` are all generated - don't edit directly.
- Test dependencies: `make check-build` must succeed before `make check`.
- Test data: `tests/input/` ignored by git; tests skip if missing (`SKIP_TOOLS_TESTS` env).
- Subdirectory dependencies: Link order in `tests/Makefile.am` `*_LDADD` must match dependency graph.
- Python module: Requires built `libfsapfs.la` and `pyfsapfs.la` in `.libs/`.
- Windows fsapfsmount.exe dependency: The tool requires `dokan1.dll` in the same directory (which `devops.ps1 build` copies automatically), and the matching Dokan kernel driver must be installed on the host system to mount APFS volumes.
- Windows Build Workload/SDK Issues: If building Dokan fails due to a missing Windows 10 SDK (10.0.19041.0) or `CL.exe` missing errors, run `.\devops.ps1 env -InstallVisualStudio`. The script will detect the existing MSBuild installation and launch Visual Studio Installer to add the C++ workload (`Microsoft.VisualStudio.Workload.VCTools`), compiler toolchain (`Microsoft.VisualStudio.Component.VC.Tools.x86.x64`), and Windows 10 SDK (`Microsoft.VisualStudio.Component.Windows10SDK.19041`).