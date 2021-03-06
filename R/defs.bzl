# Copyright 2017 GRAIL, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""R package build, test and install Bazel rules.

r_pkg will build the package and its dependencies and install them in
Bazel's sandbox.

r_unit_test will install all the dependencies of the package in Bazel's
sandbox and generate a script to run the test scripts from the package.

r_pkg_test will install all the dependencies of the package in Bazel's
sandbox and generate a script to run R CMD CHECK on the package.

r_library will generate binary archives for the package and its
dependencies (as a side effect of installing them to Bazel's sandbox),
install all the binary archives into a folder, and make available the
folder as a single tar. The target can also be executed using bazel run.
See usage by running with -h flag.
"""


_R = "R --vanilla --slave "
_Rscript = "Rscript --vanilla "


# Provider with following fields:
# "pkg_name": "Name of the package",
# "lib_loc": "Directory where this package is installed",
# "lib_files": "All files in this package",
# "bin_archive": "Binary archive of this package",
# "transitive_pkg_deps": "depset of all dependencies of this target"
RPackage = provider(doc="Build information about an R package dependency")


def _package_name(ctx):
    # Package name from attribute with fallback to label name.

    pkg_name = ctx.attr.pkg_name
    if pkg_name == "":
        pkg_name = ctx.label.name
    return pkg_name


def _target_dir(ctx):
    # Relative path to target directory.

    workspace_root = ctx.label.workspace_root
    if workspace_root != "" and ctx.label.package != "":
        workspace_root += "/"
    target_dir = workspace_root + ctx.label.package
    return target_dir


def _package_source_dir(target_dir, pkg_name):
    # Relative path to R package source.

    return target_dir


def _package_files(ctx):
    # Returns files that are installed as an R package.

    pkg_name = _package_name(ctx)
    target_dir = _target_dir(ctx)
    pkg_src_dir = _package_source_dir(target_dir, pkg_name)

    has_R_code = False
    has_native_code = False
    has_data_files = False
    inst_files = []
    for src_file in ctx.files.srcs:
        if src_file.path.startswith(pkg_src_dir + "/R/"):
            has_R_code = True
        elif src_file.path.startswith(pkg_src_dir + "/src/"):
            has_native_code = True
        elif src_file.path.startswith(pkg_src_dir + "/data/"):
            has_data_files = True
        elif src_file.path.startswith(pkg_src_dir + "/inst/"):
            inst_files += [src_file]

    pkg_files = [
        ctx.actions.declare_file("lib/{0}/DESCRIPTION".format(pkg_name)),
        ctx.actions.declare_file("lib/{0}/NAMESPACE".format(pkg_name)),
        ctx.actions.declare_file("lib/{0}/Meta/hsearch.rds".format(pkg_name)),
        ctx.actions.declare_file("lib/{0}/Meta/links.rds".format(pkg_name)),
        ctx.actions.declare_file("lib/{0}/Meta/nsInfo.rds".format(pkg_name)),
        ctx.actions.declare_file("lib/{0}/Meta/package.rds".format(pkg_name)),
        ctx.actions.declare_file("lib/{0}/Meta/Rd.rds".format(pkg_name)),
        ctx.actions.declare_file("lib/{0}/help/AnIndex".format(pkg_name)),
        ctx.actions.declare_file("lib/{0}/help/aliases.rds".format(pkg_name)),
        ctx.actions.declare_file("lib/{0}/help/{0}.rdb".format(pkg_name)),
        ctx.actions.declare_file("lib/{0}/help/{0}.rdx".format(pkg_name)),
        ctx.actions.declare_file("lib/{0}/help/paths.rds".format(pkg_name)),
        ctx.actions.declare_file("lib/{0}/html/00Index.html".format(pkg_name)),
        ctx.actions.declare_file("lib/{0}/html/R.css".format(pkg_name)),
    ]

    if has_R_code:
        pkg_files += [
            ctx.actions.declare_file("lib/{0}/R/{0}".format(pkg_name)),
            ctx.actions.declare_file("lib/{0}/R/{0}.rdb".format(pkg_name)),
            ctx.actions.declare_file("lib/{0}/R/{0}.rdx".format(pkg_name)),
        ]

    if has_native_code:
        shlib_name = ctx.attr.shlib_name
        if shlib_name == "":
            shlib_name = pkg_name
        pkg_files += [ctx.actions.declare_file("lib/{0}/libs/{1}.so"
                                               .format(pkg_name, shlib_name))]

    if has_data_files and ctx.attr.lazy_data:
        pkg_files += [
            ctx.actions.declare_file("lib/{0}/data/Rdata.rdb".format(pkg_name)),
            ctx.actions.declare_file("lib/{0}/data/Rdata.rds".format(pkg_name)),
            ctx.actions.declare_file("lib/{0}/data/Rdata.rdx".format(pkg_name)),
        ]

    for inst_file in inst_files:
        pkg_files += [ctx.actions.declare_file(
            "lib/{0}/{1}".format(
                pkg_name,
                inst_file.path[len(pkg_src_dir + "/inst/"):]))]

    for post_install_file in ctx.attr.post_install_files:
        pkg_files += [(ctx.actions.declare_file("lib/{0}/{1}"
                                                .format(pkg_name, post_install_file)))]

    return pkg_files


def _library_deps(target_deps, path_prefix=""):
    # Returns information about all dependencies of this package.

    # Transitive closure of all package dependencies.
    transitive_pkg_deps = depset()
    for target_dep in target_deps:
        transitive_pkg_deps += (target_dep[RPackage].transitive_pkg_deps +
                                depset([target_dep[RPackage]]))

    # Colon-separated search path to individual package libraries.
    lib_search_path = []

    # Files in the aggregated library of all dependency packages.
    lib_files = []

    # Binary archives of all dependency packages.
    bin_archives = []

    # R 3.3 has a bug in which some relative paths are not recognized in
    # R_LIBS_USER when running R CMD INSTALL (works fine for other
    # uses).  We work around this bug by creating a single directory
    # with symlinks to all deps.  Without this bug, lib_search_path can
    # be used directly.  This bug is fixed in R 3.4.
    symlink_deps_command = "mkdir -p ${{R_LIBS_USER}}\n"

    for pkg_dep in transitive_pkg_deps:
        dep_lib_loc = path_prefix + pkg_dep.lib_loc
        lib_search_path += [dep_lib_loc]
        lib_files += pkg_dep.lib_files
        bin_archives += [pkg_dep.bin_archive]
        symlink_deps_command += "ln -s $(pwd)/%s/%s ${{R_LIBS_USER}}/\n" % (dep_lib_loc,
                                                                            pkg_dep.pkg_name)

    return {
        "transitive_pkg_deps": transitive_pkg_deps,
        "lib_search_path": lib_search_path,
        "lib_files": lib_files,
        "bin_archives": bin_archives,
        "symlinked_library_command": symlink_deps_command,
    }


def _pkgconfig_paths():
    # For macOS only: pkg-config opt paths when xcode provided
    # versions are defaults but we want the Homebrew ones.
    return ":".join([
        "/usr/local/opt/icu4c/lib/pkgconfig",
        "/usr/local/opt/openssl/lib/pkgconfig",
    ])


def _build_impl(ctx):
    # Implementation for the r_pkg rule.

    pkg_name = _package_name(ctx)
    target_dir = _target_dir(ctx)
    pkg_src_dir = _package_source_dir(target_dir, pkg_name)
    pkg_lib_dir = "{0}/lib".format(target_dir)
    pkg_lib_path = "{0}/{1}".format(ctx.bin_dir.path, pkg_lib_dir)
    pkg_bin_archive = ctx.actions.declare_file(ctx.label.name + ".bin.tar.gz")
    package_files = _package_files(ctx)
    output_files = package_files + [pkg_bin_archive]

    library_deps = _library_deps(ctx.attr.deps, path_prefix=(ctx.bin_dir.path + "/"))
    all_input_files = (library_deps["lib_files"] + ctx.files.srcs
                       + [ctx.file.makevars_darwin, ctx.file.makevars_linux])

    env_dict = {
        "PKG_CONFIG_PATH": _pkgconfig_paths(),
    }

    command = ("\n".join([
        "set -euo pipefail",
        "",
        "PWD=$(pwd)",
        "mkdir -p {0}",
        "if [[ $(uname) == \"Darwin\" ]]; then export R_MAKEVARS_USER=${{PWD}}/{4};",
        "else export R_MAKEVARS_USER=${{PWD}}/{5}; fi",
        "export PATH",  # PATH needs to be exported to R.
        "",
        "export R_LIBS_USER=$(mktemp -d)",
        library_deps["symlinked_library_command"],
        "",
        "set +e",
        "OUT=$(%s CMD INSTALL {6} --build --library={0} {1} 2>&1 )" % _R,
        "if (( $? )); then",
        "  echo \"${{OUT}}\"",
        "  rm -rf ${{R_LIBS_USER}}",
        "  exit 1",
        "fi",
        "set -e",
        "",
        "mv {2}*gz {3}",  # .tgz on macOS and .tar.gz on Linux.
        "rm -rf ${{R_LIBS_USER}}",
    ]).format(pkg_lib_path, pkg_src_dir, pkg_name, pkg_bin_archive.path,
              ctx.file.makevars_darwin.path, ctx.file.makevars_linux.path,
              ctx.attr.install_args))
    ctx.actions.run_shell(outputs=output_files, inputs=all_input_files, command=command,
                          env=env_dict, mnemonic="RBuild",
                          progress_message="Building R package %s" % pkg_name)

    return [DefaultInfo(files=depset(output_files)),
            RPackage(pkg_name=pkg_name,
                     lib_loc=pkg_lib_dir, lib_files=package_files,
                     bin_archive=pkg_bin_archive,
                     transitive_pkg_deps=library_deps["transitive_pkg_deps"])]


r_pkg = rule(
    implementation=_build_impl,
    attrs={
        "srcs": attr.label_list(
            allow_files=True, mandatory=True,
            doc="Source files to be included for building the package"),
        "pkg_name": attr.string(
            doc="Name of the package if different from the target name"),
        "deps": attr.label_list(
            providers=[RPackage],
            doc="R package dependencies of type r_pkg"),
        "install_args": attr.string(
            doc="Additional arguments to supply to R CMD INSTALL"),
        "makevars_darwin": attr.label(
            allow_single_file=True,
            default="@com_grail_rules_r//R:Makevars.darwin",
            doc="Makevars file to use for macOS overrides"),
        "makevars_linux": attr.label(
            allow_single_file=True,
            default="@com_grail_rules_r//R:Makevars.linux",
            doc="Makevars file to use for Linux overrides"),
        "shlib_name": attr.string(
            doc="Shared library name, if different from package name"),
        "lazy_data": attr.bool(
            default=False,
            doc="Set to True if the package uses the LazyData feature"),
        "post_install_files": attr.string_list(
            doc="Extra files that the install process generates"),
    },
    doc=("Rule to install the package and its transitive dependencies" +
         "in the Bazel sandbox."),
)


def _test_impl(ctx):
    library_deps = _library_deps(ctx.attr.deps)
    lib_search_path = ":".join(library_deps["lib_search_path"])
    env_dict = {
        "R_LIBS_USER": lib_search_path
    }

    pkg_name = ctx.attr.pkg_name
    pkg_tests_dir = _package_source_dir(_target_dir(ctx), pkg_name) + "/tests"
    test_files = []
    for src_file in ctx.files.srcs:
        if src_file.path.startswith(pkg_tests_dir):
            test_files += [src_file]

    script = "\n".join([
        "#!/bin/bash",
        "set -euxo pipefail",
        "test -d {0}",
        "",
        "export R_LIBS_USER=$(mktemp -d)",
        library_deps["symlinked_library_command"],
        "",
        "# Give a writable directory to tests",
        "TESTS_TMP_DIR=$(mktemp -d)",
        "cp -r {0}/ ${{TESTS_TMP_DIR}}",
        "pushd ${{TESTS_TMP_DIR}}",
        "",
        "cleanup() {{",
        "  popd",
        "  rm -rf ${{TESTS_TMP_DIR}}",
        "  rm -rf ${{R_LIBS_USER}}",
        "}}",
        "",
        "for SCRIPT in $(ls *.R); do",
        "  if ! " + _Rscript + "${{SCRIPT}}; then",
        "    echo $?",
        "    cleanup",
        "    exit 1",
        "  fi",
        "done",
        "",
        "cleanup",
    ]).format(pkg_tests_dir)

    ctx.actions.write(
        output=ctx.outputs.executable,
        content=script)

    runfiles = ctx.runfiles(files=library_deps["lib_files"] + test_files)
    return [DefaultInfo(runfiles=runfiles)]


r_unit_test = rule(
    implementation=_test_impl,
    attrs={
        "srcs": attr.label_list(
            allow_files=True, mandatory=True,
            doc="Test scripts and test data files for the package"),
        "pkg_name": attr.string(
            mandatory=True,
            doc="Name of the package"),
        "deps": attr.label_list(
            providers=[RPackage],
            doc="R package dependencies of type r_pkg"),
    },
    test=True,
    doc=("Rule to keep all deps in the sandbox, and run the test " +
         "scripts of the specified package. The package itself must " +
         "be one of the deps."),
)


def _check_impl(ctx):
    library_deps = _library_deps(ctx.attr.deps)
    lib_search_path = ":".join(library_deps["lib_search_path"])
    env_dict = {
        "R_LIBS_USER": lib_search_path
    }
    all_input_files = library_deps["lib_files"] + ctx.files.srcs

    # Bundle the package as a runfile for the test.
    pkg_name = ctx.attr.pkg_name
    target_dir = _target_dir(ctx)
    pkg_src_dir = _package_source_dir(target_dir, pkg_name)
    pkg_src_archive = ctx.actions.declare_file(ctx.attr.pkg_name + ".tar.gz")
    command = (_R + "CMD build {0} {1} > /dev/null && mv {2}*.tar.gz {3}"
               .format(ctx.attr.build_args, pkg_src_dir, ctx.attr.pkg_name,
                       pkg_src_archive.path))
    ctx.actions.run_shell(
        outputs=[pkg_src_archive], inputs=all_input_files,
        command=command, env=env_dict,
        progress_message="Building R (source) package %s" % pkg_name)

    script = "\n".join([
        "#!/bin/bash",
        "set -euxo pipefail",
        "test -e {0}",
        "",
        "export R_LIBS_USER=$(mktemp -d)",
        library_deps["symlinked_library_command"],
        _R + "CMD check {1} {0}",
        "rm -rf ${{R_LIBS_USER}}",
        ""
    ]).format(pkg_src_archive.short_path, ctx.attr.check_args)

    ctx.actions.write(
        output=ctx.outputs.executable,
        content=script)

    runfiles = ctx.runfiles(
        files=[pkg_src_archive] + library_deps["lib_files"])
    return [DefaultInfo(runfiles=runfiles)]


r_pkg_test = rule(
    implementation=_check_impl,
    attrs={
        "srcs": attr.label_list(
            allow_files=True, mandatory=True,
            doc="Source files to be included for building the package"),
        "pkg_name": attr.string(
            mandatory=True,
            doc="Name of the package"),
        "deps": attr.label_list(
            providers=[RPackage],
            doc="R package dependencies of type r_pkg"),
        "build_args": attr.string(
            default="--no-build-vignettes --no-manual",
            doc="Additional arguments to supply to R CMD build"),
        "check_args": attr.string(
            default="--no-build-vignettes --no-manual",
            doc="Additional arguments to supply to R CMD check"),
    },
    test=True,
    doc=("Rule to keep all deps of the package in the sandbox, build " +
         "a source archive of this package, and run R CMD check on " +
         "the package source archive in the sandbox."),
)


def _library_impl(ctx):
    library_deps = _library_deps(ctx.attr.pkgs)
    bin_archive_files = []
    for bin_archive in library_deps["bin_archives"]:
        bin_archive_files += [bin_archive.path]
    all_deps = library_deps["bin_archives"]

    library_archive = ctx.actions.declare_file("library.tar")
    command = "\n".join([
        "#!/bin/bash",
        "set -euo pipefail",
        "",
        "BIN_ARCHIVES=(",
    ] + bin_archive_files + [
        ")",
        "LIBRARY_DIR=$(mktemp -d)",
        _R + "CMD INSTALL --library=${LIBRARY_DIR} ${BIN_ARCHIVES[*]} > /dev/null",
        "tar -c -C ${LIBRARY_DIR} -f %s ." % library_archive.path,
        "rm -rf ${LIBRARY_DIR}"
    ])
    ctx.actions.run_shell(outputs=[library_archive], inputs = all_deps,
                          command=command)

    script = "\n".join([
        "#!/bin/bash",
        "set -euo pipefail",
        "",
        "args=`getopt l:s: $*`",
        "if [ $? != 0 ]; then",
        "  echo 'Usage: bazel run target_label -- [-l library_path] [-s repo_root]'",
        "  echo '  -l  library_path is the directory where R packages will be installed'",
        "  echo '  -s  if specified, will only install symlinks pointing into repo_root/bazel-bin'",
        "  exit 2",
        "fi",
        "set -- $args",
        "",
        "LIBRARY_PATH=%s" % ctx.attr.library_path,
        "SOFT_INSTALL=0",
        "for i; do",
        "  case $i",
        "  in",
        "    -l)",
        "       LIBRARY_PATH=${2}; shift;",
        "       shift;;",
        "    -s)",
        "       SOFT_INSTALL=1; BAZEL_BIN=${2}/bazel-bin; shift;",
        "       shift;;",
        "  esac",
        "done",
        "",
        "DEFAULT_R_LIBRARY=$(%s -e 'cat(.libPaths()[1])')" % _R,
        "LIBRARY_PATH=${LIBRARY_PATH:=${DEFAULT_R_LIBRARY}}",
        "mkdir -p ${LIBRARY_PATH}",
        "",
        "BAZEL_LIB_DIRS=(",
    ] + library_deps["lib_search_path"] + [
        ")",
        "if (( ${SOFT_INSTALL} )); then",
        "  echo \"Installing package symlinks from ${BAZEL_BIN} to ${LIBRARY_PATH}\"",
        "  for LIB_DIR in ${BAZEL_LIB_DIRS[*]}; do",
        "    for PKG in ${BAZEL_BIN}/${LIB_DIR}/*; do",
        "      ln -s -f ${PKG} ${LIBRARY_PATH}",
        "    done",
        "  done",
        "else",
        "  echo \"Copying installed packages to ${LIBRARY_PATH}\"",
        "  tar -x -C ${LIBRARY_PATH} -f %s" % library_archive.short_path,
        "fi",
    ])

    ctx.actions.write(
        output=ctx.outputs.executable,
        content=script)

    runfiles = ctx.runfiles(files=([library_archive]))
    return [DefaultInfo(runfiles=runfiles, files=depset([library_archive]))]


r_library = rule(
    implementation=_library_impl,
    attrs={
        "pkgs": attr.label_list(
            providers=[RPackage], mandatory=True,
            doc="Package (and dependencies) to install"),
        "library_path": attr.string(
            default="",
            doc=("If different from system default, default library " +
                 "location for installation. For runtime overrides, " +
                 "use bazel run [target] -- -l [path]")),
    },
    executable=True,
    doc=("Rule to install the given package and all dependencies to " +
         "a user provided or system default R library site.")
)


def r_package(pkg_name, pkg_srcs, pkg_deps, pkg_suggested_deps=[]):
    """Convenience macro to generate the r_pkg and r_library targets."""
   
    r_pkg(
        name = pkg_name,
        srcs = pkg_srcs,
        deps = pkg_deps,
    )

    r_library(
        name = "library",
        pkgs = [":" + pkg_name],
        tags = ["manual"],
    )


def r_package_with_test(pkg_name, pkg_srcs, pkg_deps, pkg_suggested_deps=[], test_timeout="short"):
    """Convenience macro to generate the r_pkg, r_unit_test, r_pkg_test, and r_library targets."""

    r_pkg(
        name = pkg_name,
        srcs = pkg_srcs,
        deps = pkg_deps,
    )

    r_library(
        name = "library",
        pkgs = [":" + pkg_name],
        tags = ["manual"],
    )

    r_unit_test(
        name = "test",
        timeout = test_timeout,
        srcs = pkg_srcs,
        pkg_name = pkg_name,
        deps = [":" + pkg_name] + pkg_deps + pkg_suggested_deps,
    )

    r_pkg_test(
        name = "check",
        timeout = test_timeout,
        srcs = pkg_srcs,
        pkg_name = pkg_name,
        deps = pkg_deps + pkg_suggested_deps,
    )
