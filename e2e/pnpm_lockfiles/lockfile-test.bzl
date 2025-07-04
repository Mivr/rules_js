"""
Test utils for lockfiles
"""

load("@aspect_bazel_lib//lib:copy_file.bzl", "copy_file")
load("@aspect_bazel_lib//lib:write_source_files.bzl", "write_source_files")
load("@aspect_rules_js//js:defs.bzl", "js_test")
load("@bazel_skylib//rules:build_test.bzl", "build_test")

# Each version being tested
PNPM_LOCK_VERSIONS = [
    "v54",
    "v60",
    "v61",
    "v90",
]

BZLMOD_FILES = {
    # global
    "defs.bzl": "@REPO_NAME//:defs.bzl",

    # resolved.json reference
    "is-odd_resolved.json": "@REPO_NAME//VERSION:is-odd/resolved.json",
    "is-odd-v0_resolved.json": "@REPO_NAME//VERSION:is-odd-v0/resolved.json",

    # hasBin, optional deps, deps and across versions
    "rollup_links_defs.bzl": "@REPO_NAME__rollup__2.14.0__links//:defs.bzl",
    "rollup_package_json.bzl": "@REPO_NAME__rollup__2.14.0//VERSION:package_json.bzl",
    "rollup3_package_json.bzl": "@REPO_NAME__rollup__3.29.4//VERSION:package_json.bzl",
}

WKSP_FILES = {
    "repositories.bzl": "@REPO_NAME//:repositories.bzl",
}

def lockfile_test(npm_link_all_packages, name = None):
    """
    Tests for a lockfile and associated targets + files generated by rules_js.

    Args:
        name: the lockfile version name
        npm_link_all_packages: the npm_link_all_packages function
    """

    lock_version = name if name else native.package_name()
    lock_repo = "lock-%s" % lock_version

    npm_link_all_packages(name = "node_modules")

    # Copy each test to this lockfile dir
    for test in ["patched-dependencies-test.js", "aliases-test.js"]:
        copy_file(
            name = "copy-{}".format(test),
            src = "//:base/{}".format(test),
            out = test,
        )

    js_test(
        name = "patch-test",
        data = [
            ":node_modules/meaning-of-life",
        ],
        entry_point = "patched-dependencies-test.js",
    )

    js_test(
        name = "aliases-test",
        data = [
            ":node_modules/@aspect-test/a",
            ":node_modules/@aspect-test/a2",
            ":node_modules/aspect-test-a-no-scope",
            ":node_modules/aspect-test-a/no-at",
            ":node_modules/@aspect-test-a-bad-scope",
            ":node_modules/@aspect-test-custom-scope/a",
            ":node_modules/@scoped/a",
            ":node_modules/@types/node",
            ":node_modules/alias-only-sizzle",
            ":node_modules/alias-project-a",
            ":node_modules/alias-types-node",
            ":node_modules/is-odd",
            ":node_modules/is-odd-alias",
            ":node_modules/is-odd-v0",
            ":node_modules/is-odd-v1",
            ":node_modules/is-odd-v2",
            ":node_modules/is-odd-v3",
            ":node_modules/lodash",
            ":node_modules/@isaacs/cliui",
        ],
        entry_point = "aliases-test.js",
    )

    build_test(
        name = "targets",
        targets = [
            # The full node_modules target
            ":node_modules",

            # Direct 'dependencies'
            ":node_modules/@aspect-test",  # target for the scope
            ":node_modules/@aspect-test/a",

            # Direct 'devDependencies'
            ":node_modules/@aspect-test/b",
            ":node_modules/@types/node",

            # Direct 'optionalDependencies'
            ":node_modules/@aspect-test/h-is-only-optional",

            # Direct optional + dev
            ":node_modules/@aspect-test/c",

            # rollup has a 'optionalDependency' (fsevents)
            ":node_modules/rollup",

            # npm: alias to a package that has many peers
            ":node_modules/rollup-plugin-with-peers",
            # underlying repo for the many-peers package
            "@%s__at_rollup_plugin-typescript__8.2.1_%s//:pkg" % (
                lock_repo,
                "3vgsug3mjv7wvue74swjdxifxy" if lock_version == "v54" else "626159424" if (lock_version == "v90" or lock_version == "v101") else "1813138439" if (lock_version == "v61" or lock_version == "v60") else "unknown",
            ),

            # uuv 'hasBin'
            ":node_modules/uvu",

            # a package with various `npm:` cases
            ":node_modules/@isaacs/cliui",

            # link:, workspace:, file:, ./rel/path
            ":node_modules/@scoped",  # target for the scope
            ":node_modules/@scoped/a",
            ":node_modules/@scoped/b",
            ":node_modules/@scoped/c",
            ":node_modules/@scoped/d",
            ":node_modules/test-c200-d200",
            ":node_modules/test-c201-d200",
            ":node_modules/test-peer-types",
            ":node_modules/scoped/bad",
            ":node_modules/lodash",

            # Packages involving overrides
            ":node_modules/is-odd",
            ":.aspect_rules_js/node_modules/is-odd@3.0.1",
            ":.aspect_rules_js/node_modules/is-number@0.0.0",

            # Odd git/http versions
            ":node_modules/debug",
            ":node_modules/hello",
            ":node_modules/jsonify",
            ":node_modules/jquery-git-ssh-e61fccb",
            ":node_modules/jquery-git-ssh-399b201",

            # npm: alias
            ":node_modules/@aspect-test/a2",
            # npm: alias to registry-scoped packages
            ":node_modules/alias-types-node",
            # npm: alias adding/removing or odd @scopes
            ":node_modules/aspect-test-a/no-at",
            ":node_modules/aspect-test-a-no-scope",
            ":node_modules/@aspect-test-a-bad-scope",
            ":node_modules/@aspect-test-custom-scope",  # target for the scope
            ":node_modules/@aspect-test-custom-scope/a",

            # alias via link:
            ":node_modules/alias-project-a",

            # npm: alias to alternate versions
            ":node_modules/is-odd-v0",
            ":node_modules/is-odd-v1",
            ":node_modules/is-odd-v2",
            ":node_modules/is-odd-v3",
            ":.aspect_rules_js/node_modules/is-odd@0.1.0",
            ":.aspect_rules_js/node_modules/is-odd@1.0.0",
            ":.aspect_rules_js/node_modules/is-odd@2.0.0",
            ":.aspect_rules_js/node_modules/is-odd@3.0.0",

            # npm: alias to package not listed elsewhere
            ":node_modules/alias-only-sizzle",
            ":.aspect_rules_js/node_modules/@types+sizzle@2.3.9",
            "@%s__at_types_sizzle__2.3.9//:pkg" % lock_repo,

            # Targets within the virtual store...
            # Direct dep targets
            ":.aspect_rules_js/node_modules/@aspect-test+a@5.0.2",
            ":.aspect_rules_js/node_modules/@aspect-test+a@5.0.2/dir",
            ":.aspect_rules_js/node_modules/@aspect-test+a@5.0.2/pkg",
            ":.aspect_rules_js/node_modules/@aspect-test+a@5.0.2/ref",

            # Direct deps with lifecycles
            ":.aspect_rules_js/node_modules/@aspect-test+c@2.0.2/lc",
            ":.aspect_rules_js/node_modules/@aspect-test+c@2.0.2/pkg_lc",

            # link:, workspace:, file:, ./rel/path
            ":.aspect_rules_js/node_modules/@scoped+a@0.0.0",
            ":.aspect_rules_js/node_modules/@scoped+b@0.0.0",
            ":.aspect_rules_js/node_modules/@scoped+c@0.0.0",
            ":.aspect_rules_js/node_modules/@scoped+d@0.0.0",
            ":.aspect_rules_js/node_modules/test-c200-d200@0.0.0",
            ":.aspect_rules_js/node_modules/test-c201-d200@0.0.0",
            ":.aspect_rules_js/node_modules/lodash@4.17.21",
            ":.aspect_rules_js/node_modules/lodash@4.17.21/dir",

            # Patched dependencies
            ":.aspect_rules_js/node_modules/meaning-of-life@1.0.0_%s" % ("1541309197" if lock_version == "v101" else "o3deharooos255qt5xdujc3cuq"),
            "@%s__meaning-of-life__1.0.0_%s//:pkg" % (lock_repo, "1541309197" if lock_version == "v101" else "o3deharooos255qt5xdujc3cuq"),

            # Direct deps from custom registry
            ":.aspect_rules_js/node_modules/@types+node@16.18.11",

            # Direct deps with peers
            ":.aspect_rules_js/node_modules/@aspect-test+d@2.0.0_at_aspect-test_c_2.0.2",
            "@%s__at_aspect-test_d__2.0.0_at_aspect-test_c_2.0.2//:pkg" % lock_repo,
        ],
    )

    # The generated bzl files (standard non-workspace)
    # buildifier: disable=no-effect
    [
        native.genrule(
            name = "extract-%s" % out,
            srcs = [what.replace("VERSION", lock_version).replace("REPO_NAME", lock_repo)],
            outs = ["snapshot-extracted-%s" % out],
            cmd = 'sed "s/{}/<LOCKVERSION>/g" "$<" > "$@"'.format(lock_version),
            visibility = ["//visibility:private"],
        )
        for (out, what) in BZLMOD_FILES.items()
    ]

    write_source_files(
        name = "repos",
        files = dict(
            [
                (
                    "snapshots/%s" % f,
                    ":extract-%s" % f,
                )
                for f in BZLMOD_FILES.keys()
            ],
        ),
        # Target names may be different on workspace vs bzlmod
        target_compatible_with = select({
            "@aspect_bazel_lib//lib:bzlmod": [],
            "//conditions:default": ["@platforms//:incompatible"],
        }),
        # Target names may be different on bazel versions
        tags = ["skip-on-bazel6"],
    )

    # buildifier: disable=no-effect
    [
        native.genrule(
            name = "extract-%s" % out,
            srcs = [what.replace("VERSION", lock_version).replace("REPO_NAME", lock_repo)],
            outs = ["snapshot-extracted-%s" % out],
            cmd = 'sed "s/{}/<LOCKVERSION>/g" "$<" | sed "s/system_tar = \\".*\\"/system_tar = \\"<TAR>\\"/" > "$@"'.format(lock_version),
            visibility = ["//visibility:private"],
            # Target names may be different on workspace vs bzlmod
            target_compatible_with = select({
                "@aspect_bazel_lib//lib:bzlmod": ["@platforms//:incompatible"],
                "//conditions:default": [],
            }),
        )
        for (out, what) in WKSP_FILES.items()
    ]

    write_source_files(
        name = "wksp-repos",
        files = dict(
            [
                (
                    "snapshots/%s" % f,
                    ":extract-%s" % f,
                )
                for f in WKSP_FILES.keys()
            ],
        ),
        # Target names may be different on workspace vs bzlmod
        target_compatible_with = select({
            "@aspect_bazel_lib//lib:bzlmod": ["@platforms//:incompatible"],
            "//conditions:default": [],
        }),
        # Target names may be different on bazel versions
        tags = ["skip-on-bazel6"],
    )
