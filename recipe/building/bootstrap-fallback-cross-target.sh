#!/usr/bin/env bash
# bootstrap-fallback-cross-target.sh
#
# PURPOSE: Enable first-time builds of cross-target OCaml on new arches (e.g. s390x, riscv64)
# where no pre-published ocaml_<arch> package exists yet in any channel.
#
# LIFECYCLE: This file exists only until an `ocaml_<arch>` package is published to a channel
# and the recipe-level build dependency is restored. Once that dep is active, the
# `$CROSS_COMPILER_DIR/lib/ocaml/stdlib.cma` check in build.sh will pass immediately and
# this function will never be called. At that point this script is dead code and can be
# removed entirely.
#
# USAGE: Designed to be sourced by build.sh immediately before the hard-fail stdlib.cma check.
# Can also be run standalone for testing: bash recipe/building/bootstrap-fallback-cross-target.sh
#
# IMPLEMENTATION NOTE: Uses a staging dir (`_xcross_compiler_fallback/`) to avoid the
# self-referential cp error that occurs when OCAML_INSTALL_PREFIX=BUILD_PREFIX directly.
# build_cross_compiler() step 7/7 copies wrappers from OCAML_INSTALL_PREFIX/bin/ into
# BUILD_PREFIX/bin/ -- if they are the same directory, cp fails with "same file" error.
# This mirrors the pattern used by the native cross-compiler mode at build.sh:5988-6085:
# build into a staging dir first, then tar-transfer into the final destination.

bootstrap_cross_target_from_inline() {
    echo ""
    echo "[bootstrap-fallback] first-build path for ${target_platform:-<unknown target_platform>}"
    echo "[bootstrap-fallback] CROSS_COMPILER_DIR=${CROSS_COMPILER_DIR:-<unset>}"
    echo "[bootstrap-fallback] CROSS_TARGET=${CROSS_TARGET:-<unset>}"

    # If the expected stdlib.cma already exists, nothing to do.
    if [[ -f "${CROSS_COMPILER_DIR}/lib/ocaml/stdlib.cma" ]]; then
        echo "[bootstrap-fallback] stdlib.cma already present - no-op, returning."
        return 0
    fi

    # Ensure build_cross_compiler() is available (it is defined in build.sh, which sources
    # this file, so it should already be in scope; guard with type check for safety).
    if ! declare -f build_cross_compiler > /dev/null 2>&1; then
        echo "[bootstrap-fallback] ERROR: build_cross_compiler() not defined in scope."
        echo "[bootstrap-fallback] This script must be sourced from build.sh after build_cross_compiler() is defined."
        return 1
    fi

    # CONDA_TOOLCHAIN_BUILD must be set (it identifies the native build-host triplet,
    # e.g. x86_64-conda-linux-gnu on linux-64 build machines).
    if [[ -z "${CONDA_TOOLCHAIN_BUILD:-}" ]]; then
        echo "[bootstrap-fallback] ERROR: CONDA_TOOLCHAIN_BUILD not set."
        echo "[bootstrap-fallback] Cannot call setup_toolchain for native build-host compiler."
        return 1
    fi

    # Staging dir - distinct from the cross-compiler mode's _xcross_compiler/ dir so both
    # can coexist in the unlikely event both paths run in the same build.
    local _staging_dir="${SRC_DIR}/_xcross_compiler_fallback"
    mkdir -p "${_staging_dir}"

    echo ""
    echo "[bootstrap-fallback] Invoking build_cross_compiler() to populate ${CROSS_COMPILER_DIR} ..."
    echo "[bootstrap-fallback] (this may take several minutes -- bootstrapping a fresh cross-compiler for first-build)"
    echo "[bootstrap-fallback] build_platform=${build_platform:-${target_platform}}"
    echo "[bootstrap-fallback] CONDA_TOOLCHAIN_BUILD=${CONDA_TOOLCHAIN_BUILD}"
    echo "[bootstrap-fallback] staging dir: ${_staging_dir}"

    # Run build_cross_compiler() in a subshell so env exports do not leak.
    # Mirror the setup from the cross-compiler block in build.sh (lines 5988-6008):
    #   1. setup_toolchain "NATIVE" to populate NATIVE_CC, NATIVE_AR, etc.
    #   2. setup_cflags_ldflags "NATIVE" for the build-host's flags.
    #   3. OCAML_PREFIX = BUILD_PREFIX (native OCaml tools installed there).
    #   4. OCAMLLIB  = BUILD_PREFIX/lib/ocaml (native stdlib).
    #   5. OCAML_INSTALL_PREFIX = _staging_dir (NOT BUILD_PREFIX) so build_cross_compiler()
    #      writes wrappers into staging/bin/, avoiding the self-referential cp error.
    # The subshell must cd to $SRC_DIR because configure/make operate on the OCaml source tree.
    (
        set -euo pipefail

        cd "${SRC_DIR}"

        # Setup native (build-host) toolchain variables.
        setup_toolchain "NATIVE" "${CONDA_TOOLCHAIN_BUILD}"
        if is_unix; then
            setup_cflags_ldflags "NATIVE" "${build_platform:-${target_platform}}" "${target_platform}"
        else
            export NATIVE_CFLAGS="${NATIVE_CFLAGS:-}"
            export NATIVE_LDFLAGS="${NATIVE_LDFLAGS:-}"
        fi

        export OCAML_PREFIX="${BUILD_PREFIX}"
        export OCAMLLIB="${OCAML_PREFIX}/lib/ocaml"
        # Write into staging dir, NOT BUILD_PREFIX, to avoid self-referential cp in step 7/7.
        export OCAML_INSTALL_PREFIX="${_staging_dir}"

        build_cross_compiler
    )
    local _rc=$?

    if [[ ${_rc} -ne 0 ]]; then
        echo "[bootstrap-fallback] build_cross_compiler() exited with status ${_rc}."
        echo "[bootstrap-fallback] Leaving CROSS_COMPILER_DIR empty; existing hard-fail check will report the error."
        return 0
    fi

    # Transfer staged output into BUILD_PREFIX so the cross-target block downstream
    # finds the cross-compiler at CROSS_COMPILER_DIR (= BUILD_PREFIX/lib/ocaml-cross-compilers/CROSS_TARGET).
    echo "[bootstrap-fallback] Transferring staged cross-compiler from ${_staging_dir} into BUILD_PREFIX ..."

    # Transfer the cross-compiler tree.
    if [[ -d "${_staging_dir}/lib/ocaml-cross-compilers" ]]; then
        mkdir -p "${BUILD_PREFIX}/lib"
        cp -a "${_staging_dir}/lib/ocaml-cross-compilers/." "${BUILD_PREFIX}/lib/ocaml-cross-compilers/"
    fi

    # Transfer ONLY the target-prefixed toolchain wrappers (e.g. s390x-conda-linux-gnu-ocaml-*).
    # Do NOT copy unprefixed binaries that would shadow build-host binaries already in BUILD_PREFIX/bin/.
    if [[ -d "${_staging_dir}/bin" ]]; then
        mkdir -p "${BUILD_PREFIX}/bin"
        find "${_staging_dir}/bin" -maxdepth 1 -type f -name "${CROSS_TARGET}-*" \
            -exec cp -a {} "${BUILD_PREFIX}/bin/" \;
        find "${_staging_dir}/bin" -maxdepth 1 -type l -name "${CROSS_TARGET}-*" \
            -exec cp -a {} "${BUILD_PREFIX}/bin/" \;
    fi

    # Re-check after transfer.
    if [[ -f "${CROSS_COMPILER_DIR}/lib/ocaml/stdlib.cma" ]]; then
        echo "[bootstrap-fallback] SUCCESS: stdlib.cma now present at ${CROSS_COMPILER_DIR}/lib/ocaml/stdlib.cma"
    else
        echo "[bootstrap-fallback] FAILURE: stdlib.cma still missing after build_cross_compiler() and transfer."
        echo "[bootstrap-fallback] The existing hard-fail check will report the definitive error."
    fi

    return 0
}

# Allow standalone execution for manual testing.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "[bootstrap-fallback] Running standalone (not sourced)."
    echo "[bootstrap-fallback] Set CROSS_COMPILER_DIR, CROSS_TARGET, SRC_DIR, target_platform,"
    echo "[bootstrap-fallback] CONDA_TOOLCHAIN_BUILD, BUILD_PREFIX before calling."
    bootstrap_cross_target_from_inline
fi
