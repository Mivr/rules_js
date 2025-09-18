# npm_translate_lock: How It Works

## Overview

`npm_translate_lock` is a Bazel repository rule that converts NPM package manager lock files into Bazel-compatible dependency declarations. It serves as the bridge between the NPM ecosystem and Bazel's build system.

## Key Functions

### 1. **Lock File Processing**
- **Input**: Accepts `pnpm-lock.yaml`, `package-lock.json`, or `yarn.lock`
- **Normalization**: Converts all lock file formats to pnpm's format for consistent processing
- **Bootstrap**: If no pnpm lock file exists, runs `pnpm import` to create one

### 2. **Dependency Resolution**
- **Transitive Closure**: Walks the entire dependency tree to resolve all transitive dependencies
- **Cycle Breaking**: Handles circular dependencies that are common in the NPM ecosystem
- **Filtering**: Applies prod/dev/optional dependency filters based on configuration

### 3. **Bazel Repository Generation**
- **External Repositories**: Creates individual Bazel external repositories for each NPM package
- **Build Files**: Generates BUILD files with appropriate targets and visibility rules
- **Helper Macros**: Creates utility functions like `npm_link_all_packages` for easier consumption

## Workflow Steps

1. **Initialization**: Parse configuration and validate inputs
2. **Lock File Processing**: Ensure pnpm-lock.yaml exists (bootstrap if needed)
3. **Dependency Analysis**: Extract importers (workspace projects) and packages
4. **Transitive Resolution**: Build complete dependency graph with cycle detection
5. **Repository Generation**: Create Bazel external repositories and build files
6. **Post-processing**: Apply patches, run lifecycle hooks, handle custom post-installs

## Generated Outputs

### `repositories.bzl`
Contains the `npm_repositories()` macro that creates all the individual `npm_import` repository rules.

### `defs.bzl`
Provides helper macros like:
- `npm_link_all_packages()`: Links all dependencies into a target's node_modules
- Package-specific linking functions

### BUILD Files
Create targets for packages listed in `package.json` dependencies, allowing direct reference without version specification.

## Key Benefits

- **Hermeticity**: All dependencies are fetched and cached by Bazel
- **Reproducibility**: Lock files ensure consistent dependency versions
- **Performance**: Bazel's caching and parallelization speed up builds
- **Integration**: Seamless integration with other Bazel rules and toolchains

## Configuration Options

- **Dependency Filtering**: Control which dependencies are included (prod/dev/optional)
- **Patches**: Apply patches to specific packages
- **Lifecycle Hooks**: Run package-specific install scripts
- **Custom Post-installs**: Execute custom commands after package installation
- **Package Replacement**: Substitute packages with custom implementations