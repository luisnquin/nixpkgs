{ lib, stdenv, targetPackages, fetchurl, fetchpatch, noSysDirs
, langC ? true, langCC ? true, langFortran ? false
, langObjC ? stdenv.targetPlatform.isDarwin
, langObjCpp ? stdenv.targetPlatform.isDarwin
, langGo ? false
, profiledCompiler ? false
, langJit ? false
, staticCompiler ? false
, # N.B. the defult is intentionally not from an `isStatic`. See
  # https://gcc.gnu.org/install/configure.html - this is about target
  # platform libraries not host platform ones unlike normal. But since
  # we can't rebuild those without also rebuilding the compiler itself,
  # we opt to always build everything unlike our usual policy.
  enableShared ? true
, enableLTO ? true
, texinfo ? null
, perl ? null # optional, for texi2pod (then pod2man)
, gmp, mpfr, libmpc, gettext, which, patchelf
, libelf                      # optional, for link-time optimizations (LTO)
, isl ? null # optional, for the Graphite optimization framework.
, zlib ? null
, enableMultilib ? false
, enablePlugin ? stdenv.hostPlatform == stdenv.buildPlatform # Whether to support user-supplied plug-ins
, name ? "gcc"
, libcCross ? null
, threadsCross ? null # for MinGW
, crossStageStatic ? false
, # Strip kills static libs of other archs (hence no cross)
  stripped ? stdenv.hostPlatform.system == stdenv.buildPlatform.system
          && stdenv.targetPlatform.system == stdenv.hostPlatform.system
, gnused ? null
, cloog # unused; just for compat with gcc4, as we override the parameter on some places
, buildPackages
}:

# LTO needs libelf and zlib.
assert libelf != null -> zlib != null;

# Make sure we get GNU sed.
assert stdenv.hostPlatform.isDarwin -> gnused != null;

# The go frontend is written in c++
assert langGo -> langCC;

# threadsCross is just for MinGW
assert threadsCross != null -> stdenv.targetPlatform.isWindows;

with lib;
with builtins;

let majorVersion = "7";
    version = "${majorVersion}.5.0";

    inherit (stdenv) buildPlatform hostPlatform targetPlatform;

    patches =
      [ # https://gcc.gnu.org/ml/gcc-patches/2018-02/msg00633.html
        ./riscv-pthread-reentrant.patch
        # https://gcc.gnu.org/ml/gcc-patches/2018-03/msg00297.html
        ./riscv-no-relax.patch

        ./0001-Fix-build-for-glibc-2.31.patch
      ]
      ++ optional (targetPlatform != hostPlatform) ../libstdc++-target.patch
      ++ optionals targetPlatform.isNetBSD [
        ../libstdc++-netbsd-ctypes.patch
      ]
      ++ optional noSysDirs ../no-sys-dirs.patch
      ++ optional (hostPlatform != buildPlatform) (fetchpatch { # XXX: Refine when this should be applied
        url = "https://git.busybox.net/buildroot/plain/package/gcc/7.1.0/0900-remove-selftests.patch?id=11271540bfe6adafbc133caf6b5b902a816f5f02";
        sha256 = "0mrvxsdwip2p3l17dscpc1x8vhdsciqw1z5q9i6p5g9yg1cqnmgs";
      })
      ++ optional langFortran ../gfortran-driving.patch
      ++ optional (targetPlatform.libc == "musl" && targetPlatform.isPower) ../ppc-musl.patch
      ++ optional (targetPlatform.libc == "musl" && targetPlatform.isx86_32) (fetchpatch {
        url = "https://git.alpinelinux.org/aports/plain/main/gcc/gcc-6.1-musl-libssp.patch?id=5e4b96e23871ee28ef593b439f8c07ca7c7eb5bb";
        sha256 = "1jf1ciz4gr49lwyh8knfhw6l5gvfkwzjy90m7qiwkcbsf4a3fqn2";
      })
      ++ optional (targetPlatform.libc == "musl") ../libgomp-dont-force-initial-exec.patch

      # Obtain latest patch with ../update-mcfgthread-patches.sh
      ++ optional (!crossStageStatic && targetPlatform.isMinGW) ./Added-mcf-thread-model-support-from-mcfgthread.patch;

    /* Cross-gcc settings (build == host != target) */
    crossMingw = targetPlatform != hostPlatform && targetPlatform.libc == "msvcrt";
    stageNameAddon = if crossStageStatic then "stage-static" else "stage-final";
    crossNameAddon = optionalString (targetPlatform != hostPlatform) "${targetPlatform.config}-${stageNameAddon}-";

in

stdenv.mkDerivation ({
  pname = "${crossNameAddon}${name}${if stripped then "" else "-debug"}";
  inherit version;

  builder = ../builder.sh;

  src = fetchurl {
    url = "mirror://gcc/releases/gcc-${version}/gcc-${version}.tar.xz";
    sha256 = "0qg6kqc5l72hpnj4vr6l0p69qav0rh4anlkk3y55540zy3klc6dq";
  };

  inherit patches;

  outputs = [ "out" "man" "info" ] ++ lib.optional (!langJit) "lib";
  setOutputFlags = false;

  libc_dev = stdenv.cc.libc_dev;

  hardeningDisable = [ "format" "pie" ];

  # This should kill all the stdinc frameworks that gcc and friends like to
  # insert into default search paths.
  prePatch = lib.optionalString hostPlatform.isDarwin ''
    substituteInPlace gcc/config/darwin-c.c \
      --replace 'if (stdinc)' 'if (0)'

    substituteInPlace libgcc/config/t-slibgcc-darwin \
      --replace "-install_name @shlib_slibdir@/\$(SHLIB_INSTALL_NAME)" "-install_name ''${!outputLib}/lib/\$(SHLIB_INSTALL_NAME)"

    substituteInPlace libgfortran/configure \
      --replace "-install_name \\\$rpath/\\\$soname" "-install_name ''${!outputLib}/lib/\\\$soname"
  '';

  postPatch = ''
    configureScripts=$(find . -name configure)
    for configureScript in $configureScripts; do
      patchShebangs $configureScript
    done
  '' + (
    if targetPlatform != hostPlatform || stdenv.cc.libc != null then
      # On NixOS, use the right path to the dynamic linker instead of
      # `/lib/ld*.so'.
      let
        libc = if libcCross != null then libcCross else stdenv.cc.libc;
      in
        (
        '' echo "fixing the \`GLIBC_DYNAMIC_LINKER', \`UCLIBC_DYNAMIC_LINKER', and \`MUSL_DYNAMIC_LINKER' macros..."
           for header in "gcc/config/"*-gnu.h "gcc/config/"*"/"*.h
           do
             grep -q _DYNAMIC_LINKER "$header" || continue
             echo "  fixing \`$header'..."
             sed -i "$header" \
                 -e 's|define[[:blank:]]*\([UCG]\+\)LIBC_DYNAMIC_LINKER\([0-9]*\)[[:blank:]]"\([^\"]\+\)"$|define \1LIBC_DYNAMIC_LINKER\2 "${libc.out}\3"|g' \
                 -e 's|define[[:blank:]]*MUSL_DYNAMIC_LINKER\([0-9]*\)[[:blank:]]"\([^\"]\+\)"$|define MUSL_DYNAMIC_LINKER\1 "${libc.out}\2"|g'
           done
        ''
        + lib.optionalString (targetPlatform.libc == "musl")
        ''
            sed -i gcc/config/linux.h -e '1i#undef LOCAL_INCLUDE_DIR'
        ''
        )
    else "")
      + lib.optionalString targetPlatform.isAvr ''
        makeFlagsArray+=(
           'LIMITS_H_TEST=false'
        )
      '';

  inherit noSysDirs staticCompiler crossStageStatic
    libcCross crossMingw;

  depsBuildBuild = [ buildPackages.stdenv.cc ];
  nativeBuildInputs = [ texinfo which gettext ]
    ++ (optional (perl != null) perl);

  # For building runtime libs
  depsBuildTarget =
    (
      if hostPlatform == buildPlatform then [
        targetPackages.stdenv.cc.bintools # newly-built gcc will be used
      ] else assert targetPlatform == hostPlatform; [ # build != host == target
        stdenv.cc
      ]
    )
    ++ optional targetPlatform.isLinux patchelf;

  buildInputs = [
    gmp mpfr libmpc libelf
    targetPackages.stdenv.cc.bintools # For linking code at run-time
  ] ++ (optional (isl != null) isl)
    ++ (optional (zlib != null) zlib)
    # The builder relies on GNU sed (for instance, Darwin's `sed' fails with
    # "-i may not be used with stdin"), and `stdenvNative' doesn't provide it.
    ++ (optional hostPlatform.isDarwin gnused)
    ;

  depsTargetTarget = optional (!crossStageStatic && threadsCross != null) threadsCross;

  preConfigure = import ../common/pre-configure.nix {
    inherit lib;
    inherit version hostPlatform langGo;
  };

  dontDisableStatic = true;

  # TODO(@Ericson2314): Always pass "--target" and always prefix.
  configurePlatforms = [ "build" "host" ] ++ lib.optional (targetPlatform != hostPlatform) "target";

  configureFlags = import ../common/configure-flags.nix {
    inherit
      lib
      stdenv
      targetPackages
      crossStageStatic libcCross
      version

      gmp mpfr libmpc libelf isl

      enableLTO
      enableMultilib
      enablePlugin
      enableShared

      langC
      langCC
      langFortran
      langGo
      langObjC
      langObjCpp
      langJit
      ;
  } ++ optional (targetPlatform.isAarch64) "--enable-fix-cortex-a53-843419"
    ++ optional targetPlatform.isNetBSD "--disable-libcilkrts"
  ;

  targetConfig = if targetPlatform != hostPlatform then targetPlatform.config else null;

  buildFlags = optional
    (targetPlatform == hostPlatform && hostPlatform == buildPlatform)
    (if profiledCompiler then "profiledbootstrap" else "bootstrap");

  dontStrip = !stripped;

  doCheck = false; # requires a lot of tools, causes a dependency cycle for stdenv

  installTargets = optional stripped "install-strip";

  env = {
    NIX_NO_SELF_RPATH = true;

    # Setting $CPATH and $LIBRARY_PATH to make sure both `gcc' and `xgcc' find the
    # library headers and binaries, regarless of the language being compiled.
    #
    # Likewise, the LTO code doesn't find zlib.
    #
    # Cross-compiling, we need gcc not to read ./specs in order to build the g++
    # compiler (after the specs for the cross-gcc are created). Having
    # LIBRARY_PATH= makes gcc read the specs from ., and the build breaks.

    CPATH = toString (makeSearchPathOutput "dev" "include" ([]
      ++ optional (zlib != null) zlib
    ));

    # Per https://gcc.gnu.org/onlinedocs/gcc/Environment-Variables.html only
    # affects native buidls, but should be fine for cross.
    LIBRARY_PATH = toString (makeLibraryPath ([]
      ++ optional (zlib != null) zlib
    ));

    inherit
      (import ../common/extra-target-flags.nix {
        inherit lib stdenv crossStageStatic libcCross threadsCross;
      })
      EXTRA_FLAGS_FOR_TARGET
      EXTRA_LDFLAGS_FOR_TARGET
      ;
    NIX_CFLAGS_COMPILE = lib.optionalString (stdenv.cc.isClang && langFortran) "-Wno-unused-command-line-argument";
    NIX_LDFLAGS = lib.optionalString  hostPlatform.isSunOS "-lm -ldl";
  } // optionalAttrs (hostPlatform.system == "x86_64-solaris") {
    # https://gcc.gnu.org/install/specific.html#x86-64-x-solaris210
    CC = "gcc -m64";
  };

  passthru = {
    inherit langC langCC langObjC langObjCpp langFortran langGo version;
    isGNU = true;
  };

  enableParallelBuilding = true;
  inherit enableMultilib;

  inherit (stdenv) is64bit;

  meta = {
    homepage = "https://gcc.gnu.org/";
    license = lib.licenses.gpl3Plus;  # runtime support libraries are typically LGPLv3+
    description = "GNU Compiler Collection, version ${version}"
      + (if stripped then "" else " (with debugging info)");

    longDescription = ''
      The GNU Compiler Collection includes compiler front ends for C, C++,
      Objective-C, Fortran, OpenMP for C/C++/Fortran, and Ada, as well as
      libraries for these languages (libstdc++, libgomp,...).

      GCC development is a part of the GNU Project, aiming to improve the
      compiler used in the GNU system including the GNU/Linux variant.
    '';

    maintainers = with lib.maintainers; [ ];

    platforms =
      lib.platforms.linux ++
      lib.platforms.freebsd ++
      lib.platforms.illumos ++
      lib.platforms.darwin;
  };
}

// optionalAttrs (targetPlatform != hostPlatform && targetPlatform.libc == "msvcrt" && crossStageStatic) {
  makeFlags = [ "all-gcc" "all-target-libgcc" ];
  installTargets = "install-gcc install-target-libgcc";
}

// optionalAttrs (enableMultilib) { dontMoveLib64 = true; }
)
