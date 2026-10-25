export type LeanToken = {
  kind:
    | "plain"
    | "keyword"
    | "declaration"
    | "type"
    | "string"
    | "number"
    | "comment"
    | "operator";
  text: string;
};

const keywords = new Set(
  `
  abbrev axiom by class coinductive def deriving do else end example export
  extends forall from fun have if import in include inductive infix infixl
  infixr instance let macro macro_rules match mutual namespace noncomputable
  notation opaque open partial postfix prefix private protected public section
  set_option structure syntax term then theorem universe universes unsafe
  variable variables where with
  admit aesop all_goals apply assumption cases cases' change constructor
  contradiction conv decide exact exfalso fail_if_success first focus
  generalize guard hnf induction intro intros left next obtain omega rcases
  refine rename_i repeat rfl right rw simp simp_all simpa skip specialize
  subst suffices trivial try unfold unless unreachable when
`
    .split(/\s+/)
    .filter(Boolean),
);
const declarations = new Set([
  "abbrev",
  "axiom",
  "class",
  "def",
  "inductive",
  "opaque",
  "structure",
  "theorem",
]);

/** Cosmetic, lossless lexical highlighting. Tokens remain React text nodes;
 * this never interprets Lean source, evaluates it, or manufactures HTML. */
export function tokenizeLean(source: string): LeanToken[] {
  const tokens: LeanToken[] = [];
  const word = /[\p{L}_][\p{L}\p{N}\p{M}_'!?]*/uy;
  const number = /(?:0[xX][\da-fA-F]+|0[bB][01]+|\d+(?:\.\d+)?)/y;
  const rawString = /r(#+)?"/y;
  const character =
    /'(?:\\(?:x[\da-fA-F]{2}|u[\da-fA-F]{4}|U[\da-fA-F]{8}|[^\r\n])|[^'\\\r\n])'/uy;
  const operator = /[\p{Sm}:=|&!+*%<>∧∨¬∀∃λ⟨⟩←→↔]+/uy;
  let offset = 0;
  let expectName = false;
  const emit = (kind: LeanToken["kind"], end: number) => {
    const text = source.slice(offset, end);
    const previous = tokens.at(-1);
    if (kind === "plain" && previous?.kind === kind) previous.text += text;
    else tokens.push({ kind, text });
    offset = end;
  };
  const at = (pattern: RegExp) => {
    pattern.lastIndex = offset;
    return pattern.exec(source);
  };
  while (offset < source.length) {
    if (source.startsWith("--", offset)) {
      const end = source.indexOf("\n", offset);
      emit("comment", end < 0 ? source.length : end);
    } else if (source.startsWith("/-", offset)) {
      let depth = 1,
        end = offset + 2;
      while (end < source.length && depth > 0) {
        if (source.startsWith("/-", end)) {
          depth++;
          end += 2;
        } else if (source.startsWith("-/", end)) {
          depth--;
          end += 2;
        } else end++;
      }
      emit("comment", end);
    } else if (source[offset] === "«") {
      const end = source.indexOf("»", offset + 1);
      emit(
        expectName ? "declaration" : "plain",
        end < 0 ? source.length : end + 1,
      );
      expectName = false;
    } else {
      const raw = at(rawString);
      if (raw) {
        const closing = '"' + (raw[1] ?? "");
        const end = source.indexOf(closing, offset + raw[0].length);
        emit("string", end < 0 ? source.length : end + closing.length);
      } else if (source[offset] === '"') {
        let end = offset + 1;
        while (end < source.length) {
          if (source[end] === "\\") end = Math.min(source.length, end + 2);
          else if (source[end++] === '"') break;
        }
        emit("string", end);
      } else {
        const char = at(character),
          digits = at(number),
          identifier = at(word),
          symbol = at(operator);
        if (char) emit("string", offset + char[0].length);
        else if (digits) emit("number", offset + digits[0].length);
        else if (identifier) {
          const text = identifier[0];
          const kind = keywords.has(text)
            ? "keyword"
            : expectName
              ? "declaration"
              : /^\p{Lu}/u.test(text)
                ? "type"
                : "plain";
          expectName = declarations.has(text);
          emit(kind, offset + text.length);
        } else if (source[offset] === "#") {
          word.lastIndex = offset + 1;
          const command = word.exec(source);
          emit(
            command ? "keyword" : "plain",
            offset + 1 + (command?.[0].length ?? 0),
          );
        } else if (symbol) emit("operator", offset + symbol[0].length);
        else
          emit(
            "plain",
            offset + (source.codePointAt(offset)! > 0xffff ? 2 : 1),
          );
      }
    }
  }
  return tokens;
}
