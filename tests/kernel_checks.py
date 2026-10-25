"""The actual Lean kernel must reject false hashes and Payment certificates."""
from pathlib import Path
import subprocess
import re
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HEADER = '''import LeanXRPL.KernelMerkle
import LeanXRPL.SHA512Fast
import LeanXRPL.PaymentModel
set_option maxRecDepth 100000
set_option maxHeartbeats 0
open LeanXRPL
'''


def check(source, expected):
    with tempfile.TemporaryDirectory(prefix='xl-kernel-') as folder:
        file = Path(folder) / 'Check.lean'
        file.write_text(HEADER + source)
        p = subprocess.run(['lake', 'env', 'lean', str(file)], cwd=ROOT,
                           capture_output=True, text=True, timeout=120)
        assert (p.returncode == 0) == expected, (p.stdout, p.stderr)
        return p.stdout


def main():
    import hashlib
    expected = int.from_bytes(hashlib.sha512(b'abc').digest()[:32], 'big')
    check(f'example : SHA512.half [97,98,99] = {expected} := by decide +kernel\n', True)
    check('example : SHA512.half [97,98,99] = 0 := by decide +kernel\n', False)
    # Exercise the equivalence bridge used by generated node hash certificates,
    # including SHA-512 padding boundaries and multiple compression blocks.
    source = ''
    for size in (0, 3, 111, 112, 127, 128, 129, 516):
        data = bytes(i % 256 for i in range(size))
        value = int.from_bytes(hashlib.sha512(data).digest()[:32], 'big')
        literal = '[' + ','.join(map(str, data)) + ']'
        source += (f'theorem vector_{size} : SHA512.half {literal} = {value} := '
                   f'(SHA512Fast.half_eq _).symm.trans '
                   f'(by decide +kernel : SHA512Fast.half {literal} = {value})\n'
                   f'#print axioms vector_{size}\n')
    audit = check(source, True)
    groups = re.findall(r'depends on axioms:\s*\[([^\]]*)\]', audit)
    assert len(groups) == 8 and all(g.strip() == 'propext' for g in groups), audit
    check('example : SHA512.half [97,98,99] = 0 := '
          '(SHA512Fast.half_eq _).symm.trans '
          '(by decide +kernel : SHA512Fast.half [97,98,99] = 0)\n', False)
    facts = '''def facts : PaymentModel.Facts := {
      kind := .xrp, amount := 30, fee := 10,
      sourceXrpBefore := 100, sourceXrpAfter := 60,
      destinationXrpBefore := 20, destinationXrpAfter := 50,
      sequenceBefore := 100, sequenceAfter := 101, transactionSequence := 100,
      identityOK := true, frameOK := true, historyOK := true, deliveryOK := true }
'''
    check(facts + 'example : PaymentModel.Valid facts := by decide\n', True)
    check(facts.replace('destinationXrpAfter := 50', 'destinationXrpAfter := 49') +
          'example : PaymentModel.Valid facts := by decide\n', False)
    check('example : KernelMerkle.apply .empty ⟨0,none,none⟩ = some .empty := by rfl\n', False)
    print('PASS real kernel accepts correct facts and rejects false SHA-512Half, incorrect recipient credit, and invalid Merkle edits')


if __name__ == '__main__':
    main()
