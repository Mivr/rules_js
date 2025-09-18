# npm_translate_lock: Technical Implementation Details

## 🔧 Core Implementation Architecture

### Repository Rule Structure
```python
npm_translate_lock_rule = repository_rule(
    implementation = _npm_translate_lock_impl,
    attrs = _ATTRS,  # 30+ configuration attributes
)
```

**Why a repository rule:**
- Executes during Bazel's loading phase
- Has network access for downloading packages
- Can generate files in external workspace
- Cached based on inputs (lock file, config)

---

## 📊 Phase 1: State Management & Initialization

### Internal State Structure
```python
# npm_translate_lock_state.bzl
def new(rctx_name, rctx, attr, bzlmod):
    """Creates internal state object with all processing context"""
    
    priv = {
        "rctx_name": rctx_name,
        "should_update_pnpm_lock": _should_update_pnpm_lock(attr),
        "external_repository_action_cache": None,
        "label_store": None,  # File path management
        "importers": {},      # Workspace projects
        "packages": {},       # Third-party packages
        "root_package": attr.root_package,
        "npm_registries": {}, # Registry configurations
        "npm_auth": {},       # Authentication tokens
    }
```

### Lock File Detection Logic
```python
def _npm_translate_lock_impl(rctx):
    # Check for pnpm lock file
    if not rctx.attr.pnpm_lock:
        # Bootstrap path: convert npm/yarn lock or create new
        _bootstrap_import(rctx, state)
    
    # Watch lock file for changes (Bazel 6+)
    if rctx.attr.pnpm_lock and hasattr(rctx, "watch"):
        rctx.watch(rctx.attr.pnpm_lock)
```

**Bootstrap Implementation:**
```python
def _bootstrap_import(rctx, state):
    """Convert package-lock.json or yarn.lock to pnpm-lock.yaml"""
    
    # Determine source lock file type
    if state.npm_package_lock_label():
        # Convert from npm
        cmd = ["pnpm", "import", "--lockfile-only"]
        input_file = state.npm_package_lock_label()
    elif state.yarn_lock_label():
        # Convert from yarn  
        cmd = ["pnpm", "import", "--lockfile-only"]
        input_file = state.yarn_lock_label()
    else:
        # Generate from package.json
        cmd = ["pnpm", "install", "--lockfile-only"]
    
    # Execute pnpm command with proper environment
    result = rctx.execute(
        cmd,
        environment = environment,
        working_directory = working_directory,
        quiet = rctx.attr.quiet,
    )
```

---

## 📖 Phase 2: Lock File Parsing & Data Extraction

### YAML Parsing Implementation
```python
def _parse_pnpm_lock(rctx, pnpm_lock_path):
    """Parse pnpm-lock.yaml into structured data"""
    
    # Read YAML file
    pnpm_lock_content = rctx.read(pnpm_lock_path)
    
    # Parse using yq tool (more reliable than custom YAML parser)
    yq_toolchain = utils.get_yq_toolchain(rctx, rctx.attr.yq_toolchain_prefix)
    
    # Extract different sections of lock file
    specifiers = _extract_specifiers(rctx, yq_toolchain, pnpm_lock_path)
    dependencies = _extract_dependencies(rctx, yq_toolchain, pnpm_lock_path) 
    packages = _extract_packages(rctx, yq_toolchain, pnpm_lock_path)
    importers = _extract_importers(rctx, yq_toolchain, pnpm_lock_path)
    
    return {
        "specifiers": specifiers,
        "dependencies": dependencies,
        "packages": packages,
        "importers": importers,
    }
```

### Data Structure Transformation
```python
def _process_packages(raw_packages):
    """Convert raw YAML data into internal package format"""
    
    packages = {}
    for package_key, package_data in raw_packages.items():
        # Parse package key: "/react/18.2.0" -> name="react", version="18.2.0"
        name, version = _parse_package_key(package_key)
        
        # Extract resolution information
        resolution = package_data.get("resolution", {})
        integrity = resolution.get("integrity", "")
        tarball = resolution.get("tarball", "")
        
        # Process dependencies
        deps = package_data.get("dependencies", {})
        optional_deps = package_data.get("optionalDependencies", {})
        peer_deps = package_data.get("peerDependencies", {})
        
        packages[package_key] = {
            "name": name,
            "version": version,
            "integrity": integrity,
            "tarball": tarball,
            "dependencies": deps,
            "optional_dependencies": optional_deps,
            "peer_dependencies": peer_deps,
            "dev": package_data.get("dev", False),
            "optional": package_data.get("optional", False),
        }
    
    return packages
```

---

## 🔄 Phase 3: Transitive Closure & Dependency Resolution

### Circular Dependency Detection Algorithm
```python
def gather_transitive_closure(packages, package, no_optional, cache={}):
    """
    Iterative algorithm to build transitive closure while handling cycles.
    Uses stack-based approach since Starlark forbids recursion.
    """
    
    root_package = packages[package]
    transitive_closure = {}
    transitive_closure[root_package["name"]] = [root_package["version"]]
    
    # Stack of dependency dictionaries to process
    stack = [_get_package_info_deps(root_package, no_optional)]
    
    # Iterate with large limit to detect infinite loops
    iteration_max = 999999
    for i in range(0, iteration_max + 1):
        if not len(stack):
            break  # All dependencies processed
            
        if i == iteration_max:
            fail("gather_transitive_closure exhausted iteration limit")
        
        # Process next dependency set from stack
        deps = stack.pop()
        
        for dep_name, dep_version in deps.items():
            # Handle aliased dependencies (npm:package@version)
            if dep_version.startswith("npm:"):
                package_key = dep_version[4:]  # Remove "npm:" prefix
                dep_name, dep_version = package_key.rsplit("@", 1)
            else:
                package_key = utils.package_key(dep_name, dep_version)
            
            # Add to transitive closure
            transitive_closure[dep_name] = transitive_closure.get(dep_name, [])
            if dep_version in transitive_closure[dep_name]:
                continue  # Already processed this version
            
            transitive_closure[dep_name].append(dep_version)
            
            # Handle first-party links (don't recurse)
            if dep_version.startswith("link:"):
                continue
            
            # Use cache to avoid recomputing shared dependencies
            if package_key in cache:
                _merge_cached_closure(transitive_closure, cache[package_key])
            elif package_key in packages:
                # Add dependencies to stack for processing
                next_deps = _get_package_info_deps(packages[package_key], no_optional)
                stack.append(next_deps)
    
    return utils.sorted_map(transitive_closure)
```

### Dependency Filtering Logic
```python
def translate_to_transitive_closure(importers, packages, prod=False, dev=False, no_optional=False):
    """Apply user-specified filters to dependency resolution"""
    
    importers_deps = {}
    for import_path, lock_importer in importers.items():
        # Apply prod/dev filtering
        prod_deps = {} if dev else lock_importer.get("dependencies", {})
        dev_deps = {} if prod else lock_importer.get("dev_dependencies", {})
        opt_deps = {} if no_optional else lock_importer.get("optional_dependencies", {})
        
        # Combine filtered dependency sets
        deps = dicts.add(prod_deps, opt_deps)  # Runtime dependencies
        all_deps = dicts.add(prod_deps, dev_deps, opt_deps)  # All dependencies
        
        importers_deps[import_path] = {
            "deps": deps,      # For linking as first-party package
            "all_deps": all_deps,  # For node_modules in this workspace
        }
    
    # Build transitive closure for each package
    cache = {}
    for package_key in packages.keys():
        transitive_closure = gather_transitive_closure(
            packages, package_key, no_optional, cache
        )
        packages[package_key]["transitive_closure"] = transitive_closure
        cache[package_key] = transitive_closure
    
    return (importers_deps, packages)
```

---

## 🏗️ Phase 4: Repository Generation

### npm_import Rule Generation
```python
def _generate_npm_import_rules(packages, state):
    """Generate individual npm_import repository rules"""
    
    npm_imports = []
    for package_key, package_info in packages.items():
        # Extract package details
        name = package_info["name"]
        version = package_info["version"]
        integrity = package_info.get("integrity", "")
        
        # Build dependency list
        deps = []
        for dep_name, dep_versions in package_info["transitive_closure"].items():
            if dep_name == name:
                continue  # Don't depend on self
            
            for dep_version in dep_versions:
                dep_repo_name = utils.npm_import_repository_name(dep_name, dep_version)
                deps.append(f'"{dep_repo_name}//:pkg"')
        
        # Generate npm_import rule
        npm_import_rule = f'''npm_import(
    name = "{utils.npm_import_repository_name(name, version)}",
    package = "{name}",
    version = "{version}",
    integrity = "{integrity}",
    deps = [{", ".join(deps)}],
    transitive_closure = {package_info["transitive_closure"]},
    npm_auth = {state.npm_auth()},
    npm_registries = {state.npm_registries()},
)'''
        
        npm_imports.append(npm_import_rule)
    
    return npm_imports
```

### repositories.bzl Generation
```python
def _generate_repositories_bzl(npm_imports, state):
    """Generate the repositories.bzl file with npm_repositories macro"""
    
    content = [
        '"""Generated npm dependencies"""',
        '',
        'load("@aspect_rules_js//npm:npm_import.bzl", "npm_import")',
        '',
        'def npm_repositories():',
        '    """Macro to create all npm_import repository rules"""',
    ]
    
    # Add each npm_import rule with proper indentation
    for npm_import_rule in npm_imports:
        indented_rule = "\n".join(f"    {line}" for line in npm_import_rule.split("\n"))
        content.append(indented_rule)
        content.append("")
    
    return "\n".join(content)
```

### defs.bzl Helper Generation
```python
def _generate_defs_bzl(importers, packages, state):
    """Generate helper functions for linking dependencies"""
    
    content = [
        '"""Generated helper functions for npm dependencies"""',
        '',
        'load("@aspect_rules_js//npm:npm_link_all_packages.bzl", "npm_link_all_packages")',
        '',
    ]
    
    # Generate npm_link_all_packages function
    all_packages = []
    for package_key, package_info in packages.items():
        repo_name = utils.npm_import_repository_name(package_info["name"], package_info["version"])
        all_packages.append(f'"{repo_name}//:pkg"')
    
    content.extend([
        'def npm_link_all_packages(name = "node_modules", **kwargs):',
        '    """Link all npm packages into a node_modules directory"""',
        '    npm_link_all_packages(',
        '        name = name,',
        '        imported_links = [',
    ])
    
    for package_link in all_packages:
        content.append(f'            {package_link},')
    
    content.extend([
        '        ],',
        '        **kwargs',
        '    )',
    ])
    
    # Generate individual package linking functions
    for package_key, package_info in packages.items():
        name = package_info["name"]
        version = package_info["version"]
        repo_name = utils.npm_import_repository_name(name, version)
        
        content.extend([
            f'',
            f'def npm_link_{name.replace("-", "_")}(name = "node_modules", **kwargs):',
            f'    """Link {name} package"""',
            f'    npm_link_all_packages(',
            f'        name = name,',
            f'        imported_links = ["{repo_name}//:pkg"],',
            f'        **kwargs',
            f'    )',
        ])
    
    return "\n".join(content)
```

---

## 🔧 Phase 5: Post-Processing Implementation

### Patch Application System
```python
def _apply_patches(rctx, packages, state):
    """Apply user-specified patches to packages"""
    
    for package_key, package_info in packages.items():
        package_name = package_info["name"]
        
        # Check if patches exist for this package
        if package_name not in state.patches():
            continue
        
        patch_files = state.patches()[package_name]
        for patch_file in patch_files:
            # Apply patch using system patch tool
            patch_result = rctx.execute([
                state.patch_tool(),
                "--strip=0",  # or user-specified strip level
                "--input", patch_file,
                "--directory", package_info["extracted_path"],
            ])
            
            if patch_result.return_code != 0:
                fail(f"Failed to apply patch {patch_file} to {package_name}: {patch_result.stderr}")
```

### Lifecycle Hook Execution
```python
def _run_lifecycle_hooks(rctx, packages, state):
    """Execute package-specific lifecycle hooks"""
    
    for package_key, package_info in packages.items():
        package_name = package_info["name"]
        
        # Check if lifecycle hooks are configured
        if package_name not in state.lifecycle_hooks():
            continue
        
        hooks = state.lifecycle_hooks()[package_name]
        for hook_name in hooks:
            # Set up environment for hook execution
            env = dict(state.lifecycle_hooks_envs().get(package_name, {}))
            env.update({
                "npm_package_name": package_name,
                "npm_package_version": package_info["version"],
                "npm_package_path": package_info["extracted_path"],
            })
            
            # Execute hook with sandboxing
            hook_result = rctx.execute(
                [hook_name],
                environment = env,
                working_directory = package_info["extracted_path"],
                execution_requirements = state.lifecycle_hooks_execution_requirements().get(package_name, {}),
            )
            
            if hook_result.return_code != 0:
                fail(f"Lifecycle hook {hook_name} failed for {package_name}: {hook_result.stderr}")
```

---

## 📊 Performance Optimizations

### Caching Strategy
```python
# External repository action cache
def _init_external_repository_action_cache(priv, attr):
    """Set up caching for expensive operations"""
    
    if attr.external_repository_action_cache:
        priv["external_repository_action_cache"] = attr.external_repository_action_cache
    else:
        # Default cache location
        priv["external_repository_action_cache"] = "~/.cache/bazel/rules_js"

# Transitive closure caching
cache = {}  # Shared across all packages
for package_key in packages.keys():
    if package_key in cache:
        # Reuse previously computed transitive closure
        packages[package_key]["transitive_closure"] = cache[package_key]
    else:
        # Compute and cache
        transitive_closure = gather_transitive_closure(packages, package_key, no_optional, cache)
        packages[package_key]["transitive_closure"] = transitive_closure
        cache[package_key] = transitive_closure
```

### Parallel Processing
```python
# Bazel automatically parallelizes npm_import repository rules
# Each package gets its own repository rule that can execute in parallel

def npm_repositories():
    # These all execute in parallel during repository loading
    npm_import(name = "npm__react__18.2.0", ...)
    npm_import(name = "npm__lodash__4.17.21", ...)
    npm_import(name = "npm__typescript__4.9.5", ...)
    # ... hundreds more
```

---

## 🔍 Error Handling & Validation

### Input Validation
```python
def _validate_attrs(attr, is_windows):
    """Validate all input attributes"""
    
    # Ensure only one lock file type is specified
    lock_file_count = sum([
        1 if attr.pnpm_lock else 0,
        1 if attr.npm_package_lock else 0, 
        1 if attr.yarn_lock else 0,
    ])
    
    if lock_file_count > 1:
        fail("Only one of pnpm_lock, npm_package_lock, or yarn_lock may be specified")
    
    # Validate patch files exist
    for package_name, patch_files in attr.patches.items():
        for patch_file in patch_files:
            if not rctx.path(patch_file).exists:
                fail(f"Patch file {patch_file} for package {package_name} does not exist")
```

### Progress Reporting
```python
def _npm_translate_lock_impl(rctx):
    rctx.report_progress("Initializing")
    # ... initialization code ...
    
    rctx.report_progress(f"Translating {state.label_store.relative_path('pnpm_lock')}")
    # ... translation code ...
    
    rctx.report_progress("Generating starlark for npm dependencies") 
    # ... generation code ...
```

This technical implementation shows how `npm_translate_lock` handles the complex task of bridging two very different dependency management systems while maintaining performance, reliability, and ease of use.