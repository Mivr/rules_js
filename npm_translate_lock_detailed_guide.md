# npm_translate_lock: Complete Step-by-Step Guide

## 🎯 Overview
`npm_translate_lock` is the bridge between the NPM ecosystem and Bazel's hermetic build system. This guide explains every step in detail, including why each step is necessary and what problems it solves.

---

## 📋 Phase 1: Input Processing & Normalization

### 🔒 Step 1A: Lock File Input Processing
**What it does:** Accepts various package manager lock file formats
**Why it's needed:** Different teams use different package managers (npm, yarn, pnpm), but we need consistent processing

#### Input Types:
- **`pnpm-lock.yaml`** (Preferred)
  - **Why preferred:** Most comprehensive format with detailed resolution info
  - **Contains:** Exact versions, integrity hashes, peer dependency info, resolution strategy
  - **Example structure:**
    ```yaml
    lockfileVersion: 5.4
    specifiers:
      react: ^18.0.0
    dependencies:
      react: 18.2.0
    packages:
      /react/18.2.0:
        resolution: {integrity: sha512-...}
        dependencies:
          loose-envify: 1.4.0
    ```

- **`package-lock.json`** (NPM format)
  - **Why conversion needed:** NPM's lock format is less detailed about resolution strategy
  - **Problem it solves:** Teams using `npm install` can still use rules_js
  - **Conversion process:** Uses `pnpm import` to preserve exact versions while gaining pnpm's resolution benefits

- **`yarn.lock`** (Yarn format)
  - **Why conversion needed:** Yarn uses a different resolution algorithm
  - **Problem it solves:** Teams using Yarn can migrate to Bazel without changing their dependency versions
  - **Conversion process:** `pnpm import` maintains version compatibility

### 🔄 Step 1B: Lock File Normalization
**What it does:** Converts all lock file formats to pnpm format
**Why it's critical:** 
- Unified processing pipeline regardless of input format
- pnpm's format contains the most detailed dependency resolution information
- Enables consistent handling of complex dependency scenarios

**Technical details:**
```bash
# For npm users:
pnpm import --lockfile-only
# Converts package-lock.json → pnpm-lock.yaml

# For yarn users:  
pnpm import --lockfile-only
# Converts yarn.lock → pnpm-lock.yaml
```

### ⚙️ Step 1C: Configuration Processing
**What it does:** Processes additional configuration files
**Why it's needed:** Customize behavior for enterprise environments, authentication, and package modifications

#### Configuration Files:

- **`package.json`**
  - **Purpose:** Defines root dependencies and workspace structure
  - **Why needed:** Determines which packages to create BUILD targets for
  - **Used for:** Workspace detection, dependency categorization (prod/dev/optional)

- **`.npmrc`**
  - **Purpose:** NPM registry configuration and authentication
  - **Why critical:** Enterprise environments often use private registries
  - **Contains:** Registry URLs, auth tokens, proxy settings, scoped package configs
  - **Example:**
    ```
    registry=https://registry.npmjs.org/
    @mycompany:registry=https://npm.mycompany.com/
    //npm.mycompany.com/:_authToken=${NPM_TOKEN}
    ```

- **`patches/`**
  - **Purpose:** Fix third-party packages without forking
  - **Why essential:** Many npm packages have bugs or incompatibilities with Bazel
  - **Common use cases:** Fix build scripts, remove problematic dependencies, add missing files
  - **Applied:** During repository generation phase

- **`lifecycle_hooks`**
  - **Purpose:** Run package-specific install scripts
  - **Why needed:** Many packages require post-install compilation (native modules, code generation)
  - **Examples:** node-gyp builds, TypeScript compilation, asset processing

---

## 🚀 Phase 2: Initialization & Bootstrap

### 🎯 Step 2A: Rule Initialization
**What it does:** Entry point for the npm_translate_lock repository rule
**Why it's a repository rule:** Needs to download external dependencies and generate files during Bazel's loading phase

**Technical implementation:**
```python
def _npm_translate_lock_impl(rctx):
    # rctx = repository context
    # Has access to network for downloading
    # Can generate files in external repository
```

### 🚀 Step 2B: State Initialization
**What it does:** Creates internal data structures and validates configuration
**Why necessary:** 
- Validates all input files exist and are readable
- Sets up internal state for processing
- Prepares error handling and progress reporting

**Key validations:**
- Lock file format is supported
- Configuration files are valid
- Network access is available for downloads
- Required tools (pnpm, node) are available

### ❓ Step 2C: Lock File Existence Check
**What it does:** Determines if pnpm-lock.yaml already exists
**Why it's a decision point:** Different processing paths based on availability

**Decision logic:**
- If `pnpm-lock.yaml` exists → Parse directly
- If only `package-lock.json` or `yarn.lock` exists → Bootstrap conversion
- If no lock file exists → Generate from package.json

### 🔧 Step 2D: Bootstrap Process (When Needed)
**What it does:** Converts existing lock files or generates new ones
**Why critical:** Ensures we always have a pnpm-lock.yaml to work with

**Bootstrap scenarios:**
1. **NPM to pnpm conversion:**
   ```bash
   pnpm import --lockfile-only
   # Reads package-lock.json, writes pnpm-lock.yaml
   ```

2. **Yarn to pnpm conversion:**
   ```bash
   pnpm import --lockfile-only  
   # Reads yarn.lock, writes pnpm-lock.yaml
   ```

3. **Fresh installation:**
   ```bash
   pnpm install --lockfile-only
   # Reads package.json, writes pnpm-lock.yaml
   ```

---

## 📖 Phase 3: Lock File Parsing & Data Extraction

### 📖 Step 3A: Parse Lock File
**What it does:** Parses YAML structure into internal data structures
**Why needed:** Convert text format into structured data for processing

**Key data extracted:**
- **Specifiers:** What versions were requested in package.json
- **Dependencies:** What versions were actually resolved
- **Packages:** Detailed info about each package version
- **Importers:** Workspace projects and their dependencies

**Example data structure:**
```python
{
    "specifiers": {"react": "^18.0.0"},
    "dependencies": {"react": "18.2.0"},
    "packages": {
        "/react/18.2.0": {
            "resolution": {"integrity": "sha512-..."},
            "dependencies": {"loose-envify": "1.4.0"}
        }
    }
}
```

### 🔍 Step 3B: Extract Importers & Packages
**What it does:** Separates workspace projects from third-party packages
**Why necessary:** Different handling for first-party vs third-party code

**Importers (Workspace Projects):**
- Root project and any workspace packages
- Have different dependency linking rules
- Can have `file:` or `link:` dependencies to each other

**Packages (Third-party Dependencies):**
- Downloaded from npm registries
- Need integrity verification
- May require patches or lifecycle hooks

---

## 🔄 Phase 4: Dependency Resolution & Transitive Closure

### 📊 Step 4A: Gather Dependencies
**What it does:** Collects all direct dependencies from each package
**Why comprehensive collection needed:** Must include all dependency types for complete resolution

**Dependency types collected:**
- **dependencies:** Runtime dependencies (always included)
- **devDependencies:** Development-time dependencies (optional)
- **optionalDependencies:** Optional runtime dependencies (optional)
- **peerDependencies:** Dependencies provided by parent (handled specially)

### 🔗 Step 4B: Resolve Circular Dependencies (CRITICAL STEP)
**What it does:** Breaks circular dependency cycles that are common in NPM
**Why absolutely critical:** Bazel requires a Directed Acyclic Graph (DAG), but NPM allows cycles

**The Problem:**
```
Package A depends on Package B
Package B depends on Package A
```
This creates a cycle that Bazel cannot handle.

**The Solution:**
Uses a sophisticated algorithm to break cycles while preserving functionality:

1. **Detection:** Identifies all cycles in the dependency graph
2. **Analysis:** Determines which dependencies in cycles are actually needed at build time
3. **Breaking:** Creates a "transitive closure" that includes all dependencies but breaks the cycles
4. **Verification:** Ensures all packages still have access to their required dependencies

**Technical Implementation:**
```python
def gather_transitive_closure(packages, package, no_optional, cache={}):
    # Uses iterative approach (not recursive) to avoid stack overflow
    # Maintains a stack of packages to process
    # Builds complete transitive closure while detecting cycles
    # Uses caching to avoid recomputing for shared dependencies
```

**Example cycle breaking:**
```
Before: A → B → C → A (cycle!)
After:  A gets transitive closure: [A, B, C]
        B gets transitive closure: [B, C, A]  
        C gets transitive closure: [C, A, B]
```

### 🎛️ Step 4C: Apply Dependency Filters
**What it does:** Filters dependencies based on user configuration
**Why needed:** Users often want to exclude certain dependency types

**Filter options:**
- **`prod = True`:** Only production dependencies (excludes devDependencies)
- **`dev = True`:** Only development dependencies (excludes dependencies)
- **`no_optional = True`:** Excludes optionalDependencies
- **Combined filters:** Can combine multiple filters

**Use cases:**
- Production builds: Only include runtime dependencies
- Development builds: Include dev tools and testing frameworks
- Minimal builds: Exclude optional dependencies to reduce size

### 🕸️ Step 4D: Build Final Dependency Graph
**What it does:** Creates the final dependency graph with resolved versions
**Why it's the foundation:** This graph determines what gets downloaded and how packages are linked

**Graph properties:**
- **Acyclic:** No circular dependencies (cycles broken in previous step)
- **Complete:** Includes all transitive dependencies
- **Versioned:** Each node represents a specific package version
- **Linked:** Edges represent dependency relationships

---

## 🏗️ Phase 5: Bazel Repository Generation

### 🏗️ Step 5A: Generate Repository Files
**What it does:** Orchestrates the creation of all Bazel integration files
**Why it's the integration layer:** Converts npm concepts into Bazel concepts

### 📦 Step 5B: Create npm_import Rules
**What it does:** Generates individual Bazel repository rules for each npm package
**Why each package is separate:** Enables fine-grained caching and parallel downloads

**Generated for each package:**
```python
npm_import(
    name = "npm__react__18.2.0",
    package = "react",
    version = "18.2.0",
    integrity = "sha512-...",
    deps = ["@npm__loose_envify__1.4.0//:pkg"],
    transitive_closure = {...},
)
```

**Benefits of individual repositories:**
- **Parallel downloads:** Bazel can download packages in parallel
- **Incremental updates:** Only changed packages need re-downloading
- **Fine-grained caching:** Each package cached independently
- **Hermeticity:** Each package isolated with exact dependencies

### 📜 Step 5C: Generate repositories.bzl
**What it does:** Creates a macro that instantiates all npm_import rules
**Why a single macro:** Provides a simple API for users to set up all dependencies

**Generated macro:**
```python
def npm_repositories():
    npm_import(name = "npm__react__18.2.0", ...)
    npm_import(name = "npm__lodash__4.17.21", ...)
    # ... hundreds more packages
```

**User consumption:**
```python
load("@npm//:repositories.bzl", "npm_repositories")
npm_repositories()  # Sets up all dependencies
```

### 🛠️ Step 5D: Generate defs.bzl
**What it does:** Creates helper functions for easier dependency consumption
**Why helper functions needed:** Raw npm_import repositories are hard to use directly

**Key helper functions:**

1. **`npm_link_all_packages()`**
   - Links all dependencies into a target's node_modules
   - Handles complex linking scenarios
   - Manages peer dependencies

2. **Package-specific functions:**
   - `npm_link_react()` - Links just React
   - `npm_link_lodash()` - Links just Lodash
   - Allows fine-grained dependency control

**Example usage:**
```python
js_library(
    name = "my_lib",
    srcs = ["index.js"],
    deps = [":node_modules"],
)

npm_link_all_packages(
    name = "node_modules",
    imported_links = [
        "@npm__react__18.2.0//:pkg",
        "@npm__lodash__4.17.21//:pkg",
    ],
)
```

### 🏢 Step 5E: Create BUILD Files
**What it does:** Creates BUILD files with convenient target names
**Why convenient names needed:** Users shouldn't need to know exact versions

**Generated targets:**
```python
# BUILD file in npm repository
alias(
    name = "react",
    actual = "@npm__react__18.2.0//:pkg",
    visibility = ["//visibility:public"],
)

alias(
    name = "lodash", 
    actual = "@npm__lodash__4.17.21//:pkg",
    visibility = ["//visibility:public"],
)
```

**User benefit:**
```python
# User can reference by name, not version
js_library(
    name = "my_app",
    deps = ["@npm//:react", "@npm//:lodash"],
)
```

---

## 🔧 Phase 6: Post-Processing & Customization

### 🩹 Step 6A: Apply Patches
**What it does:** Modifies third-party packages after download
**Why essential:** Many npm packages have issues that need fixing

**Common patch scenarios:**
1. **Fix build scripts:** Remove incompatible build steps
2. **Add missing files:** Some packages forget to include necessary files
3. **Remove problematic dependencies:** Strip out dependencies that cause issues
4. **Bazel compatibility:** Modify packages to work better with Bazel

**Patch application process:**
1. Download original package
2. Apply patch files using `patch` command
3. Verify patch applied successfully
4. Package modified version for use

**Example patch:**
```diff
--- a/package.json
+++ b/package.json
@@ -10,7 +10,6 @@
   "dependencies": {
     "some-dependency": "^1.0.0"
-    "problematic-dependency": "^2.0.0"
   }
```

### ⚡ Step 6B: Run Lifecycle Hooks
**What it does:** Executes package-specific install scripts
**Why many packages need this:** Native modules, code generation, asset compilation

**Common lifecycle hook scenarios:**
1. **Native module compilation:**
   - Packages with C/C++ code need compilation
   - Uses node-gyp or similar tools
   - Example: `node-sass`, `sqlite3`, `sharp`

2. **Code generation:**
   - Generate code from schemas or templates
   - Example: Protocol buffer compilers, GraphQL code generators

3. **Asset processing:**
   - Compile stylesheets, optimize images
   - Example: CSS preprocessors, image optimization tools

**Hook execution environment:**
- Sandboxed execution with controlled environment variables
- Access to node toolchain and build tools
- Proper error handling and logging

### 🔧 Step 6C: Handle Custom Post-installs
**What it does:** Runs user-defined commands for specific packages
**Why needed:** Some packages need special setup that's not covered by standard lifecycle hooks

**Use cases:**
- Custom configuration file generation
- Special environment setup
- Integration with enterprise tools
- Package-specific optimizations

**Configuration example:**
```python
npm_translate_lock(
    custom_postinstalls = {
        "my-special-package": "echo 'Setting up special package' && ./setup.sh",
        "enterprise-tool": "configure-for-bazel.py",
    }
)
```

---

## ✅ Phase 7: Final Integration & Output

### ✅ Step 7A: Bazel External Repositories
**What it creates:** Complete set of Bazel external repositories for all npm packages
**Why this is the goal:** Transforms npm packages into native Bazel dependencies

**Repository structure for each package:**
```
@npm__react__18.2.0/
├── BUILD.bazel          # Bazel build file
├── pkg/                 # Package contents
│   ├── index.js        # Main package files
│   ├── package.json    # Package metadata
│   └── ...             # Other package files
└── node_modules/       # Linked dependencies
    └── ...
```

**Key properties:**
- **Hermetic:** Each repository is self-contained
- **Cached:** Bazel caches repositories across builds
- **Versioned:** Each version gets its own repository
- **Linked:** Dependencies properly linked via node_modules

### 🎯 Step 7B: Ready for Build
**What this means:** npm packages can now be used in Bazel build rules
**Why this is powerful:** Full integration with Bazel's build system

**Available integrations:**
- **js_library:** Create JavaScript libraries
- **js_binary:** Create executable JavaScript applications  
- **js_test:** Run JavaScript tests
- **ts_library:** TypeScript compilation with dependencies
- **webpack_bundle:** Bundle applications with all dependencies

### 🚀 Step 7C: Build Target Integration
**What users can now do:** Build JavaScript applications with full dependency management
**Why this completes the circle:** From npm packages to production builds

**Example complete build:**
```python
# Load the generated repositories
load("@npm//:repositories.bzl", "npm_repositories")
npm_repositories()

# Load helper functions
load("@npm//:defs.bzl", "npm_link_all_packages")

# Create a JavaScript application
js_binary(
    name = "my_app",
    entry_point = "src/main.js",
    deps = [":node_modules"],
)

# Link all npm dependencies
npm_link_all_packages(
    name = "node_modules",
)
```

**Final result:**
- Fast, incremental builds
- Hermetic dependency management
- Parallel execution
- Reliable caching
- Full integration with Bazel ecosystem

---

## 🎯 Summary: Why Each Step Matters

1. **Input Processing:** Handles diversity of package manager ecosystems
2. **Normalization:** Creates consistent processing pipeline
3. **Bootstrap:** Ensures we always have complete dependency information
4. **Parsing:** Converts text formats to structured data
5. **Dependency Resolution:** Solves the complex problem of npm's circular dependencies
6. **Repository Generation:** Bridges npm and Bazel ecosystems
7. **Post-processing:** Handles real-world package complexities
8. **Integration:** Provides seamless developer experience

The entire process transforms the chaotic, circular world of npm dependencies into Bazel's ordered, hermetic, and cacheable build system while preserving all the functionality developers expect.