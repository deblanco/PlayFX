#!/usr/bin/env python3
"""Generates THIRD_PARTY_LICENSES: every third-party component that ships in the PlayFX app, with its
version, upstream URL, copyright notices and full licence text.

What ships, and where this script reads it from (all on disk; no network):
  - Rust crates linked into the app binary: `cargo tree -e normal --target aarch64-apple-darwin` (normal
    dependencies only, with Cargo.lock as is: no dev- or build-dependencies, no other targets), details
    from `cargo metadata`, licence files from each crate's directory in ~/.cargo/registry/src.
    Proc-macro crates are kept: their output is compiled into the binary. Licence files below a crate's
    top level (e.g. regex-syntax's Unicode tables) are added to its notices.
  - The Rust standard library, linked from the toolchain: its crates from `cargo tree` in the rust-src
    component's library workspace, with the in-tree notices of the toolchain's COPYRIGHT-library.html.
  - npm packages in the web UI: the ones whose modules, styles or assets Vite actually puts in the
    bundle (scripts/third-party-licenses-bundle.mjs builds it into a temporary folder to find out).
  - C libraries statically linked (packages/streamcore/vendor/macos/lib, staged by build-chiaki.sh):
    those built from the chiaki-ng tree, and the Homebrew ones (licences from their kegs).
  - Code adapted into PlayFX's own sources (listed by hand below).

Dual-licensed components are listed under one of their licences, preferring one whose text the package
ships, then the simplest (MIT before Apache-2.0). Identical licence texts are printed once, after the
list of components they cover and each one's copyright notice.

Usage: scripts/third-party-licenses.py [output]     (default: THIRD_PARTY_LICENSES at the repo root)
Needs cargo (see CLAUDE.md for PATH) with the toolchain's rust-src component (rustup component add
rust-src), bun with node_modules installed, Homebrew with the kegs that build-chiaki.sh uses, and the
chiaki-ng submodule checked out (in this checkout or the main one).
"""
import json
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TAURI = os.path.join(ROOT, "apps", "desktop", "src-tauri")
APP = os.path.join(ROOT, "apps", "desktop")
VENDOR = os.path.join(ROOT, "packages", "streamcore", "vendor", "macos", "lib")
TARGET = "aarch64-apple-darwin"

# ----------------------------------------------------------------------------------------------- helpers


def run(cmd, cwd=ROOT, env=None):
    return subprocess.run(cmd, cwd=cwd, env=env, check=True, stdout=subprocess.PIPE, text=True).stdout


def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read().replace("\r\n", "\n").replace("\r", "\n").expandtabs(4)


def warn(msg):
    print("third-party-licenses: " + msg, file=sys.stderr)


def chiaki_dir():
    """The chiaki-ng submodule here, or in the main checkout when this is a worktree without it."""
    own = os.path.join(ROOT, "third_party", "chiaki-ng")
    if os.path.exists(os.path.join(own, "COPYING")):
        return own
    common = run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"]).strip()
    main = os.path.join(os.path.dirname(common), "third_party", "chiaki-ng")
    if os.path.exists(os.path.join(main, "COPYING")):
        return main
    sys.exit("third-party-licenses: third_party/chiaki-ng is not checked out (git submodule update --init)")


# Standard MIT text (SPDX "MIT"), for packages that declare MIT but ship no licence file, and for code
# adapted by hand from MIT sources.
MIT_TEXT = """Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""

# ------------------------------------------------------------------------------------ licence texts

LICENSE_FILE = re.compile(r"(?i)^(licen[cs]e|copying|unlicense)([-_. ].*)?$")
# Notices that go with a package whatever licence is chosen: third-party code inside it, NOTICE files.
EXTRA_FILE = re.compile(r"(?i)^(.*third[-_]?party.*|notice([-_.].*)?|copyright(notice)?(\.\w+)?)$")


def classify(text):
    """The licences whose terms a licence file contains (a file can hold several)."""
    t = re.sub(r"\s+", " ", text)
    found = set()
    if "Permission is hereby granted, free of charge" in t:
        found.add("MIT" if "above copyright notice" in t else "MIT-0")
    if re.search(r"Apache License,? Version 2\.0|Apache License Version 2\.0, January 2004", t) and "TERMS AND CONDITIONS" in t:
        found.add("Apache-2.0")
    if "Redistribution and use in source and binary forms" in t:
        found.add("BSD-3-Clause" if re.search(r"Neither the name|(^| )3\. ", t) else "BSD-2-Clause")
    if "This software is provided 'as-is'" in t and "plainly marked" in t:
        found.add("Zlib")
    if "UNICODE LICENSE V3" in t or "UNICODE, INC. LICENSE AGREEMENT" in t:
        found.add("Unicode-3.0")
    if "Mozilla Public License Version 2.0" in t or "Mozilla Public License, version 2.0" in t:
        found.add("MPL-2.0")
    if "This is free and unencumbered software released into the public domain" in t:
        found.add("Unlicense")
    if re.search(r"Permission to use, copy, modify, and(/or)? distribute this software for any purpose with or without fee is hereby granted", t):
        found.add("ISC" if "provided that the above copyright notice" in t else "0BSD")
    if "SIL OPEN FONT LICENSE" in t.upper():
        found.add("OFL-1.1")
    if "CC0 1.0 Universal" in t:
        found.add("CC0-1.0")
    return found


# Lower is preferred. Licences with no notice requirement come last so a notice is always given when the
# package allows; one whose text the package doesn't ship is avoided when another choice ships its text.
RANK = {"MIT": 0, "ISC": 1, "Zlib": 2, "BSD-2-Clause": 3, "BSD-3-Clause": 4, "Unicode-3.0": 5,
        "Apache-2.0": 6, "MPL-2.0": 7, "OFL-1.1": 7, "0BSD": 8, "MIT-0": 8, "CC0-1.0": 8, "Unlicense": 8}


def alternatives(expr):
    """An SPDX expression as its alternatives, each the set of licences to comply with together."""
    tokens = re.findall(r"\(|\)|[^\s()]+", expr.replace("/", " OR "))
    pos = [0]

    def parse_or():
        alts = parse_and()
        while pos[0] < len(tokens) and tokens[pos[0]].upper() == "OR":
            pos[0] += 1
            alts = alts + parse_and()
        return alts

    def parse_and():
        alts = parse_atom()
        while pos[0] < len(tokens) and tokens[pos[0]].upper() == "AND":
            pos[0] += 1
            rhs = parse_atom()
            alts = [a | b for a in alts for b in rhs]
        return alts

    def parse_atom():
        tok = tokens[pos[0]]
        pos[0] += 1
        if tok == "(":
            alts = parse_or()
            pos[0] += 1  # ")"
            return alts
        return [frozenset([tok])]

    return parse_or()


def choose(expr, available):
    def cost(alt):
        return sum(RANK.get(lic, 9) + (0 if lic in available else 20) for lic in alt)
    return sorted(min(alternatives(expr), key=cost), key=lambda lic: RANK.get(lic, 9))


COPYRIGHT_LINE = re.compile(r"^\s*(Copyright\b|COPYRIGHT\s*(\(C\)|©|\d)|\(c\)\s*\d|©)")
NOT_COPYRIGHT = re.compile(r"(?i)notice|holder|owner\]|\[yyyy\]|<year>|\{yyyy\}|\[year\]|<copyright")
CONTINUATION_STOP = re.compile(r"(?i)^\s*(permission|redistribution|licensed|this |the |unless|use of|except|"
                               r"neither|apache|mit\b|spdx|all rights reserved|copyright|[-=*#]{3})")


def split_copyrights(text):
    """(copyright lines with their continuation lines and "All rights reserved.", the rest of the text)."""
    lines = text.split("\n")
    keep, notes, i = [], [], 0
    while i < len(lines):
        line = lines[i]
        if COPYRIGHT_LINE.match(line) and not NOT_COPYRIGHT.search(line):
            entry = [line.strip()]
            i += 1
            while (i < len(lines) and lines[i].strip() and len(entry) < 4
                   and not CONTINUATION_STOP.match(lines[i]) and not COPYRIGHT_LINE.match(lines[i])):
                entry.append(lines[i].strip())
                i += 1
            while i < len(lines) and re.match(r"(?i)^\s*all rights reserved\.?\s*$", lines[i]):
                entry.append(lines[i].strip())
                i += 1
            notes.append(" ".join(entry))
        else:
            keep.append(line)
            i += 1
    return notes, "\n".join(keep)


def tidy_copyright(line):
    """One copyright statement repeated per font file ("X.ttf: Copyright ...") is shown once."""
    parts = re.split(r"\s+[\w\-\[\],]+\.(?:ttf|otf):\s+", line)
    seen = []
    for p in parts:
        if p.strip() and p.strip() not in seen:
            seen.append(p.strip())
    return " ".join(seen)


def strip_comment(text):
    """A licence from a source file's header comment, without the comment markers."""
    out = []
    for line in text.split("\n"):
        line = re.sub(r"^\s*(/\*+|\*+/|\*|//)\s?", "", line.rstrip())
        out.append("" if re.fullmatch(r"\**/?", line) else line)
    return "\n".join(out).strip("\n") + "\n"


def notice(spdx, text, authors=None, note=None):
    """One licence notice of a component, split into its copyright lines and the licence terms.

    MIT: everything before "Permission is hereby granted" is the component's own notice. Apache-2.0: the
    terms run to "END OF TERMS AND CONDITIONS"; a filled-in appendix contributes its copyright lines.
    Otherwise copyright lines are taken out of the text. `key` is what identical texts are grouped by."""
    text = text.strip("\n") + "\n"
    head, body = [], text
    if spdx == "MIT" and "Permission is hereby granted" in text:
        at = text.index("Permission is hereby granted")
        pre = text[:at].split("\n")
        body = text[at:]
        head = [line.strip() for line in pre if line.strip()
                and not re.fullmatch(r"(?i)[#*\s]*(the )?mit license( \(mit\))?:?[*\s]*|[-=*#_\s]+", line)]
    elif spdx == "Apache-2.0" and "END OF TERMS AND CONDITIONS" in text:
        start = re.search(r"(?m)^.*Apache License\s*$", text)
        start = start.start() if start else 0
        end = text.index("END OF TERMS AND CONDITIONS") + len("END OF TERMS AND CONDITIONS")
        head, _ = split_copyrights(text[:start])
        appendix, _ = split_copyrights(text[end:])
        head += appendix
        body = text[start:end] + "\n"
        lines = body.split("\n")
        indent = min((len(line) - len(line.lstrip()) for line in lines if line.strip()), default=0)
        body = "\n".join(line[indent:] for line in lines)
    else:
        head, body = split_copyrights(text)
    head = [tidy_copyright(h) for h in head if not h.startswith("#")]
    # A copyright line the licence file lacks: from the package manifest, printed even with the full text.
    added = [authors] if authors and not any(COPYRIGHT_LINE.match(h) for h in head) else []
    key = (spdx, re.sub(r"\s+", " ", body).strip())
    return {"spdx": spdx, "head": head + added, "added": added, "body": body.strip("\n") + "\n", "full": text,
            "key": key, "note": note}


# --------------------------------------------------------------------------------------- components


def component(origin, name, version, url, declared, notices, extras=()):
    return {"origin": origin, "name": name, "version": version, "url": url, "declared": declared,
            "notices": notices, "extras": list(extras)}


def package_notices(name, directory, declared, authors, fallback_texts, truncate=None, nested=False):
    """Licence notices for a package directory (crate or npm): the chosen licences' files, else the
    standard text with the authors from the manifest. `nested`: also licence files below the top level."""
    files = sorted(f for f in os.listdir(directory) if LICENSE_FILE.match(f) and not EXTRA_FILE.match(f)
                   and not f.endswith(".spdx") and os.path.isfile(os.path.join(directory, f)))
    texts = {}
    for f in files:
        text = read(os.path.join(directory, f))
        if truncate and truncate in text:
            text = text[:text.index(truncate)]
        texts[f] = (text, classify(text))
    available = set().union(*[c for _, c in texts.values()]) if texts else set()
    chosen = choose(declared, available)
    out = []
    for lic in chosen:
        candidates = [f for f, (_, c) in texts.items() if lic in c]
        if candidates:
            # Prefer the file named for this licence, then the one holding the fewest other licences.
            hint = {"Apache-2.0": "apache", "BSD-3-Clause": "bsd", "BSD-2-Clause": "bsd"}.get(lic, lic.lower())
            best = min(candidates, key=lambda f: (hint not in f.lower(), len(texts[f][1]), f))
            out.append(notice(lic, texts[best][0], authors))
        elif lic in ("MIT",):
            out.append(notice(lic, MIT_TEXT, authors, "the package ships no licence file; standard MIT text"))
        elif lic in fallback_texts():
            out.append(notice(lic, fallback_texts()[lic], authors,
                              "the package ships no licence file; text of the same licence from another package"))
        else:
            sys.exit("third-party-licenses: %s: no %s text found (declared: %s)" % (name, lic, declared))
    extras = []
    for f in sorted(os.listdir(directory)):
        if EXTRA_FILE.match(f) and os.path.isfile(os.path.join(directory, f)):
            extras.append((f, read(os.path.join(directory, f))))
    if nested:
        # Licences of code inside a crate's sources (e.g. regex-syntax's Unicode tables), not its tests.
        for dirpath, dirs, names in os.walk(directory):
            dirs[:] = sorted(d for d in dirs if d not in ("tests", "benches", "examples", "testdata", "target"))
            if dirpath == directory:
                continue
            for f in sorted(names):
                if (LICENSE_FILE.match(f) or EXTRA_FILE.match(f)) and not f.endswith((".rs", ".spdx")):
                    path = os.path.join(dirpath, f)
                    extras.append((os.path.relpath(path, directory), read(path)))
    return out, extras


def spdx_copyright(directory):
    for f in os.listdir(directory):
        if f.endswith(".spdx"):
            m = re.search(r"(?m)^PackageCopyrightText:\s*(.+)$", read(os.path.join(directory, f)))
            if m:
                text = m.group(1).replace("<text>", "").replace("</text>", "").strip()
                return "Copyright (c) " + text
    return None


def authors_line(authors, name):
    names = [re.sub(r"\s*[<(][^>)]*[>)]", "", a).strip() for a in authors if a]
    names = [n for n in names if n]
    if not names:
        return "Copyright: the %s authors (no copyright line in its licence file)" % name
    return "Copyright: %s (authors named in the package manifest; no copyright line in its licence file)" % ", ".join(names)


def cargo_packages(cwd, tree_args=(), features=(), env=None):
    """The packages `cargo tree -e normal --target TARGET` lists in the workspace at `cwd`, from cargo metadata."""
    cargo = ["cargo", "--offline", "--locked"] + list(features)
    meta = json.loads(run(cargo[:1] + ["metadata"] + cargo[1:] + ["--format-version", "1", "--filter-platform", TARGET], cwd, env))
    tree = run(cargo[:1] + ["tree"] + cargo[1:] + list(tree_args)
               + ["-e", "normal", "--target", TARGET, "--prefix", "none", "--format", "{p}"], cwd, env)
    wanted = set()
    for line in tree.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            wanted.add((parts[0], parts[1].lstrip("v")))
    packages = [p for p in meta["packages"] if (p["name"], p["version"]) in wanted]
    if len(packages) != len(wanted):
        sys.exit("third-party-licenses: cargo tree and cargo metadata disagree on the crates in %s" % cwd)
    return sorted(packages, key=lambda p: (p["name"], p["version"]))


def rust_crates():
    packages = [p for p in cargo_packages(TAURI) if p.get("source")]  # all but the app's own crate
    for p in packages:
        if not p["source"].startswith("registry+"):
            sys.exit("third-party-licenses: %s comes from %s; only crates.io crates are handled" % (p["name"], p["source"]))
    return packages


def rust_std():
    """The Rust standard library, linked into the binary from the toolchain's prebuilt copy: its own crates
    (one entry, with the notices of COPYRIGHT-library.html's in-tree section), compiler_builtins, and the
    crates.io crates it vendors. Read from the toolchain's rust-src component."""
    sysroot = run(["rustc", "--print", "sysroot"], TAURI).strip()
    rustc_version = run(["rustc", "--version"], TAURI).split()[1]
    library = os.path.join(sysroot, "lib", "rustlib", "src", "rust", "library")
    docs = os.path.join(sysroot, "share", "doc", "rust")
    if not os.path.exists(os.path.join(library, "std", "Cargo.toml")):
        sys.exit("third-party-licenses: the toolchain has no rust-src (rustup component add rust-src)")
    # The prebuilt std is built with backtraces and panic=unwind support (its addr2line, gimli, object,
    # miniz_oxide and panic_unwind rlibs ship with the toolchain).
    env = dict(os.environ, RUSTC_BOOTSTRAP="1")
    packages = cargo_packages(library, ["-p", "std"], ["-F", "std/backtrace,std/panic-unwind"], env)
    origin = "Rust standard library (app binary)"
    comps = []

    # The in-tree licence entries: "File/Directory", "License" and "Copyright" lines in COPYRIGHT-library.html.
    page = read(os.path.join(docs, "COPYRIGHT-library.html"))
    intree = page[page.index("The following licenses cover the in-tree"):page.index("The following licenses cover the out-of-tree")]
    intree = re.sub(r"<[^>]+>", "\n", intree).replace("&quot;", '"').replace("&amp;", "&")
    copyrights = {"MIT": [], "Unicode-3.0": []}
    for entry in re.split(r"File/Directory:", intree)[1:]:
        lic = re.search(r"License:\s*(.+)", entry).group(1).strip()
        holders = ["Copyright (c) " + c.strip() for c in re.findall(r"Copyright:\s*(.+)", entry)]
        if lic == "Apache-2.0 OR MIT":
            kind = "MIT"
        elif lic == "Unicode-3.0":
            kind = "Unicode-3.0"
        elif "LLVM-exception" in lic or "fuchsia" in entry:
            # LLVM's exception waives notices in binaries; the Fuchsia mutex isn't compiled for macOS.
            continue
        else:
            sys.exit("third-party-licenses: unhandled Rust standard library licence %r" % lic)
        for h in holders:
            if h not in copyrights[kind]:
                copyrights[kind].append(h)
    in_tree = [p for p in packages if not p.get("source") and p["name"] != "compiler_builtins"]
    for p in in_tree:
        if p["license"] != "MIT OR Apache-2.0":
            sys.exit("third-party-licenses: Rust standard library crate %s is under %s" % (p["name"], p["license"]))
    unicode = read(os.path.join(docs, "licenses", "Unicode-3.0.txt"))
    names = ", ".join(sorted(p["name"] for p in in_tree))
    comps.append(component(origin, "Rust standard library (%s)" % names, rustc_version, "https://github.com/rust-lang/rust",
                           "MIT OR Apache-2.0",
                           [notice("MIT", "\n".join(copyrights["MIT"]) + "\n\n" + MIT_TEXT),
                            notice("Unicode-3.0", unicode if re.search(r"(?m)^Copyright", unicode)
                                   else "\n".join(copyrights["Unicode-3.0"]) + "\n\n" + unicode)]))

    builtins = next(p for p in packages if p["name"] == "compiler_builtins")
    text = read(os.path.join(library, "compiler-builtins", "LICENSE.txt"))
    mit = text[text.index("Permission is hereby granted"):text.index("SOFTWARE.", text.index("Permission")) + len("SOFTWARE.")]
    comps.append(component(origin, "compiler_builtins", builtins["version"], builtins["repository"], builtins["license"],
                           [notice("MIT", mit, authors_line(builtins.get("authors") or [], "compiler_builtins"),
                                   "MIT AND Apache-2.0 WITH LLVM-exception; LLVM's exception needs no notice in a binary")]))

    for p in packages:
        if p.get("source"):
            d = os.path.dirname(p["manifest_path"])
            notices, extras = package_notices(p["name"], d, p["license"], authors_line(p.get("authors") or [], p["name"]),
                                              dict, nested=True)
            comps.append(component(origin, p["name"], p["version"], p.get("repository") or "https://crates.io/crates/" + p["name"],
                                   p["license"], notices, extras))
    return comps


def npm_packages():
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, "packages.json")
        subprocess.run(["bun", os.path.join(ROOT, "scripts", "third-party-licenses-bundle.mjs"), APP, out],
                       cwd=APP, check=True, stdout=sys.stderr)
        with open(out) as f:
            return json.load(f)


def repo_url(repository):
    url = repository.get("url", "") if isinstance(repository, dict) else (repository or "")
    url = re.sub(r"^git\+", "", url)
    url = re.sub(r"^git@github\.com:", "https://github.com/", url)
    url = re.sub(r"^github:", "https://github.com/", url)
    url = re.sub(r"\.git$", "", url)
    if re.fullmatch(r"[\w.-]+/[\w.-]+", url):
        url = "https://github.com/" + url
    return url


def collect():
    comps = []
    crates = rust_crates()
    npm = npm_packages()

    # Texts to fall back on when a package declares a licence but ships no file for it: the same licence
    # from another package of the same repository, else from any package.
    def fallbacks_for(repository):
        found = {}
        for same_repo in (True, False):
            for p in crates:
                if same_repo and (p.get("repository") != repository or not repository):
                    continue
                d = os.path.dirname(p["manifest_path"])
                for f in os.listdir(d):
                    if LICENSE_FILE.match(f) and not EXTRA_FILE.match(f) and os.path.isfile(os.path.join(d, f)):
                        text = read(os.path.join(d, f))
                        for lic in classify(text):
                            if len(classify(text)) == 1:
                                found.setdefault(lic, split_copyrights(text)[1])
        return found

    for p in crates:
        d = os.path.dirname(p["manifest_path"])
        declared = p.get("license") or ""
        if not declared:
            sys.exit("third-party-licenses: crate %s declares no licence" % p["name"])
        authors = spdx_copyright(d) or authors_line(p.get("authors") or [], p["name"])
        notices, extras = package_notices(p["name"], d, declared, authors, lambda: fallbacks_for(p.get("repository")),
                                          nested=True)
        url = p.get("repository") or p.get("homepage") or "https://crates.io/crates/" + p["name"]
        comps.append(component("Rust crates (app binary)", p["name"], p["version"], url, declared, notices, extras))

    for pkg in npm:
        d = pkg["dir"]
        with open(os.path.join(d, "package.json")) as f:
            manifest = json.load(f)
        declared = manifest.get("license") or ""
        if isinstance(declared, dict):
            declared = declared.get("type", "")
        if not declared:
            sys.exit("third-party-licenses: npm package %s declares no licence" % pkg["name"])
        author = manifest.get("author")
        author = author.get("name") if isinstance(author, dict) else author
        # Vite's LICENSE.md goes on to the licences of what its Node build bundles; only Vite's own
        # client code (the module preload polyfill) is in the app.
        truncate = "# Licenses of bundled dependencies" if pkg["name"] == "vite" else None
        authors = spdx_copyright(d) or authors_line([author] if author else [], pkg["name"])
        notices, extras = package_notices(pkg["name"], d, declared, authors, dict, truncate)
        url = repo_url(manifest.get("repository")) or manifest.get("homepage") or "https://www.npmjs.com/package/" + pkg["name"]
        comps.append(component("npm packages (web UI)", pkg["name"], pkg["version"], url, declared, notices, extras))

    comps += rust_std()
    comps += native_libraries()
    comps += adapted_code()
    return comps


def native_libraries():
    chiaki = chiaki_dir()
    third = os.path.join(chiaki, "third-party")
    origin = "C libraries (statically linked)"
    comps = []

    def submodule_url(path):
        m = re.search(r'path = %s\s+url = (\S+)' % re.escape(path), read(os.path.join(chiaki, ".gitmodules")))
        return re.sub(r"\.git$", "", m.group(1)) if m else ""

    def submodule_rev(path):
        return run(["git", "-C", os.path.join(chiaki, path), "rev-parse", "--short=12", "HEAD"]).strip()

    curl_version = re.search(r'LIBCURL_VERSION "([^"]+)"', read(os.path.join(third, "curl", "include", "curl", "curlver.h"))).group(1)
    nanopb_version = re.search(r'NANOPB_VERSION "nanopb-([^"]+)"', read(os.path.join(third, "nanopb", "pb.h"))).group(1)
    from_chiaki = [
        ("curl", "%s (git %s)" % (curl_version, submodule_rev("third-party/curl")), "https://curl.se",
         "curl", os.path.join(third, "curl", "COPYING")),
        ("nanopb", "%s (git %s)" % (nanopb_version, submodule_rev("third-party/nanopb")), submodule_url("third-party/nanopb"),
         "Zlib", os.path.join(third, "nanopb", "LICENSE.txt")),
        ("Jerasure", "2.0 (git %s)" % submodule_rev("third-party/jerasure"), submodule_url("third-party/jerasure"),
         "BSD-3-Clause", os.path.join(third, "jerasure", "COPYING")),
        ("GF-Complete", "git %s" % submodule_rev("third-party/gf-complete"), submodule_url("third-party/gf-complete"),
         "BSD-3-Clause", os.path.join(third, "gf-complete", "COPYING")),
    ]
    for name, version, url, spdx, path in from_chiaki:
        comps.append(component(origin, name, version + ", from chiaki-ng's tree", url, spdx, [notice(spdx, read(path))]))

    # Mesa's bitstream reader, copied into libchiaki (lib/src/vl_rbsp.h).
    header = read(os.path.join(chiaki, "lib", "src", "vl_rbsp.h"))
    lic = strip_comment(header[:header.index("*/") + 2])
    comps.append(component(origin, "Mesa (vl_rbsp.h, in libchiaki)", "copied file", "https://gitlab.freedesktop.org/mesa/mesa",
                           "MIT", [notice("MIT", lic)]))

    homebrew = [
        ("OpenSSL", "openssl@3", ["libssl.a", "libcrypto.a"], "https://www.openssl.org", "Apache-2.0", "LICENSE.txt"),
        ("Opus", "opus", ["libopus.a"], "https://opus-codec.org", "BSD-3-Clause", "COPYING"),
        ("json-c", "json-c", ["libjson-c.a"], "https://github.com/json-c/json-c", "MIT", "COPYING"),
        ("miniupnpc", "miniupnpc", ["libminiupnpc.a"], "https://github.com/miniupnp/miniupnp", "BSD-3-Clause", "LICENSE"),
        ("libevent", "libevent", ["libevent.a"], "https://libevent.org", "BSD-3-Clause", "LICENSE"),
    ]
    for name, formula, libs, url, spdx, license_file in homebrew:
        prefix = os.path.realpath(run(["brew", "--prefix", formula]).strip())
        if not os.path.isdir(prefix):
            sys.exit("third-party-licenses: Homebrew %s is not installed" % formula)
        for lib in libs:
            staged, keg = os.path.join(VENDOR, lib), os.path.join(prefix, "lib", lib)
            if os.path.exists(staged) and (not os.path.exists(keg) or read_bytes(staged) != read_bytes(keg)):
                warn("%s differs from Homebrew's %s: the version listed may not be the linked one "
                     "(re-run build-chiaki.sh)" % (lib, keg))
        version = os.path.basename(prefix)
        notices = [notice(spdx, read(os.path.join(prefix, license_file)))]
        extras = [(f, read(os.path.join(prefix, f))) for f in sorted(os.listdir(prefix)) if re.match(r"(?i)^notice", f)]
        comps.append(component(origin, name, version + " (Homebrew)", url, spdx, notices, extras))
    return comps


def read_bytes(path):
    with open(path, "rb") as f:
        return f.read()


def adapted_code():
    """Third-party code adapted by hand into PlayFX's own sources and the shadcn/ui component sources."""
    # Copyright lines as upstream states them: CAS in ffx-cas/ffx_cas.h (the file ported) and LICENSE.txt
    # of GPUOpen-Effects/FidelityFX-CAS; shadcn/ui in LICENSE.md of shadcn-ui/ui. (No shadcn/studio code: its
    # blocks are MIT with a Commons Clause, which the AGPL can't carry.)
    return [
        component("Code adapted into PlayFX's sources", "AMD FidelityFX CAS (contrast-adaptive sharpening)",
                  "1.20190610 (ffx_cas.h), ported to Metal in packages/streamcore/Sources/StreamCore/Shaders.swift",
                  "https://github.com/GPUOpen-Effects/FidelityFX-CAS", "MIT",
                  [notice("MIT", "Copyright (c) 2017-2019 Advanced Micro Devices, Inc. All rights reserved.\n"
                                 "Copyright (c) 2020 Advanced Micro Devices, Inc. All rights reserved.\n\n" + MIT_TEXT)]),
        component("Code adapted into PlayFX's sources", "shadcn/ui components",
                  "apps/desktop/src/components/ui (generated by the shadcn CLI)", "https://github.com/shadcn-ui/ui", "MIT",
                  [notice("MIT", "Copyright (c) 2023 shadcn\n\n" + MIT_TEXT)]),
    ]


# ------------------------------------------------------------------------------------------- output

RULE = "=" * 100
THIN = "-" * 100


def render(comps):
    chiaki = chiaki_dir()
    chiaki_rev = run(["git", "-C", chiaki, "rev-parse", "--short=12", "HEAD"]).strip()
    cmake = read(os.path.join(chiaki, "CMakeLists.txt"))
    chiaki_version = ".".join(re.search(r"set\(CHIAKI_VERSION_%s (\d+)\)" % part, cmake).group(1)
                              for part in ("MAJOR", "MINOR", "PATCH"))
    exception = read(os.path.join(chiaki, "LICENSES", "AGPL-3.0-only-OpenSSL.txt"))
    exception = exception[exception.index("Additional permission under GNU AGPL version 3 section 7"):].strip()

    # Group identical texts; a text shared by one component only is printed whole.
    groups = {}
    for c in comps:
        for n in c["notices"]:
            groups.setdefault(n["key"], []).append((c, n))
    order = sorted(groups, key=lambda k: (-len(groups[k]), k[0], k[1]))
    numbers = {}
    labels = {}
    for i, key in enumerate(order, 1):
        numbers[key] = i
        same = [k for k in order if k[0] == key[0]]
        labels[key] = key[0] if len(same) == 1 else "%s, text %d of %d" % (key[0], same.index(key) + 1, len(same))

    out = []
    w = out.append
    w("PlayFX: third-party software licences")
    w(RULE)
    w("")
    w("PlayFX is free software under the GNU Affero General Public License version 3 (see LICENSE and")
    w("NOTICE). It includes the third-party software listed below, each under its own licence. For every")
    w("component this file gives its version, where it comes from, its copyright notices and the full text")
    w("of its licence. Components under identical licence texts share one copy of the text, printed after")
    w("the list of those components and their copyright notices. Where a component offers a choice of")
    w("licences, it is used here under the one named.")
    w("")
    w("Generated by scripts/third-party-licenses.py from the sources the app is built from. Do not edit.")
    w("")
    w(RULE)
    w("Components")
    w(RULE)
    origins = ["C libraries (statically linked)", "Code adapted into PlayFX's sources", "Rust standard library (app binary)",
               "Rust crates (app binary)", "npm packages (web UI)"]
    w("")
    w("libchiaki (chiaki-ng)  %s, git %s  AGPL-3.0-only with an OpenSSL linking exception" % (chiaki_version, chiaki_rev))
    w("    built from the modified fork https://github.com/deblanco/chiaki-ng (branch playfx)")
    w("    of https://github.com/streetpea/chiaki-ng; see the section after this list")
    for origin in origins:
        members = sorted((c for c in comps if c["origin"] == origin), key=lambda c: (c["name"].lower(), c["version"]))
        w("")
        w("%s (%d)" % (origin, len(members)))
        w(THIN)
        for c in members:
            lics = " AND ".join(n["spdx"] for n in c["notices"])
            refs = ", ".join("[%d]" % numbers[n["key"]] for n in c["notices"])
            w("%s %s  %s %s" % (c["name"], c["version"], lics, refs))
            w("    %s" % c["url"])

    w("")
    w(RULE)
    w("libchiaki (chiaki-ng)")
    w(RULE)
    w("")
    w("The Remote Play protocol library, statically linked into PlayFX. PlayFX builds it from")
    w("https://github.com/deblanco/chiaki-ng (branch playfx, commit %s), a modified fork of chiaki-ng" % chiaki_rev)
    w("(https://github.com/streetpea/chiaki-ng), itself a fork of Chiaki by Florian Märkl.")
    w("")
    w("Copyright (C) the Chiaki and chiaki-ng authors (including Florian Märkl, Street Pea and contributors)")
    w("Modifications in the playfx branch: Copyright (C) 2026 Daniel B.")
    w("")
    w("Licensed under the GNU Affero General Public License version 3 only, whose full text is in the")
    w("LICENSE file next to this one, with the following additional permission from chiaki-ng's")
    w("LICENSES/AGPL-3.0-only-OpenSSL.txt. Its complete source code is published at the address above.")
    w("")
    w("Its lib/src/base64.c says its implementation is taken from Wikibooks, Algorithm Implementation/")
    w("Miscellaneous/Base64 (https://en.wikibooks.org/wiki/Algorithm_Implementation/Miscellaneous/Base64).")
    w("Its lib/src/vl_rbsp.h is from Mesa; see Mesa in the list above.")
    w("")
    w(exception)

    w("")
    w(RULE)
    w("Licence texts")
    w(RULE)
    for key in order:
        members = groups[key]
        w("")
        w(THIN)
        w("[%d] %s" % (numbers[key], labels[key]))
        w(THIN)
        w("")
        single = len(members) == 1
        w("Used by:" if not single else "Used by %s %s." % (members[0][0]["name"], members[0][0]["version"]))
        if not single:
            for c, n in sorted(members, key=lambda m: (m[0]["name"].lower(), m[0]["version"])):
                w("  %s %s" % (c["name"], c["version"]))
                for h in n["head"]:
                    w("      " + h)
                if n["note"]:
                    w("      (%s)" % n["note"])
        else:
            n = members[0][1]
            if n["note"]:
                w("(%s)" % n["note"])
            for h in n["added"]:
                w(h)
        if key[0] == "MPL-2.0":
            w("")
            w("The source code of these components is available from the addresses in the list above.")
        w("")
        w((n["body"] if not single else members[0][1]["full"]).rstrip("\n"))

    extras = [(c, f, text) for c in comps for f, text in c["extras"]]
    if extras:
        w("")
        w(RULE)
        w("Additional notices shipped with components")
        w(RULE)
        for c, f, text in sorted(extras, key=lambda e: (e[0]["name"].lower(), e[1])):
            w("")
            w(THIN)
            w("%s %s: %s" % (c["name"], c["version"], f))
            w(THIN)
            w("")
            w(text.strip("\n"))
    return "\n".join(line.rstrip() for line in "\n".join(out).split("\n")) + "\n"


def main():
    output = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "THIRD_PARTY_LICENSES")
    text = render(collect())
    with open(output, "w", encoding="utf-8") as f:
        f.write(text)
    print("wrote %s" % os.path.relpath(output, ROOT), file=sys.stderr)


if __name__ == "__main__":
    main()
