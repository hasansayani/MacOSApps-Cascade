#!/usr/bin/env python3
"""Measures the repo and the built app, then regenerates:

  docs/app-facts.svg   a "nutrition facts"-style label (code, tests, permissions, size, CPU, memory)
  docs/app-facts.json  the raw numbers behind the label
  docs/code-graph.svg  file-level dependency graph (Graphviz)
  docs/cascade-flow.svg  how a cascade runs, from docs/cascade-flow.dot (Graphviz)

Usage: scripts/repo_report.py [--skip-build]
Run from anywhere; expects build/Cascade.app (built by build.sh unless --skip-build).
"""
import datetime
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "build" / "Cascade.app"
DOCS = ROOT / "docs"
TARGETS = {"CascadeCore": "Core logic", "Cascade": "App", "CascadeSelfTest": "Self-tests"}


def sh(*cmd, check=True, **kw):
    return subprocess.run(cmd, cwd=ROOT, check=check, capture_output=True, text=True, **kw).stdout.strip()


# ---------------------------------------------------------------------------------------------
# Measurements

def code_stats():
    stats = {}
    for target in TARGETS:
        files = sorted((ROOT / "Sources" / target).glob("*.swift"))
        code = comments = blank = 0
        for f in files:
            for line in f.read_text().splitlines():
                s = line.strip()
                if not s:
                    blank += 1
                elif s.startswith("//"):
                    comments += 1
                else:
                    code += 1
        stats[target] = {"files": len(files), "code": code, "comments": comments, "blank": blank}
    return stats


def test_stats():
    out = sh("swift", "run", "-c", "release", "CascadeSelfTest", check=False)
    m = re.search(r"(\d+)/(\d+) checks passed", out)
    suites = len(re.findall(r"^[✓✗] ", out, re.M))
    passed, total = (int(m.group(1)), int(m.group(2))) if m else (0, 0)
    return {"suites": suites, "checks_passed": passed, "checks_total": total}


def coverage_stats():
    scratch = ROOT / ".build" / "coverage"
    flags = ["-Xswiftc", "-profile-generate", "-Xswiftc", "-profile-coverage-mapping"]
    sh("swift", "build", "--scratch-path", str(scratch), "--product", "CascadeSelfTest", *flags)
    binary = Path(sh("swift", "build", "--scratch-path", str(scratch), "--product", "CascadeSelfTest",
                     "--show-bin-path")) / "CascadeSelfTest"
    with tempfile.TemporaryDirectory() as tmp:
        raw, data = Path(tmp) / "cov.profraw", Path(tmp) / "cov.profdata"
        subprocess.run([str(binary)], cwd=ROOT, env={**os.environ, "LLVM_PROFILE_FILE": str(raw)},
                       capture_output=True)
        sh("xcrun", "llvm-profdata", "merge", "-sparse", str(raw), "-o", str(data))
        report = json.loads(sh("xcrun", "llvm-cov", "export", str(binary), f"-instr-profile={data}",
                               "-summary-only", str(ROOT / "Sources" / "CascadeCore")))
    totals = report["data"][0]["totals"]
    return {"core_lines_pct": round(totals["lines"]["percent"], 1),
            "core_functions_pct": round(totals["functions"]["percent"], 1),
            "core_regions_pct": round(totals["regions"]["percent"], 1)}


def size_stats(version):
    binary = APP / "Contents" / "MacOS" / "Cascade"
    app_bytes = sum(f.stat().st_size for f in APP.rglob("*") if f.is_file())
    zip_path = ROOT / "build" / f"Cascade-{version}.zip"
    slices = {}
    for arch in sh("lipo", "-archs", str(binary)).split():
        with tempfile.NamedTemporaryFile() as t:
            sh("lipo", str(binary), "-thin", arch, "-output", t.name)
            slices[arch] = os.path.getsize(t.name)
    return {"app_bytes": app_bytes, "binary_bytes": binary.stat().st_size, "slices": slices,
            "zip_bytes": zip_path.stat().st_size if zip_path.exists() else None}


def security_stats():
    sources = "\n".join(f.read_text() for f in (ROOT / "Sources").rglob("*.swift"))
    app_sources = "\n".join(f.read_text() for f in (ROOT / "Sources" / "Cascade").glob("*.swift"))
    sig = subprocess.run(["codesign", "-dvv", str(APP)], capture_output=True, text=True).stderr
    entitlements = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", str(APP)],
                                  capture_output=True, text=True).stdout
    package = (ROOT / "Package.swift").read_text()
    return {
        "accessibility": "AXIsProcessTrusted" in app_sources,
        "network_calls": len(re.findall(r"URLSession|NWConnection|CFSocket|NSURLConnection|URLRequest", sources)),
        "screen_capture": bool(re.search(r"CGWindowListCreateImage|SCStream|SCScreenshot", sources)),
        "keyboard_monitor": bool(re.search(r"addGlobalMonitorForEvents\(matching: [^)]*key", app_sources)),
        "private_apis": sorted(set(re.findall(r'@_silgen_name\("(\w+)"\)', sources))),
        "dependencies": len(re.findall(r"\.package\(", package)),
        "hardened_runtime": "runtime" in sig,
        "signature": "Ad-hoc" if "Signature=adhoc" in sig else "Developer ID",
        "entitlements": len(re.findall(r"<key>", entitlements)),
        "frameworks": sorted(set(re.findall(r"^import (\w+)", app_sources, re.M)) - {"CascadeCore"}),
    }


def runtime_stats(previous):
    """Idle CPU/memory of a running Cascade, and the scan benchmark. Falls back to the last report."""
    result = dict(previous.get("runtime", {}))
    pid = sh("pgrep", "-x", "Cascade", check=False).split()
    if pid:
        pid = pid[0]

        def cpu_seconds():
            t = sh("ps", "-o", "time=", "-p", pid)
            parts = [float(p) for p in t.replace("-", ":").split(":")]
            return sum(v * 60 ** i for i, v in enumerate(reversed(parts)))
        window = 20
        start = cpu_seconds()
        time.sleep(window)
        idle_pct = (cpu_seconds() - start) / window * 100
        result.update({
            "idle_cpu_pct": round(idle_pct, 2),
            "idle_memory_mb": round(int(sh("ps", "-o", "rss=", "-p", pid)) / 1024, 1),
            "threads": len(sh("ps", "-M", "-p", pid).splitlines()) - 1,
        })
    # The benchmark must run as its own app (via `open`) so macOS checks Cascade's own permission.
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "bench.json"
        subprocess.run(["open", "-n", "-W", "--stdout", str(out), str(APP), "--args", "--benchmark", "25"],
                       capture_output=True, timeout=120)
        try:
            result["scan"] = json.loads(out.read_text())
        except (OSError, ValueError):
            print("  (benchmark skipped: grant Cascade Accessibility access to measure it)")
    return result


def machine():
    chip = sh("sysctl", "-n", "machdep.cpu.brand_string", check=False)
    return f"{chip}, macOS {sh('sw_vers', '-productVersion')}"


# ---------------------------------------------------------------------------------------------
# Code graph

def code_graph_dot():
    """Graphviz source for the file-level dependency graph."""
    files = {t: sorted((ROOT / "Sources" / t).glob("*.swift")) for t in TARGETS}
    texts = {f: f.read_text() for fs in files.values() for f in fs}
    decl = re.compile(r"^(?:(?:public|private|fileprivate|internal|final)\s+)*(?:class|struct|enum|protocol)\s+(\w+)", re.M)
    ext = re.compile(r"^extension\s+(\w+)", re.M)
    owners, declared = {}, {}
    for f, text in texts.items():
        declared[f] = decl.findall(text)
        for name in declared[f]:
            owners[name] = f
    # Extensions of system types count as owned by the extending file when only one file extends them.
    extended = {}
    for f, text in texts.items():
        for name in ext.findall(text):
            if name not in owners:
                extended.setdefault(name, set()).add(f)
    for name, fs in extended.items():
        if len(fs) == 1:
            owners[name] = next(iter(fs))

    def node(f):
        return f"{f.parent.name}_{f.stem}"

    def uses(t, f):
        return sum(len(re.findall(rf"\b{t}\b", o)) for g, o in texts.items() if g != f)

    special = {"ApplicationServices": "Accessibility API", "Carbon": "Carbon hot keys",
               "SwiftUI": "SwiftUI", "ServiceManagement": "Login items"}
    styles = {"CascadeCore": ("#eef4ff", "#3b6fd8"), "Cascade": ("#f4f4f4", "#555555"),
              "CascadeSelfTest": ("#eefaf0", "#2f8f46")}
    out = [
        "digraph Cascade {",
        '  graph [rankdir=TB, compound=true, nodesep=0.3, ranksep=0.55, pad=0.3, bgcolor="white",'
        ' fontname="Helvetica", fontsize=13];',
        '  node [shape=box, style="rounded,filled", fillcolor=white, color="#444444", penwidth=1.2,'
        ' fontname="Helvetica", fontsize=12, margin="0.18,0.08"];',
        '  edge [color="#555555", arrowsize=0.7, penwidth=1.1];',
    ]
    first = {}
    for target, fs in files.items():
        fill, border = styles[target]
        out.append(f'  subgraph cluster_{target} {{')
        out.append(f'    label=<<b>{target}</b>  <font color="#666666">{TARGETS[target]}</font>>;')
        out.append(f'    style="rounded,filled"; fillcolor="{fill}"; color="{border}"; penwidth=1.5; margin=14;')
        for f in fs:
            loc = sum(1 for l in texts[f].splitlines() if l.strip() and not l.strip().startswith("//"))
            types = sorted((t for t in declared[f] if not t.startswith("_")), key=lambda t: -uses(t, f))[:3]
            subtitle = escape(", ".join(types) if types else "entry point")
            frameworks = [label for key, label in special.items() if re.search(rf"^import {key}", texts[f], re.M)]
            tag = (f'<br/><font point-size="9.5" color="#b35c00">▸ {escape(" · ".join(frameworks))}</font>'
                   if frameworks else "")
            out.append(f'    {node(f)} [label=<<b>{f.name}</b><br/><font point-size="10" color="#555555">'
                       f'{subtitle}<br/>{loc} lines</font>{tag}>];')
            first.setdefault(target, node(f))
        out.append("  }")
    out.append('  labelloc=b; label=<<font point-size="10" color="#555555">→ uses a type from    '
               '⇒ package depends on package    '
               '<font color="#b35c00">▸ macOS framework needing special access</font></font>>;')

    edges, package_edges, fw_edges = set(), set(), set()
    target_of = {node(f): f.parent.name for f in texts}
    for f, text in texts.items():
        stripped = re.sub(r"//.*", "", text)
        for name, owner in owners.items():
            if owner == f or not re.search(rf"\b{name}\b", stripped):
                continue
            a, b = node(f), node(owner)
            if target_of[a] == target_of[b]:
                edges.add((a, b))
            else:
                package_edges.add((target_of[a], target_of[b]))
        for key in special:
            if re.search(rf"^import {key}", text, re.M):
                fw_edges.add((node(f), f"fw_{key}"))
    for a, b in sorted(edges):
        out.append(f"  {a} -> {b};")
    for a, b in sorted(package_edges):
        # One thick arrow per package pair, drawn cluster-to-cluster.
        out.append(f'  {first[a]} -> {first[b]} [ltail=cluster_{a}, lhead=cluster_{b}, penwidth=2.4,'
                   f' color="#3b6fd8", label=" uses ", fontname="Helvetica", fontsize=10, fontcolor="#3b6fd8"];')
    out.append("}")
    return "\n".join(out) + "\n"


def render_dot(source, svg_path):
    svg = subprocess.run(["dot", "-Tsvg"], input=source, capture_output=True, text=True, check=True).stdout
    svg_path.write_text(svg)


# ---------------------------------------------------------------------------------------------
# Label (SVG)

def fmt_bytes(n):
    return "–" if n is None else (f"{n / 1024 / 1024:.1f} MB" if n >= 1024 * 1024 else f"{n / 1024:.0f} KB")


def label_svg(r):
    W, PAD = 380, 12
    y = PAD
    out = []

    def text(x, ty, s, size=13, weight=400, anchor="start", italic=False):
        style = ' font-style="italic"' if italic else ""
        out.append(f'<text x="{x}" y="{ty}" font-size="{size}" font-weight="{weight}" '
                   f'text-anchor="{anchor}"{style}>{escape(str(s))}</text>')

    def bar(h):
        nonlocal y
        out.append(f'<rect x="{PAD}" y="{y}" width="{W - 2 * PAD}" height="{h}"/>')
        y += h

    def rule():
        nonlocal y
        out.append(f'<rect x="{PAD}" y="{y}" width="{W - 2 * PAD}" height="0.8"/>')

    def row(name, value, bold=False, indent=0, line=True):
        nonlocal y
        y += 17
        text(PAD + indent, y - 4, name, 12.5, 800 if bold else 400)
        text(W - PAD, y - 4, value, 12.5, 800 if bold else 400, "end")
        if line:
            rule()

    def heading(name, right=""):
        nonlocal y
        y += 18
        text(PAD, y - 4, name, 14, 900)
        if right:
            text(W - PAD, y - 4, right, 10.5, 700, "end")
        rule()

    def para(s, size=10.5, bold_prefix=None):
        nonlocal y
        words, line_words, lines = s.split(), [], []
        limit = int((W - 2 * PAD) / (size * 0.53))
        for w in words:
            if len(" ".join(line_words + [w])) > limit:
                lines.append(" ".join(line_words))
                line_words = []
            line_words.append(w)
        lines.append(" ".join(line_words))
        for i, l in enumerate(lines):
            y += size + 3
            if i == 0 and bold_prefix and l.startswith(bold_prefix):
                out.append(f'<text x="{PAD}" y="{y}" font-size="{size}"><tspan font-weight="800">'
                           f'{escape(bold_prefix)}</tspan>{escape(l[len(bold_prefix):])}</text>')
            else:
                text(PAD, y, l, size)

    c, t, cov, s, sec, rt = r["code"], r["tests"], r["coverage"], r["size"], r["security"], r["runtime"]
    total_code = sum(v["code"] for v in c.values())
    total_comments = sum(v["comments"] for v in c.values())
    total_files = sum(v["files"] for v in c.values())

    y += 34
    text(PAD - 1, y, "App Facts", 38, 900)
    y += 8
    bar(1)
    y += 16
    text(PAD, y, f"Cascade {r['version']} · window cascading for macOS", 13)
    y += 18
    text(PAD, y, "Serving size", 15, 800)
    text(W - PAD, y, "1 universal app", 15, 800, "end")
    y += 6
    bar(10)

    y += 4
    text(PAD, y + 12, "Amount per download", 11, 800)
    y += 16
    y += 24
    text(PAD, y, "Download", 26, 900)
    text(W - PAD, y, fmt_bytes(s["zip_bytes"]), 26, 900, "end")
    y += 6
    bar(5)
    row("Installed size", fmt_bytes(s["app_bytes"]), True)
    for arch, n in s["slices"].items():
        row({"arm64": "Apple silicon slice", "x86_64": "Intel slice"}.get(arch, arch), fmt_bytes(n), indent=14)
    row("Third-party dependencies", str(sec["dependencies"]), True)
    row("Private APIs", str(len(sec["private_apis"])), True, line=False)
    y += 3
    bar(10)

    heading("Code", f"{total_files} files")
    row("Lines of code", f"{total_code:,}", True)
    for target, label in TARGETS.items():
        row(label, f"{c[target]['code']:,}", indent=14)
    row("Comment lines", f"{total_comments:,}  ({total_comments * 100 // max(total_code, 1)}% of code)")
    row("Language", "Swift (no Objective-C)", line=False)
    y += 3
    bar(5)

    heading("Tests")
    passed, total = t["checks_passed"], t["checks_total"]
    row("Checks passing", f"{passed}/{total}  ({passed * 100 // max(total, 1)}%)", True)
    row("Test suites", str(t["suites"]), indent=14)
    row("Core logic line coverage", f"{cov['core_lines_pct']}%", True)
    row("Core function coverage", f"{cov['core_functions_pct']}%", indent=14)
    row("App / UI layer", "manually tested", line=False)
    y += 3
    bar(5)

    heading("Permissions & Privacy")
    row("Accessibility", "Required" if sec["accessibility"] else "Not used", True)
    row("Screen Recording", "Used" if sec["screen_capture"] else "Not used")
    row("Input Monitoring (keys)", "Used" if sec["keyboard_monitor"] else "Not used")
    row("Network access", "None" if sec["network_calls"] == 0 else f"{sec['network_calls']} call sites")
    row("Data collected / telemetry", "None")
    row("Files written", "Settings + custom icon")
    row("Launch at login", "Optional, off")
    row("Entitlements", str(sec["entitlements"]))
    row("App Sandbox", "No (incompatible with AX)")
    row("Hardened runtime", "Yes" if sec["hardened_runtime"] else "No")
    row("Code signature", f"{sec['signature']}, not notarized", line=False)
    y += 3
    bar(5)

    heading("Performance", "measured")
    if "idle_cpu_pct" in rt:
        row("CPU while idle", f"{rt['idle_cpu_pct']:.2f}%", True)
        row("Memory while idle", f"{rt['idle_memory_mb']:.0f} MB", True)
        row("Threads while idle", str(rt["threads"]))
    if "scan" in rt:
        sc = rt["scan"]
        row("Window scan + layout", f"{sc['median_ms']} ms median", True)
        row(f"({sc['windows']} windows, {sc['apps']} apps)", f"{sc['p95_ms']} ms p95", indent=14)
    row("Background work", "Event-driven + 1.5 s check*", line=False)
    y += 3
    bar(5)

    heading("Compatibility")
    names = {"13": "Ventura", "14": "Sonoma", "15": "Sequoia", "26": "Tahoe"}
    row("macOS", f"{r['min_macos']} {names.get(r['min_macos'], '')} or later".replace("  ", " "), True)
    row("Chips", "Apple silicon + Intel", line=False)
    y += 3
    bar(10)

    y += 2
    para("INGREDIENTS: Swift, " + ", ".join(sec["frameworks"]) + ".", bold_prefix="INGREDIENTS:")
    y += 4
    allergens = "CONTAINS: " + (f"{len(sec['private_apis'])} private API ({', '.join(sec['private_apis'])}), "
                                "used to identify windows. " if sec["private_apis"] else "")
    para(allergens + "Requires Accessibility permission to move windows.", bold_prefix="CONTAINS:")
    y += 6
    para("* Window borders re-check window positions every 1.5 s (well under a millisecond) and follow "
         "drags at 60 Hz. A 2-second permission check runs only until Accessibility is granted.", size=9.5)
    y += 2
    para(f"Measured {r['date']} on {r['machine']}.", size=9.5)
    y += PAD

    H = y
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W + 8}" height="{H + 8}" viewBox="-4 -4 {W + 8} {H + 8}" '
            f'role="img" aria-label="App Facts label for Cascade {r["version"]}" '
            f'font-family="Helvetica Neue, Helvetica, Arial, sans-serif" fill="#000">'
            f'<rect x="-4" y="-4" width="{W + 8}" height="{H + 8}" fill="#fff"/>'
            f'<rect x="1" y="1" width="{W - 2}" height="{H - 2}" fill="none" stroke="#000" stroke-width="2"/>'
            + "".join(out) + "</svg>\n")


# ---------------------------------------------------------------------------------------------

def main():
    if "--skip-build" not in sys.argv:
        print("→ Building")
        sh("./build.sh")
    if not APP.exists():
        raise SystemExit("build/Cascade.app not found; run ./build.sh")

    plist = APP / "Contents" / "Info.plist"
    version = sh("/usr/libexec/PlistBuddy", "-c", "Print CFBundleShortVersionString", str(plist))
    min_os = sh("/usr/libexec/PlistBuddy", "-c", "Print LSMinimumSystemVersion", str(plist))
    previous_path = DOCS / "app-facts.json"
    previous = json.loads(previous_path.read_text()) if previous_path.exists() else {}

    print("→ Code, tests, coverage, size, security")
    report = {
        "version": version,
        "min_macos": min_os.split(".")[0],
        "date": datetime.date.today().isoformat(),
        "machine": machine(),
        "code": code_stats(),
        "tests": test_stats(),
        "coverage": coverage_stats(),
        "size": size_stats(version),
        "security": security_stats(),
    }
    print("→ Runtime (samples the running app for 20 s, then benchmarks)")
    report["runtime"] = runtime_stats(previous)

    DOCS.mkdir(exist_ok=True)
    previous_path.write_text(json.dumps(report, indent=2) + "\n")
    (DOCS / "app-facts.svg").write_text(label_svg(report))

    # Diagrams: rendered to SVG with Graphviz (GitHub shrinks wide Mermaid diagrams until unreadable).
    if subprocess.run(["which", "dot"], capture_output=True).returncode == 0:
        graph = code_graph_dot()
        (DOCS / "code-graph.dot").write_text(graph)
        render_dot(graph, DOCS / "code-graph.svg")
        render_dot((DOCS / "cascade-flow.dot").read_text(), DOCS / "cascade-flow.svg")
        diagrams = ", docs/code-graph.svg, docs/cascade-flow.svg"
    else:
        diagrams = " (diagrams skipped: brew install graphviz)"
    print(f"✓ docs/app-facts.svg, docs/app-facts.json{diagrams} updated for {version}")


if __name__ == "__main__":
    main()
