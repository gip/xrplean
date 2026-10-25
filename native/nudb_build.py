"""Required native NuDB build flags. Prefixes contain include/ and lib/."""
import json
import os
from pathlib import Path
import sys


def prefix(package, header):
    explicit = os.environ.get(package.upper() + '_PREFIX')
    if explicit:
        path = Path(explicit).expanduser().resolve()
        if not (path / 'include' / header).is_file():
            raise SystemExit(f'{package.upper()}_PREFIX does not contain include/{header}')
        return path
    bundled = Path(__file__).resolve().parents[1] / 'vendor' / package
    if (bundled / 'include' / header).is_file():
        return bundled
    for cache in ['.conan2-nix', '.conan2']:
        for path in sorted((Path.home() / cache).glob(f'p/{package}*/p')):
            if (path / 'include' / header).is_file():
                return path
    for path in map(Path, ['/opt/homebrew', '/usr/local', '/usr']):
        if (path / 'include' / header).is_file():
            return path
    return None


nudb, boost = prefix('nudb', 'nudb/version.hpp'), prefix('boost', 'boost/version.hpp')
if nudb is None or boost is None:
    raise SystemExit('XL requires NuDB and Boost; set NUDB_PREFIX and BOOST_PREFIX to prefixes containing include/ and lib/')
enabled = True
cflags = ['-DLX_WITH_NUDB=' + str(int(enabled))]
libs = ['-lc++' if sys.platform == 'darwin' else '-lstdc++', '-pthread']
if enabled:
    cflags += ['-I' + str(nudb / 'include'), '-I' + str(boost / 'include')]
    for name in ['thread', 'chrono', 'atomic']:
        archive = boost / 'lib' / f'libboost_{name}.a'
        libs += [str(archive)] if archive.is_file() else ['-L' + str(boost / 'lib'), '-lboost_' + name]
print(json.dumps(cflags if sys.argv[1] == '--cflags' else libs))
