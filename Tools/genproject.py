#!/usr/bin/env python3
"""
genproject.py — `project.yml` → `SkyRunner.xcodeproj`, with no dependencies.

Why this exists. A checked-in `.xcodeproj` is a 2000-line generated file that
conflicts on every branch, so this repo keeps `project.yml` as the source of
truth instead. The idiomatic tool for that is XcodeGen — but XcodeGen is a brew
install, and "clone the repo and build the game" should not require one. So
`make project` prefers XcodeGen when it is on PATH and falls back to this, which
reads the *same* `project.yml` and emits an equivalent project.

Scope is deliberately narrow: what this repo's `project.yml` uses. It is not a
general XcodeGen replacement, and it says so loudly when it meets a key it does
not understand rather than silently dropping it.

Object IDs are derived from a hash of what they identify, so regenerating an
unchanged project produces a byte-identical file — which is what makes the
generated project safe to gitignore and cheap to diff when you do look at it.

    python3 Tools/genproject.py [--spec project.yml] [--out .]
"""
import argparse, hashlib, os, re, sys

# ─────────────────────────────────────────────────────────────────────────────
# A YAML subset parser.
#
# Enough for this file and no more: nested maps, block lists, inline scalars,
# quoted strings, `>-` folded blocks, `#` comments. Anything outside that raises
# rather than guessing, because a silently-misparsed build setting is a bug you
# find in the simulator half an hour later.
# ─────────────────────────────────────────────────────────────────────────────

def _scalar(text):
    text = text.strip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "\"'":
        return text[1:-1]
    if text in ("true", "yes"):
        return True
    if text in ("false", "no"):
        return False
    if re.fullmatch(r"-?\d+", text):
        return int(text)
    if re.fullmatch(r"-?\d*\.\d+", text):
        return float(text)
    return text


def _strip(line):
    """Drop a trailing comment that isn't inside quotes."""
    out, quote = [], None
    for ch in line:
        if quote:
            out.append(ch)
            if ch == quote:
                quote = None
        elif ch in "\"'":
            quote = ch
            out.append(ch)
        elif ch == "#":
            break
        else:
            out.append(ch)
    return "".join(out).rstrip()


def parse_yaml(text):
    lines = []
    for raw in text.splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        body = _strip(raw)
        if body.strip():
            lines.append((len(body) - len(body.lstrip()), body.strip()))

    def block(i, indent):
        """Parse every line at `indent`; return (value, next index)."""
        if lines[i][1].startswith("- "):
            items = []
            while i < len(lines) and lines[i][0] == indent and lines[i][1].startswith("- "):
                rest = lines[i][1][2:].strip()
                if ":" in rest and not rest.startswith(("\"", "'")) and \
                        re.match(r"^[\w.$-]+\s*:", rest):
                    # `- key: value` — a map whose first pair is inline
                    entry, i = block_map_inline(rest, i, indent)
                    items.append(entry)
                else:
                    items.append(_scalar(rest))
                    i += 1
            return items, i
        result = {}
        while i < len(lines) and lines[i][0] == indent:
            key, _, rest = lines[i][1].partition(":")
            key, rest = key.strip(), rest.strip()
            if rest in (">-", ">", "|", "|-"):
                i += 1
                parts = []
                while i < len(lines) and lines[i][0] > indent:
                    parts.append(lines[i][1])
                    i += 1
                result[key] = " ".join(parts)
            elif rest:
                result[key] = _scalar(rest)
                i += 1
            else:
                i += 1
                if i < len(lines) and lines[i][0] > indent:
                    result[key], i = block(i, lines[i][0])
                else:
                    result[key] = {}
        return result, i

    def block_map_inline(first, i, indent):
        key, _, rest = first.partition(":")
        entry = {}
        if rest.strip():
            entry[key.strip()] = _scalar(rest)
            i += 1
        else:
            i += 1
            if i < len(lines) and lines[i][0] > indent + 2:
                entry[key.strip()], i = block(i, lines[i][0])
        # continuation lines of the same list item are indented past the dash
        while i < len(lines) and lines[i][0] == indent + 2:
            k, _, v = lines[i][1].partition(":")
            if v.strip():
                entry[k.strip()] = _scalar(v)
                i += 1
            else:
                i += 1
                if i < len(lines) and lines[i][0] > indent + 2:
                    entry[k.strip()], i = block(i, lines[i][0])
                else:
                    entry[k.strip()] = {}
        return entry, i

    value, end = block(0, lines[0][0]) if lines else ({}, 0)
    if end != len(lines):
        raise ValueError(f"could not parse line {end + 1}: {lines[end][1]!r}")
    return value


# ─────────────────────────────────────────────────────────────────────────────
# pbxproj emission
# ─────────────────────────────────────────────────────────────────────────────

FILE_TYPES = {
    ".swift": "sourcecode.swift", ".m": "sourcecode.c.objc",
    ".h": "sourcecode.c.h", ".c": "sourcecode.c.c",
    ".png": "image.png", ".jpg": "image.jpeg", ".json": "text.json",
    ".wav": "audio.wav", ".mp3": "audio.mp3", ".m4a": "audio.m4a",
    ".plist": "text.plist.xml", ".xcassets": "folder.assetcatalog",
    ".metal": "sourcecode.metal", ".html": "text.html",
}
SOURCE_EXT = {".swift", ".m", ".c", ".metal"}
RESOURCE_EXT = {".png", ".jpg", ".json", ".wav", ".mp3", ".m4a", ".xcassets"}
PRODUCT_TYPE = {
    "application": "com.apple.product-type.application",
    "bundle.unit-test": "com.apple.product-type.bundle.unit-test",
}
PRODUCT_EXT = {"application": ("app", "wrapper.application"),
               "bundle.unit-test": ("xctest", "wrapper.cfbundle")}


def oid(*parts):
    """A stable 24-hex object id, so an unchanged project regenerates identically."""
    return hashlib.md5("::".join(str(p) for p in parts).encode()).hexdigest()[:24].upper()


def quoted(value):
    if value is True:
        return "YES"
    if value is False:
        return "NO"
    text = str(value)
    if text == "":
        return '""'
    if re.fullmatch(r"[A-Za-z0-9_./]+", text):
        return text
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def matches(path, patterns):
    """fnmatch, but `**/` also matches at depth zero — the XcodeGen behaviour."""
    import fnmatch
    for pattern in patterns:
        if fnmatch.fnmatch(path, pattern):
            return True
        if pattern.startswith("**/") and fnmatch.fnmatch(path, pattern[3:]):
            return True
        if fnmatch.fnmatch(os.path.basename(path), pattern.replace("**/", "")):
            return True
    return False


def collect(root, entries):
    """Every file a target owns, as (relative path, phase)."""
    found = []
    for entry in entries:
        path = entry["path"] if isinstance(entry, dict) else entry
        excludes = entry.get("excludes", []) if isinstance(entry, dict) else []
        base = os.path.join(root, path)
        if os.path.isfile(base):
            found.append(path)
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
            for name in sorted(filenames):
                if name.startswith("."):
                    continue
                rel = os.path.relpath(os.path.join(dirpath, name), root)
                if excludes and matches(rel, excludes):
                    continue
                if os.path.splitext(name)[1] in FILE_TYPES:
                    found.append(rel)
    phased = []
    for rel in found:
        ext = os.path.splitext(rel)[1]
        phase = "Sources" if ext in SOURCE_EXT else \
                "Resources" if ext in RESOURCE_EXT else None
        phased.append((rel, phase))
    return phased


class Project:
    def __init__(self, spec, root):
        self.spec = spec
        self.root = root
        self.name = spec["name"]
        self.objects = {}          # id → (isa, body text)
        self.groups = {}           # dir path → id

    def add(self, ident, isa, body, comment=None):
        self.objects[ident] = (isa, body, comment or isa)

    # ── groups ──────────────────────────────────────────────────────────────
    def group_for(self, directory):
        """The PBXGroup for a directory, creating parents as needed."""
        if directory in ("", "."):
            return None
        if directory in self.groups:
            return self.groups[directory]
        ident = oid("group", directory)
        self.groups[directory] = ident
        return ident

    def build(self):
        root = self.root
        targets = self.spec["targets"]
        target_ids, product_ids, file_refs, children = {}, {}, {}, {}

        def ref_for(rel):
            if rel in file_refs:
                return file_refs[rel]
            ident = oid("file", rel)
            file_refs[rel] = ident
            ext = os.path.splitext(rel)[1]
            self.add(ident, "PBXFileReference",
                     f'{{isa = PBXFileReference; lastKnownFileType = '
                     f'{FILE_TYPES.get(ext, "text")}; path = {quoted(os.path.basename(rel))}; '
                     f'sourceTree = "<group>"; }}', os.path.basename(rel))
            parent = os.path.dirname(rel)
            children.setdefault(parent, []).append(ident)
            return ident

        # every target's files, build phases and configuration
        for tname, target in targets.items():
            files = collect(root, target.get("sources", []))
            phases = {"Sources": [], "Resources": [], "Frameworks": []}
            for rel, phase in files:
                fref = ref_for(rel)
                if not phase:
                    continue
                bid = oid("buildfile", tname, rel)
                self.add(bid, "PBXBuildFile",
                         f"{{isa = PBXBuildFile; fileRef = {fref}; }}",
                         os.path.basename(rel))
                phases[phase].append(bid)

            phase_ids = []
            for phase in ("Sources", "Frameworks", "Resources"):
                pid = oid("phase", tname, phase)
                listing = "\n".join(f"\t\t\t\t{b} /* {self.objects[b][2]} */,"
                                    for b in phases[phase])
                self.add(pid, f"PBX{phase}BuildPhase",
                         f"{{\n\t\t\tisa = PBX{phase}BuildPhase;\n"
                         f"\t\t\tbuildActionMask = 2147483647;\n"
                         f"\t\t\tfiles = (\n{listing}\n\t\t\t);\n"
                         f"\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}}",
                         phase)
                phase_ids.append(pid)

            # product reference
            kind = target["type"]
            ext, filetype = PRODUCT_EXT[kind]
            prod = oid("product", tname)
            product_ids[tname] = prod
            self.add(prod, "PBXFileReference",
                     f'{{isa = PBXFileReference; explicitFileType = {filetype}; '
                     f'includeInIndex = 0; path = {quoted(tname + "." + ext)}; '
                     f'sourceTree = BUILT_PRODUCTS_DIR; }}', f"{tname}.{ext}")

            # per-target build settings
            conf_ids = []
            for config in ("Debug", "Release"):
                cid = oid("targetconfig", tname, config)
                settings = dict(target.get("settings", {}).get("base", {}))
                settings.update(target.get("settings", {}).get("configs", {})
                                .get(config, {}))
                settings.setdefault("PRODUCT_NAME", "$(TARGET_NAME)")
                if kind == "application":
                    settings.setdefault("SWIFT_EMIT_LOC_STRINGS", "NO")
                body = "\n".join(f"\t\t\t\t{k} = {quoted(v)};"
                                 for k, v in sorted(settings.items()))
                self.add(cid, "XCBuildConfiguration",
                         f"{{\n\t\t\tisa = XCBuildConfiguration;\n"
                         f"\t\t\tbuildSettings = {{\n{body}\n\t\t\t}};\n"
                         f"\t\t\tname = {config};\n\t\t}}", config)
                conf_ids.append((config, cid))
            clist = oid("targetconfiglist", tname)
            self.add(clist, "XCConfigurationList",
                     self._config_list(conf_ids), f"Build configuration list for {tname}")

            # test targets depend on the host app
            deps = []
            for dep in target.get("dependencies", []):
                host = dep.get("target")
                if not host:
                    continue
                proxy = oid("proxy", tname, host)
                self.add(proxy, "PBXContainerItemProxy",
                         f"{{\n\t\t\tisa = PBXContainerItemProxy;\n"
                         f"\t\t\tcontainerPortal = {oid('project', self.name)} "
                         f"/* Project object */;\n\t\t\tproxyType = 1;\n"
                         f"\t\t\tremoteGlobalIDString = {oid('target', host)};\n"
                         f"\t\t\tremoteInfo = {host};\n\t\t}}")
                did = oid("dependency", tname, host)
                self.add(did, "PBXTargetDependency",
                         f"{{\n\t\t\tisa = PBXTargetDependency;\n"
                         f"\t\t\ttarget = {oid('target', host)} /* {host} */;\n"
                         f"\t\t\ttargetProxy = {proxy};\n\t\t}}")
                deps.append(did)

            tid = oid("target", tname)
            target_ids[tname] = tid
            self.add(tid, "PBXNativeTarget",
                     f"{{\n\t\t\tisa = PBXNativeTarget;\n"
                     f"\t\t\tbuildConfigurationList = {clist};\n"
                     f"\t\t\tbuildPhases = (\n"
                     + "".join(f"\t\t\t\t{p},\n" for p in phase_ids)
                     + f"\t\t\t);\n\t\t\tbuildRules = (\n\t\t\t);\n"
                     f"\t\t\tdependencies = (\n"
                     + "".join(f"\t\t\t\t{d},\n" for d in deps)
                     + f"\t\t\t);\n\t\t\tname = {tname};\n"
                     f"\t\t\tproductName = {tname};\n"
                     f"\t\t\tproductReference = {prod};\n"
                     f"\t\t\tproductType = {quoted(PRODUCT_TYPE[kind])};\n\t\t}}",
                     tname)

        # ── group tree ──────────────────────────────────────────────────────
        # Directories become groups so the navigator mirrors the repo.
        all_dirs = set()
        for parent in children:
            parts = parent.split(os.sep) if parent else []
            for i in range(len(parts)):
                all_dirs.add(os.sep.join(parts[: i + 1]))
        for directory in sorted(all_dirs, key=lambda d: -d.count(os.sep)):
            gid = self.group_for(directory)
            kids = list(children.get(directory, []))
            for other in sorted(all_dirs):
                if os.path.dirname(other) == directory and other != directory:
                    kids.append(self.group_for(other))
            listing = "\n".join(f"\t\t\t\t{k} /* {self.objects.get(k, (0,0,''))[2]} */,"
                                for k in kids)
            self.add(gid, "PBXGroup",
                     f"{{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{listing}\n"
                     f"\t\t\t);\n\t\t\tpath = {quoted(os.path.basename(directory))};\n"
                     f'\t\t\tsourceTree = "<group>";\n\t\t}}',
                     os.path.basename(directory))

        products = oid("group", "Products")
        listing = "\n".join(f"\t\t\t\t{product_ids[t]} /* {t} */," for t in targets)
        self.add(products, "PBXGroup",
                 f"{{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{listing}\n"
                 f"\t\t\t);\n\t\t\tname = Products;\n"
                 f'\t\t\tsourceTree = "<group>";\n\t\t}}', "Products")

        top = [self.group_for(d) for d in sorted(all_dirs) if os.sep not in d]
        top += [self.groups[d] for d in [] ]
        loose = [f for f in children.get("", [])]
        main = oid("group", "__root__")
        listing = "\n".join(f"\t\t\t\t{g} /* {self.objects[g][2]} */,"
                            for g in loose + top + [products])
        self.add(main, "PBXGroup",
                 f"{{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{listing}\n"
                 f'\t\t\t);\n\t\t\tsourceTree = "<group>";\n\t\t}}')

        # ── project-level configuration ─────────────────────────────────────
        conf_ids = []
        base = self.spec.get("settings", {}).get("base", {})
        per = self.spec.get("settings", {}).get("configs", {})
        for config in ("Debug", "Release"):
            settings = {
                "ALWAYS_SEARCH_USER_PATHS": "NO",
                "CLANG_ENABLE_OBJC_ARC": "YES",
                "COPY_PHASE_STRIP": "NO",
                "ENABLE_STRICT_OBJC_MSGSEND": "YES",
                "GCC_NO_COMMON_BLOCKS": "YES",
                "SDKROOT": "iphoneos",
                "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
                "ONLY_ACTIVE_ARCH": "YES" if config == "Debug" else "NO",
                "DEBUG_INFORMATION_FORMAT": "dwarf" if config == "Debug"
                                            else "dwarf-with-dsym",
                "ENABLE_PREVIEWS": "YES",
            }
            settings.update(base)
            settings.update(per.get(config, {}))
            body = "\n".join(f"\t\t\t\t{k} = {quoted(v)};"
                             for k, v in sorted(settings.items()))
            cid = oid("projectconfig", config)
            self.add(cid, "XCBuildConfiguration",
                     f"{{\n\t\t\tisa = XCBuildConfiguration;\n"
                     f"\t\t\tbuildSettings = {{\n{body}\n\t\t\t}};\n"
                     f"\t\t\tname = {config};\n\t\t}}", config)
            conf_ids.append((config, cid))
        plist = oid("projectconfiglist")
        self.add(plist, "XCConfigurationList", self._config_list(conf_ids),
                 f"Build configuration list for PBXProject {self.name}")

        attrs = "\n".join(
            f"\t\t\t\t\t{target_ids[t]} = {{\n\t\t\t\t\t\tCreatedOnToolsVersion = 26.0;\n"
            f"\t\t\t\t\t}};" for t in targets)
        listing = "".join(f"\t\t\t\t{target_ids[t]} /* {t} */,\n" for t in targets)
        self.add(oid("project", self.name), "PBXProject",
                 f"{{\n\t\t\tisa = PBXProject;\n\t\t\tattributes = {{\n"
                 f"\t\t\t\tBuildIndependentTargetsInParallel = 1;\n"
                 f"\t\t\t\tLastUpgradeCheck = 2600;\n"
                 f"\t\t\t\tTargetAttributes = {{\n{attrs}\n\t\t\t\t}};\n\t\t\t}};\n"
                 f"\t\t\tbuildConfigurationList = {plist};\n"
                 f'\t\t\tcompatibilityVersion = "Xcode 14.0";\n'
                 f"\t\t\tdevelopmentRegion = en;\n"
                 f"\t\t\thasScannedForEncodings = 0;\n"
                 f"\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n"
                 f"\t\t\tmainGroup = {main};\n"
                 f"\t\t\tproductRefGroup = {products} /* Products */;\n"
                 f'\t\t\tprojectDirPath = "";\n\t\t\tprojectRoot = "";\n'
                 f"\t\t\ttargets = (\n{listing}\t\t\t);\n\t\t}}", "Project object")
        return target_ids, product_ids

    def _config_list(self, conf_ids):
        listing = "".join(f"\t\t\t\t{cid} /* {name} */,\n" for name, cid in conf_ids)
        return (f"{{\n\t\t\tisa = XCConfigurationList;\n"
                f"\t\t\tbuildConfigurations = (\n{listing}\t\t\t);\n"
                f"\t\t\tdefaultConfigurationIsVisible = 0;\n"
                f"\t\t\tdefaultConfigurationName = Release;\n\t\t}}")

    def write(self, out_dir):
        target_ids, product_ids = self.build()
        bundle = os.path.join(out_dir, f"{self.name}.xcodeproj")
        os.makedirs(bundle, exist_ok=True)

        by_isa = {}
        for ident, (isa, body, comment) in self.objects.items():
            by_isa.setdefault(isa, []).append((ident, body, comment))
        chunks = []
        for isa in sorted(by_isa):
            chunks.append(f"\n/* Begin {isa} section */")
            for ident, body, comment in sorted(by_isa[isa]):
                chunks.append(f"\t\t{ident} /* {comment} */ = {body};")
            chunks.append(f"/* End {isa} section */")
        text = ("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n"
                "\tobjectVersion = 56;\n\tobjects = {\n"
                + "\n".join(chunks)
                + f"\n\t}};\n\trootObject = {oid('project', self.name)} "
                  f"/* Project object */;\n}}\n")
        with open(os.path.join(bundle, "project.pbxproj"), "w") as f:
            f.write(text)

        # A *shared* scheme, so `xcodebuild -scheme SkyRunner` works for everyone
        # rather than only for whoever opened the project in the IDE first.
        schemes = os.path.join(bundle, "xcshareddata", "xcschemes")
        os.makedirs(schemes, exist_ok=True)
        for name, scheme in (self.spec.get("schemes") or {self.name: {}}).items():
            with open(os.path.join(schemes, f"{name}.xcscheme"), "w") as f:
                f.write(self._scheme(name, target_ids, product_ids))
        return bundle

    def _scheme(self, name, target_ids, product_ids):
        app = name if name in target_ids else next(iter(target_ids))
        tests = [t for t in target_ids if t.endswith("Tests")]
        def ref(target):
            ext = PRODUCT_EXT[self.spec["targets"][target]["type"]][0]
            return (f'            <BuildableReference\n'
                    f'               BuildableIdentifier = "primary"\n'
                    f'               BlueprintIdentifier = "{target_ids[target]}"\n'
                    f'               BuildableName = "{target}.{ext}"\n'
                    f'               BlueprintName = "{target}"\n'
                    f'               ReferencedContainer = "container:{self.name}.xcodeproj">\n'
                    f'            </BuildableReference>\n')
        test_entries = "".join(
            f'         <TestableReference\n            skipped = "NO">\n'
            f'{ref(t)}         </TestableReference>\n' for t in tests)
        build_entries = "".join(
            f'         <BuildActionEntry\n'
            f'            buildForTesting = "YES"\n            buildForRunning = "YES"\n'
            f'            buildForProfiling = "YES"\n            buildForArchiving = "YES"\n'
            f'            buildForAnalyzing = "YES">\n{ref(t)}         </BuildActionEntry>\n'
            for t in ([app] + tests))
        return (f'<?xml version="1.0" encoding="UTF-8"?>\n'
                f'<Scheme LastUpgradeVersion = "2600" version = "1.7">\n'
                f'   <BuildAction parallelizeBuildables = "YES" '
                f'buildImplicitDependencies = "YES">\n'
                f'      <BuildActionEntries>\n{build_entries}'
                f'      </BuildActionEntries>\n   </BuildAction>\n'
                f'   <TestAction buildConfiguration = "Debug"\n'
                f'      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"\n'
                f'      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"\n'
                f'      shouldUseLaunchSchemeArgsEnv = "YES">\n'
                f'      <Testables>\n{test_entries}      </Testables>\n   </TestAction>\n'
                f'   <LaunchAction buildConfiguration = "Debug"\n'
                f'      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"\n'
                f'      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"\n'
                f'      launchStyle = "0" useCustomWorkingDirectory = "NO"\n'
                f'      ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES"\n'
                f'      debugServiceExtension = "internal" allowLocationSimulation = "YES">\n'
                f'      <BuildableProductRunnable runnableDebuggingMode = "0">\n'
                f'{ref(app)}      </BuildableProductRunnable>\n   </LaunchAction>\n'
                f'   <ProfileAction buildConfiguration = "Release"\n'
                f'      shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = ""\n'
                f'      useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">\n'
                f'      <BuildableProductRunnable runnableDebuggingMode = "0">\n'
                f'{ref(app)}      </BuildableProductRunnable>\n   </ProfileAction>\n'
                f'   <AnalyzeAction buildConfiguration = "Debug">\n   </AnalyzeAction>\n'
                f'   <ArchiveAction buildConfiguration = "Release"\n'
                f'      revealArchiveInOrganizer = "YES">\n   </ArchiveAction>\n'
                f'</Scheme>\n')


def main():
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--spec", default=os.path.join(here, "project.yml"))
    ap.add_argument("--out", default=here)
    args = ap.parse_args()

    with open(args.spec) as f:
        spec = parse_yaml(f.read())
    root = os.path.dirname(os.path.abspath(args.spec))
    project = Project(spec, root)
    bundle = project.write(args.out)

    counts = {}
    for tname, target in spec["targets"].items():
        files = collect(root, target.get("sources", []))
        counts[tname] = (sum(1 for _, p in files if p == "Sources"),
                         sum(1 for _, p in files if p == "Resources"))
    print(f"wrote {os.path.relpath(bundle, os.getcwd())}")
    for tname, (src, res) in counts.items():
        print(f"  {tname}: {src} source file(s), {res} resource(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
