import Lake
open Lake DSL

def pkgFlags (kind name : String) : IO (Array String) := do
  let out ← IO.Process.output {cmd := "pkg-config", args := #[kind, name]}
  if out.exitCode != 0 then throw <| IO.userError s!"{name} development files required: {out.stderr}"
  return (out.stdout.trimAscii.toString.splitOn " ").filter (· != "") |>.toArray

def sqliteLibs : IO (Array String) := do
  let flags ← pkgFlags "--libs" "sqlite3"
  if System.Platform.isOSX && !flags.any (·.startsWith "-L") then
    let p ← IO.Process.output {cmd := "brew", args := #["--prefix", "sqlite"]}
    if p.exitCode != 0 then throw <| IO.userError "Homebrew SQLite required on macOS"
    return flags ++ #["-L" ++ p.stdout.trimAscii.toString ++ "/lib"]
  return flags

def nudbFlags (kind : String) : IO (Array String) := do
  let out ← IO.Process.output {cmd := "python3", args := #["native/nudb_build.py",kind]}
  if out.exitCode != 0 then throw <| IO.userError out.stderr
  let values ← IO.ofExcept ((Lean.Json.parse out.stdout).bind Lean.Json.getArr?)
  values.mapM (fun value => IO.ofExcept value.getStr?)

package xrplean where
  moreLinkArgs := (run_io pkgFlags "--libs" "openssl") ++ (run_io sqliteLibs) ++ (run_io nudbFlags "--libs")

extern_lib xl_native pkg := do
  let lean ← getLeanInstall
  let ssl ← pkgFlags "--cflags" "openssl"
  let sqlite ← pkgFlags "--cflags" "sqlite3"
  let mut objects := #[]
  for file in ["bridge", "store", "xl"] do
    let mut src ← inputFile (pkg.dir / "native" / (file ++ ".c")) true
    if file == "store" then
      for inc in ["history.inc", "node_compact.inc", "node_export.inc", "node_view.inc", "node_scope.inc", "nudb_store.h"] do
        let dep ← inputFile (pkg.dir / "native" / inc) true
        src := src.zipWith (fun path _ => path) dep
    let obj ← buildO (pkg.buildDir / "native" / (file ++ ".o")) src #[]
      (#["-I", lean.includeDir.toString, "-std=c11", "-O2", "-fPIC", "-Wno-deprecated-declarations"] ++ ssl ++ sqlite) "cc"
    objects := objects.push obj
  let mut src ← inputFile (pkg.dir / "native" / "nudb_store.cpp") true
  for file in ["nudb_store.h", "nudb_build.py"] do
    let dependency ← inputFile (pkg.dir / "native" / file) true
    src := src.zipWith (fun path _ => path) dependency
  let flags ← nudbFlags "--cflags"
  let obj ← buildO (pkg.buildDir / "native" / "nudb_store.o") src #[]
    (#["-std=c++17", "-O2", "-fPIC", "-pthread"] ++ flags) "c++"
  buildStaticLib (pkg.staticLibDir / nameToStaticLib "xl_native") (objects.push obj)

lean_lib LeanXRPL
lean_lib XL where
  srcDir := "lib"
lean_lib XLB
lean_lib XLC

@[default_target] lean_exe xlb where
  root := `XLB.Main
@[default_target] lean_exe xlc where
  root := `XLC.Main

lean_exe state_tree_bench where
  srcDir := "tests"
  root := `StateTreeBench

lean_exe state_view_probe where
  srcDir := "tests"
  root := `StateViewProbe
