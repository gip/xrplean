"""Recompile an XL Batch certificate and check its exported literal/hash binding.
This utility checks bindings only; XRPL serialization and policy remain in Lean.
Use the original approved checkout (including its pinned compiled BatchPolicy).
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

HEADER = ('import LeanXRPL.BatchPolicy\nopen LeanXRPL.BatchPolicy\n'
          'set_option maxRecDepth 10000\nset_option maxHeartbeats 4000000\n')
SUFFIX = ('theorem batch_certified : Certified policy batch raw := check_sound (by decide)\n'
          'theorem exact_bytes : raw = serialize policy batch := certified_bytes batch_certified\n'
          '#print axioms batch_certified\n#print axioms exact_bytes\n')
ARTIFACTS = {'request.json','transaction.json','unsigned.hex','policy.json','Certificate.lean',
             'BatchPolicy.lean','lean-toolchain','kernel.log','binding.json'}
MODULES = {'LeanXRPL/BatchPolicy.lean','.lake/build/lib/lean/LeanXRPL/BatchPolicy.olean'}


def sha(data):
    return hashlib.sha256(data).hexdigest().upper()


def verify(folder, root):
    manifest = json.loads((folder/'manifest.json').read_text())
    names = [entry['name'] for entry in manifest]
    if len(names)!=len(set(names)) or set(names)!=ARTIFACTS|MODULES:
        raise ValueError('unexpected manifest files')
    for entry in manifest:
        name = entry['name']
        path = (root if name in MODULES else folder)/name
        if sha(path.read_bytes())!=entry['sha256']:
            raise ValueError(f'artifact digest mismatch: {name}')
    if (folder/'BatchPolicy.lean').read_bytes()!=(root/'LeanXRPL/BatchPolicy.lean').read_bytes():
        raise ValueError('proof definition differs from approved checkout')
    if (folder/'lean-toolchain').read_bytes()!=(root/'lean-toolchain').read_bytes():
        raise ValueError('toolchain mismatch')
    source = (folder/'Certificate.lean').read_text()
    # Only the generated, data-only template is executable. In particular, no
    # added commands, imports, axioms, or changed theorem types are permitted.
    pattern = (re.escape(HEADER) +
               r'def policy : Policy := ⟨[0-9]+,\[[0-9,]*\],[0-9]+⟩\n' +
               r'def batch : Batch := ⟨[0-9,⟨⟩\[\]]+⟩\n' +
               r'def raw : List Nat := (\[[0-9,]*\])\n' + re.escape(SUFFIX))
    match = re.fullmatch(pattern,source)
    if not match:
        raise ValueError('certificate is not the approved data-only template')
    raw = bytes(json.loads(match.group(1)))
    if (folder/'unsigned.hex').read_text()!=raw.hex().upper()+'\n':
        raise ValueError('unsigned bytes differ from certificate literals')
    binding = json.loads((folder/'binding.json').read_text())
    if binding['unsigned_sha256']!=sha(raw) or binding['certificate_sha256']!=sha(source.encode()):
        raise ValueError('literal binding digest mismatch')
    signing = hashlib.sha512(b'STX\x00'+raw).digest()[:32].hex().upper()
    if binding['signing_digest']!=signing:
        raise ValueError('signing digest mismatch')
    policy = json.loads((folder/'policy.json').read_text())
    canonical = json.dumps(policy,sort_keys=True,separators=(',',':'),ensure_ascii=False)
    if binding['policy_digest']!=sha(canonical.encode()):
        raise ValueError('policy digest mismatch')
    # Reconstruct JSON/bytes/policy in Lean as well: an attacker rehashing a
    # modified manifest must not make unrelated transaction JSON appear proved.
    reconstructed = subprocess.run([str(root/'.lake/build/bin/xlb'),'--verify-batch-artifacts',str(folder.resolve())],
                                   cwd=root,capture_output=True,text=True,timeout=30)
    if reconstructed.returncode:
        raise ValueError('Lean export binding failed:\n'+reconstructed.stdout+reconstructed.stderr)
    checked = subprocess.run(['lake','env','lean','--memory=2048',str((folder/'Certificate.lean').resolve())],
                             cwd=root,capture_output=True,text=True,timeout=120)
    if checked.returncode:
        raise ValueError('kernel compilation failed:\n'+checked.stdout+checked.stderr)
    audits = [line for line in checked.stdout.splitlines() if 'depends on axioms:' in line or 'does not depend on any axioms' in line]
    if len(audits)!=2:
        raise ValueError('missing theorem axiom audit')
    for line in audits:
        if 'depends on axioms:' in line:
            axioms = line.split('depends on axioms:',1)[1].strip().strip('[]').split(',')
            if any(a.strip() not in {'','propext','Classical.choice','Quot.sound'} for a in axioms):
                raise ValueError('unexpected proof axiom')
    return dict(status='kernel_checked',signing_digest=signing,policy_digest=binding['policy_digest'])


if __name__=='__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('attempt_directory',type=Path)
    parser.add_argument('--project-root',type=Path,default=Path(__file__).resolve().parents[1])
    parser.add_argument('--policy-digest',help='require the policy digest previously reviewed by the operator')
    args=parser.parse_args()
    try:
        result = verify(args.attempt_directory.resolve(),args.project_root.resolve())
        if args.policy_digest and args.policy_digest.upper()!=result['policy_digest']:
            raise ValueError('certificate policy differs from the reviewed policy digest')
        print(json.dumps(result))
    except (ValueError,OSError,KeyError,subprocess.TimeoutExpired) as error:
        parser.exit(1,str(error)+'\n')
