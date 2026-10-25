import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { tokenizeLean } from "../src/leanSyntax.ts";

test("highlighting preserves every character of the actual Lean proof modules", () => {
  for (const name of [
    "KernelMerkle",
    "PaymentModel",
    "LedgerProofs",
    "SHA512",
    "SHA512Fast",
  ]) {
    const source = readFileSync(
      new URL(`../../LeanXRPL/${name}.lean`, import.meta.url),
      "utf8",
    );
    assert.equal(
      tokenizeLean(source)
        .map((token) => token.text)
        .join(""),
      source,
      name,
    );
  }
  for (const source of [
    "",
    "-- partial source page",
    "/- unfinished ∀\n",
    '"unfinished \\',
    "🙂\r\n\t∀ x, x ≤ 0xFF",
  ])
    assert.equal(
      tokenizeLean(source)
        .map((token) => token.text)
        .join(""),
      source,
    );
});

test("Lean comments, escaped strings, raw strings and primed names keep their lexical boundaries", () => {
  const source = String.raw`/- outer /- nested -/ still a comment -/
def foo' : String := "quote: \" -- not a comment"
def raw := r##"/- not a comment -/ "# still raw"##
def alpha : Char := 'α'
def newline : Char := '\n'
-- theorem ignored : Nat := 0xFF
theorem «a named theorem» : Nat = Nat := by rfl
#print axioms foo'
example : Int := 1+/- adjacent comment -/2-1
`;
  const tokens = tokenizeLean(source);
  const values = (kind: string) =>
    tokens.filter((token) => token.kind === kind).map((token) => token.text);
  assert.equal(tokens.map((token) => token.text).join(""), source);
  assert.deepEqual(values("comment"), [
    "/- outer /- nested -/ still a comment -/",
    "-- theorem ignored : Nat := 0xFF",
    "/- adjacent comment -/",
  ]);
  assert.deepEqual(values("string"), [
    String.raw`"quote: \" -- not a comment"`,
    'r##"/- not a comment -/ "# still raw"##',
    "'α'",
    String.raw`'\n'`,
  ]);
  assert.ok(values("declaration").includes("foo'"));
  assert.ok(values("declaration").includes("«a named theorem»"));
  assert.ok(values("keyword").includes("#print"));
  assert.deepEqual(values("number"), ["1", "2", "1"]);
});
