#!/usr/bin/env python3
"""Install a checksum-pinned official OSS CAD Suite binary release locally."""
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]
LOCK = Path(__file__).with_name('oss-cad-suite.lock.json')


def host_key():
    systems = {'Darwin': 'darwin', 'Linux': 'linux'}
    machines = {'arm64': 'arm64', 'aarch64': 'arm64', 'x86_64': 'x64', 'AMD64': 'x64'}
    try:
        return systems[platform.system()] + '-' + machines[platform.machine()]
    except KeyError:
        raise SystemExit('Supported hosts: macOS/Linux on ARM64 or x86-64; use WSL2 on Windows.')


def install_path(lock):
    return ROOT / '.tools/oss-cad-suite' / lock['release'] / host_key() / 'oss-cad-suite'


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    lock = json.loads(LOCK.read_text())
    key = host_key()
    asset = lock['assets'][key]
    destination = install_path(lock)
    marker = destination / '.setsuna-install.json'
    expected = {'release': lock['release'], 'host': key, 'sha256': asset['sha256']}
    if marker.exists() and json.loads(marker.read_text()) == expected:
        print(f'Already installed: {destination}')
        return
    if destination.exists():
        raise SystemExit(f'Unmanaged/incomplete installation: {destination}; inspect it before retrying.')
    if not hasattr(tarfile, 'data_filter'):
        raise SystemExit('Python with tarfile.data_filter is required (Python 3.12+, or a security-backported version).')
    cache = ROOT / '.tools/cache'
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / asset['file']
    if not archive.exists():
        partial = archive.with_suffix(archive.suffix + '.part')
        subprocess.run(['curl', '--fail', '--location', '--retry', '3', '--retry-all-errors',
                        '--continue-at', '-', '--speed-limit', '1024', '--speed-time', '30', '--connect-timeout', '30',
                        '--output', str(partial), asset['url']], check=True)
        if partial.stat().st_size != asset['size'] or sha256(partial) != asset['sha256']:
            raise SystemExit(f'Archive verification failed: {partial}; not extracting.')
        partial.replace(archive)
    if archive.stat().st_size != asset['size'] or sha256(archive) != asset['sha256']:
        raise SystemExit(f'Cached archive verification failed: {archive}; not extracting.')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='extract-', dir=destination.parent) as temp:
        print(f'Extracting verified {asset["file"]}', flush=True)
        with tarfile.open(archive, 'r:gz') as package:
            package.extractall(temp, filter='data')
        source = Path(temp) / 'oss-cad-suite'
        for tool in ('yosys', 'nextpnr-himbaechel', 'gowin_pack', 'openFPGALoader', 'iverilog', 'vvp'):
            if not (source / 'bin' / tool).is_file():
                raise SystemExit(f'Release missing required tool: {tool}')
        # Only publish a complete installation. Failed extraction/activation
        # leaves the verified download available for the next invocation.
        if platform.system() == 'Darwin':
            subprocess.run(['xattr', '-dr', 'com.apple.quarantine', str(source)], check=True)
        (source / marker.name).write_text(json.dumps(expected, indent=2) + '\n')
        shutil.move(str(source), str(destination))
    print(f'Installed: {destination}')


if __name__ == '__main__':
    try:
        main()
    except (OSError, subprocess.CalledProcessError, tarfile.TarError) as error:
        sys.exit(str(error))
