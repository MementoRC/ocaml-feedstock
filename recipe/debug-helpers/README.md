# Saved debugging helpers (local branch, not for upstream)

## run-with-timeout-cdb.ps1

Byte-exact copy of `recipe/testing/run-with-timeout.ps1`.

Runs a command with a wall-clock timeout on Windows CI. On timeout, logs thread state and process stacks via cdb (Windows debugger from SDK Debugging Tools), then kills the process tree and exits 124.

**Original**: `recipe/testing/run-with-timeout.ps1`
**Used by**: `recipe/testing/test-compilation.bat` (line 133: `powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-with-timeout.ps1"`)

**To re-enable**: Copy this file back over `recipe/testing/run-with-timeout.ps1`. cdb comes from Windows Kits SDK Debugging Tools, pre-installed on conda-forge CI images.

