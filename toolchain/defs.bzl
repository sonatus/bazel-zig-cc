load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load(":zig_toolchain.bzl", "zig_cc_toolchain_config")

DEFAULT_TOOL_PATHS = {
    "ar": "ar",
    "gcc": "c++", # https://github.com/bazelbuild/bazel/issues/4644

    "cpp": "/usr/bin/false",
    "gcov": "/usr/bin/false",
    "nm": "/usr/bin/false",
    "objdump": "/usr/bin/false",
    "strip": "/usr/bin/false",
}.items()

DEFAULT_INCLUDE_DIRECTORIES = [
    "include",
    "libcxx/include",
    "libcxxabi/include",
]

# https://github.com/ziglang/zig/blob/0cfa39304b18c6a04689bd789f5dc4d035ec43b0/src/main.zig#L2962-L2966
TARGET_CONFIGS = [
    struct(
        target="x86_64-macos-gnu",
        includes=[
            "libunwind/include",
            "libc/include/any-macos-any",
            "libc/include/x86_64-macos-any",
            "libc/include/x86_64-macos-gnu",
        ],
        # linkopts=["-lc++", "-lc++abi"],
        linkopts=[],
        copts=[],
        bazel_target_cpu="darwin",
        constraint_values=["@platforms//os:macos", "@platforms//cpu:x86_64"],
        tool_paths={"ld": "ld64.lld"},
    ),
    struct(
        target="x86_64-linux-gnu.2.19",
        includes=[
            "libunwind/include",
            "libc/include/generic-glibc",
            "libc/include/any-linux-any",
            "libc/include/x86_64-linux-gnu",
            "libc/include/x86_64-linux-any",
        ],
        linkopts=["-lc++", "-lc++abi"],
        copts=[],
        bazel_target_cpu="k8",
        constraint_values=[
            "@platforms//os:linux",
            "@platforms//cpu:x86_64",
            ":gnu_2_19",
        ],
        tool_paths={"ld": "ld.lld"},
    ),
    struct(
        target="x86_64-linux-musl",
        includes=[
            "libc/include/generic-musl",
            "libc/include/any-linux-any",
            "libc/include/x86_64-linux-musl",
            "libc/include/x86_64-linux-any",
        ],
        linkopts=[],
        copts=["-D_LIBCPP_HAS_MUSL_LIBC", "-D_LIBCPP_HAS_THREAD_API_PTHREAD"],
        bazel_target_cpu="k8",
        constraint_values=[
            "@platforms//os:linux",
            "@platforms//cpu:x86_64",
            ":musl",
        ],
        tool_paths={"ld": "ld.lld"},
    ),
]

def toolchain_repositories():
    zig_repository(
        name = "com_github_ziglang_zig",

        version = "0.8.0",
        url_format = "https://ziglang.org/download/{version}/zig-{host_platform}-{version}.tar.xz",
        host_platform_sha256 = {
            "linux-x86_64": "502625d3da3ae595c5f44a809a87714320b7a40e6dff4a895b5fa7df3391d01e",
            "macos-x86_64": "279f9360b5cb23103f0395dc4d3d0d30626e699b1b4be55e98fd985b62bc6fbe",
        },

        host_platform_include_root = {
            "macos-x86_64": "lib/zig/",
            "linux-x86_64": "lib/",
        }
    )

def register_all_toolchains():
    for target_config in TARGET_CONFIGS:
        native.register_toolchains(
            "@com_github_ziglang_zig//:%s_toolchain" % target_config.target,
        )

ZIG_TOOL_PATH = "tools/{zig_tool}"
ZIG_TOOL_WRAPPER = """#!/bin/bash
export HOME=$TMPDIR
exec "{zig}" "{zig_tool}" "$@"
"""

ZIG_TOOLS = [
    "c++",
    "cc",
    "ar",
    # List of ld tools: https://github.com/ziglang/zig/blob/0cfa39304b18c6a04689bd789f5dc4d035ec43b0/src/main.zig#L2962-L2966
    # and also: https://github.com/ziglang/zig/issues/3257
    "ld.lld", # ELF 
    "ld64.lld", # Mach-O
    "lld-link", # COFF
    "wasm-ld", # WebAssembly
]

BUILD = """
load("@zig-cc-bazel//toolchain:defs.bzl", "zig_build_macro")
package(default_visibility = ["//visibility:public"])
zig_build_macro(absolute_path={absolute_path}, zig_include_root={zig_include_root})

constraint_setting(name = "libc")

constraint_value(
    name = "gnu_2_19",
    constraint_setting = ":libc",
)

constraint_value(
    name = "musl",
    constraint_setting = ":libc",
)


platform(
    name = "platform_linux-x86_64-musl",
    constraint_values = [
        "@platforms//os:linux",
        "@platforms//cpu:x86_64",
        ":musl",
    ],
)

platform(
    name = "platform_linux-x86_64-gnu",
    constraint_values = [
        "@platforms//os:linux",
        "@platforms//cpu:x86_64",
        ":gnu_2_19",
    ],
)

"""

def _zig_repository_impl(repository_ctx):
    if repository_ctx.os.name.lower().startswith("mac os"):
        host_platform = "macos-x86_64"
    else:
        host_platform = "linux-x86_64"

    zig_include_root = repository_ctx.attr.host_platform_include_root[host_platform]
    zig_sha256 = repository_ctx.attr.host_platform_sha256[host_platform]
    format_vars = {
        "version" : repository_ctx.attr.version,
        "host_platform" : host_platform,
    }
    zig_url = repository_ctx.attr.url_format.format(**format_vars)

    repository_ctx.download_and_extract(
        url = zig_url,
        stripPrefix = "zig-{host_platform}-{version}/".format(**format_vars),
        sha256 = zig_sha256,
    )

    for zig_tool in ZIG_TOOLS:
        repository_ctx.file(
            ZIG_TOOL_PATH.format(zig_tool=zig_tool),
            ZIG_TOOL_WRAPPER.format(zig=str(repository_ctx.path("zig")), zig_tool=zig_tool),
        )

    absolute_path = json.encode(str(repository_ctx.path("")))
    repository_ctx.file(
        "BUILD",
        BUILD.format(absolute_path=absolute_path, zig_include_root=json.encode(zig_include_root)),
    )

zig_repository = repository_rule(
    attrs = {
        "url": attr.string(),
        "version": attr.string(),
        "host_platform_sha256": attr.string_dict(),
        "url_format": attr.string(),
        "host_platform_include_root": attr.string_dict(),
    },
    implementation = _zig_repository_impl,
)

def filegroup(name, **kwargs):
    native.filegroup(name = name, **kwargs)
    return ":" + name

def zig_build_macro(absolute_path, zig_include_root):
    filegroup(name="empty")
    filegroup(name="zig_compiler", srcs=["zig"])
    filegroup(name="lib/std", srcs=native.glob(["lib/std/**"]))

    lazy_filegroups = {}

    for target_config in TARGET_CONFIGS:
        target = target_config.target
        native.platform(name = target, constraint_values = target_config.constraint_values)

        all_srcs = []
        ar_srcs = [":zig_compiler"]
        linker_srcs = [":zig_compiler"]
        compiler_srcs = [":zig_compiler"]
        tool_srcs = {"gcc": compiler_srcs, "ld": linker_srcs, "ar": ar_srcs}
        
        cxx_builtin_include_directories = []
        for d in DEFAULT_INCLUDE_DIRECTORIES + target_config.includes:
            d = zig_include_root + d
            if d not in lazy_filegroups:
                lazy_filegroups[d] = filegroup(name=d, srcs=native.glob([d + "/**"]))
            compiler_srcs.append(lazy_filegroups[d])
            cxx_builtin_include_directories.append(absolute_path + "/" + d)

        absolute_tool_paths = {}
        for name, path in target_config.tool_paths.items() + DEFAULT_TOOL_PATHS:
            if path[0] == "/":
                absolute_tool_paths[name] = path
                continue
            tool_path = ZIG_TOOL_PATH.format(zig_tool=path)
            absolute_tool_paths[name] = "%s/%s" % (absolute_path, tool_path)
            tool_srcs[name].append(tool_path)

        ar_files       = filegroup(name=target + "_ar_files",       srcs=ar_srcs)
        linker_files   = filegroup(name=target + "_linker_files",   srcs=linker_srcs)
        compiler_files = filegroup(name=target + "_compiler_files", srcs=compiler_srcs)
        all_files      = filegroup(name=target + "_all_files",      srcs=all_srcs + [ar_files, linker_files, compiler_files])

        zig_cc_toolchain_config(
            name = target + "_cc_toolchain_config",
            target = target,
            tool_paths = absolute_tool_paths,
            cxx_builtin_include_directories = cxx_builtin_include_directories,
            copts = target_config.copts,
            linkopts = target_config.linkopts,
            target_system_name = "unknown",
            target_cpu = target_config.bazel_target_cpu,
            target_libc = "unknown",
            compiler = "clang",
            abi_version = "unknown",
            abi_libc_version = "unknown",
        )

        native.cc_toolchain(
            name = target + "_cc_toolchain",
            toolchain_identifier = target + "-toolchain",
            toolchain_config = ":%s_cc_toolchain_config" % target,
            all_files = all_files,
            ar_files = ar_files,
            compiler_files = compiler_files,
            linker_files = linker_files,
            dwp_files = ":empty",
            objcopy_files = ":empty",
            strip_files = ":empty",
            supports_param_files = 0,
        )

        native.cc_toolchain_suite(
            name = target + "_cc_toolchain_suite",
            toolchains = {
                target_config.bazel_target_cpu: ":%s_cc_toolchain" % target,
            },
            tags = ["manual"]
        )

        native.toolchain(
            name = target + "_toolchain",
            exec_compatible_with = None,
            target_compatible_with = target_config.constraint_values,
            toolchain = ":%s_cc_toolchain" % target,
            toolchain_type = "@bazel_tools//tools/cpp:toolchain_type",
        )