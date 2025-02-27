(* Yoann Padioleau
 *
 * Copyright (C) 2019-2021 r2c
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * version 2.1 as published by the Free Software Foundation, with the
 * special exception on linking described in file license.txt.
 *
 * This library is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the file
 * license.txt for more details.
 *)
module G = AST_generic
module MV = Metavariable

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)
(* Data structures to represent a Semgrep rule (=~ AST of a rule).
 *
 * See also Mini_rule.ml where formula and many other features disappear.
 *
 * TODO:
 *  - parse equivalences
 *)

(*****************************************************************************)
(* Position information *)
(*****************************************************************************)

(* This is similar to what we do in AST_generic to get precise
 * error location when a rule is malformed.
 *)
type tok = AST_generic.tok [@@deriving show, eq, hash]

type 'a wrap = 'a AST_generic.wrap [@@deriving show, eq, hash]

(* To help report pattern errors in simple mode in the playground *)
type 'a loc = {
  pattern : 'a;
  t : tok;
  path : string list; (* path to pattern in YAML rule *)
}
[@@deriving show, eq]

(*****************************************************************************)
(* Extended languages *)
(*****************************************************************************)

(* eXtended language, stored in the languages: field in the rule.
 * less: merge with xpattern_kind? *)
type xlang =
  (* for "real" semgrep (the first language is used to parse the pattern) *)
  | L of Lang.t * Lang.t list
  (* for pattern-regex (referred as 'regex' or 'none' in languages:) *)
  | LRegex
  (* for spacegrep *)
  | LGeneric
[@@deriving show, eq]

exception InternalInvalidLanguage of string (* rule id *) * string (* msg *)

(* coupling: Parse_mini_rule.parse_languages *)
let xlang_of_string ?id:(id_opt = None) s =
  match s with
  | "none"
  | "regex" ->
      LRegex
  | "generic" -> LGeneric
  | _ -> (
      match Lang.lang_of_string_opt s with
      | None -> (
          match id_opt with
          | None -> failwith (Lang.unsupported_language_message s)
          | Some id ->
              raise
                (InternalInvalidLanguage
                   (id, Common.spf "unsupported language: %s" s)))
      | Some l -> L (l, []))

let string_of_xlang = function
  | L (l, _) -> Lang.string_of_lang l
  | LRegex -> "regex"
  | LGeneric -> "generic"

(*****************************************************************************)
(* Extended patterns *)
(*****************************************************************************)

type xpattern = {
  pat : xpattern_kind;
  (* Regarding @equal below, even if two patterns have different indentation,
   * we don't care. We rely only on the equality on pat, which will
   * abstract away line positions.
   * TODO: right now we have some false positives, e.g., in Python
   * assert(...) and assert ... are considered equal AST-wise
   * but it might be a bug!.
   *)
  pstr : string wrap; [@equal fun _ _ -> true]
  (* Unique id, incremented via a gensym()-like function in mk_pat().
   * This is used to run the patterns in a formula in a batch all-at-once
   * and remember what was the matching results for a certain pattern id.
   *)
  pid : pattern_id; [@equal fun _ _ -> true]
}

and xpattern_kind =
  | Sem of Pattern.t * Lang.t (* language used for parsing the pattern *)
  | Spacegrep of Spacegrep.Pattern_AST.t
  | Regexp of regexp
  | Comby of string

and regexp = Regexp_engine.Pcre_engine.t

(* used in the engine for rule->mini_rule and match_result gymnastic *)
and pattern_id = int [@@deriving show, eq]

(* helpers *)

let count = ref 0

let mk_xpat pat pstr =
  incr count;
  { pat; pstr; pid = !count }

let is_regexp xpat =
  match xpat.pat with
  | Regexp _ -> true
  | _ -> false

(*****************************************************************************)
(* Formula (patterns boolean composition) *)
(*****************************************************************************)

(* Classic boolean-logic/set operators with text range set semantic.
 * The main complication is the handling of metavariables and especially
 * negation in the presence of metavariables.
 *
 * todo? enforce invariant that Not/MetavarCond can only appear in And?
 * move MetavarCond out of leaf in an additional element in And.
 *)
type formula =
  | Leaf of leaf
  | And of tok * formula list (* see Match_rules.split_and() *)
  | Or of tok * formula list
  (* There are currently restrictions on where a Not can appear in a formula.
   * It must be inside an And to be intersected with "positive" formula.
   * But this could change? If we were moving to a different range semantic?
   *)
  | Not of tok * formula

and leaf =
  (* pattern: and pattern-inside: are actually slightly different so
   * we need to keep the information around.
   * (see tests/OTHER/rules/inside.yaml)
   * The same is true for pattern-not and pattern-not-inside
   * (see tests/OTHER/rules/negation_exact.yaml)
   *)
  | P of xpattern (* a leaf pattern *) * inside option
  (* This can also only appear inside an And *)
  | MetavarCond of tok * metavar_cond

(* todo: try to remove this at some point, but difficult. See
 * https://github.com/returntocorp/semgrep/issues/1218
 *)
and inside = Inside

and metavar_cond =
  | CondEval of AST_generic.expr (* see Eval_generic.ml *)
  (* todo: at some point we should remove CondRegexp and have just
   * CondEval, but for now there are some
   * differences between using the matched text region of a metavariable
   * (which we use for MetavarRegexp) and using its actual value
   * (which we use for MetavarComparison), which translate to different
   * calls in Eval_generic.ml
   * update: this is also useful to keep separate from CondEval for
   * the "regexpizer" optimizer (see Analyze_rule.ml).
   *)
  | CondRegexp of MV.mvar * regexp
  | CondNestedFormula of MV.mvar * xlang option * formula
[@@deriving show, eq]

(*****************************************************************************)
(* Old Formula style *)
(*****************************************************************************)

(* Unorthodox original pattern compositions.
 * See also the JSON schema in rule_schema.yaml
 *)
type formula_old =
  (* pattern: *)
  | Pat of xpattern
  (* pattern-not: *)
  | PatNot of tok * xpattern
  | PatExtra of tok * extra
  (* pattern-inside: *)
  | PatInside of xpattern
  (* pattern-not-inside: *)
  | PatNotInside of tok * xpattern
  (* pattern-either: Or *)
  | PatEither of tok * formula_old list
  (* patterns: And *)
  | Patterns of tok * formula_old list

(* extra conditions, usually on metavariable content *)
and extra =
  | MetavarRegexp of MV.mvar * regexp
  | MetavarPattern of MV.mvar * xlang option * formula
  | MetavarComparison of metavariable_comparison
  (* arbitrary code! dangerous! *)
  | PatWherePython of string

(* See also engine/Eval_generic.ml *)
and metavariable_comparison = {
  metavariable : MV.mvar;
  comparison : AST_generic.expr;
  (* I don't think those are really needed; they can be inferred
   * from the values *)
  strip : bool option;
  base : int option;
}
[@@deriving show, eq]

(* pattern formula *)
type pformula = New of formula | Old of formula_old [@@deriving show, eq]

(*****************************************************************************)
(* The rule *)
(*****************************************************************************)

(* alt:
 *     type common = { id : string; ... }
 *     type search = { common : common; formula : pformula; }
 *     type taint  = { common : common; spec : taint_spec; }
 *     type rule   = Search of search | Taint of taint
 *)

type taint_spec = {
  sources : pformula list;
  sanitizers : pformula list;
  sinks : pformula list;
}
[@@deriving show]

type mode = Search of pformula | Taint of taint_spec [@@deriving show]

(* TODO? just reuse Error_code.severity *)
type severity = Error | Warning | Info [@@deriving show]

type rule = {
  (* MANDATORY fields *)
  id : rule_id wrap;
  mode : mode;
  message : string;
  severity : severity;
  languages : xlang;
  (* OPTIONAL fields *)
  options : Config_semgrep.t option;
  (* deprecated? todo: parse them *)
  equivalences : string list option;
  fix : string option;
  fix_regexp : (regexp * int option * string) option;
  paths : paths option;
  (* ex: [("owasp", "A1: Injection")] but can be anything *)
  metadata : JSON.t option;
}

and rule_id = string

and paths = {
  (* not regexp but globs *)
  include_ : string list;
  exclude : string list;
}
[@@deriving show]

(* alias *)
type t = rule [@@deriving show]

type rules = rule list [@@deriving show]

(*****************************************************************************)
(* Error Management *)
(*****************************************************************************)

exception InvalidLanguage of rule_id * string * Parse_info.t

(* TODO: the Parse_info.t is not precise for now, it corresponds to the
 * start of the pattern *)
exception
  InvalidPattern of
    rule_id * string * xlang * string (* exn *) * Parse_info.t * string list

exception InvalidRegexp of rule_id * string * Parse_info.t

(* general errors *)
exception InvalidYaml of string * Parse_info.t

exception DuplicateYamlKey of string * Parse_info.t

(* less: could be merged with InvalidYaml *)
exception InvalidRule of rule_id * string * Parse_info.t

exception UnparsableYamlException of string

exception ExceededMemoryLimit of string

(*****************************************************************************)
(* Visitor/extractor *)
(*****************************************************************************)
(* currently used in Check_rule.ml metachecker *)
let rec visit_new_formula f formula =
  match formula with
  | Leaf (P (p, _)) -> f p
  | Leaf (MetavarCond _) -> ()
  | Not (_, x) -> visit_new_formula f x
  | Or (_, xs)
  | And (_, xs) ->
      xs |> List.iter (visit_new_formula f)

(* used by the metachecker for precise error location *)
let tok_of_formula = function
  | And (t, _)
  | Or (t, _)
  | Not (t, _) ->
      t
  | Leaf (P (p, _)) -> snd p.pstr
  | Leaf (MetavarCond (t, _)) -> t

let kind_of_formula = function
  | Leaf (P _) -> "pattern"
  | Leaf (MetavarCond _) -> "condition"
  | Or _
  | And _
  | Not _ ->
      "formula"

(*****************************************************************************)
(* Converters *)
(*****************************************************************************)

(* Substitutes `$MVAR` with `int($MVAR)` in cond. *)
let rewrite_metavar_comparison_strip mvar cond =
  let visitor =
    Map_AST.mk_visitor
      {
        Map_AST.default_visitor with
        Map_AST.kexpr =
          (fun (k, _) e ->
            (* apply on children *)
            let e = k e in
            match e.G.e with
            | G.N (G.Id ((s, tok), _idinfo)) when s = mvar ->
                let py_int = G.Id (("int", tok), G.empty_id_info ()) in
                G.Call (G.N py_int |> G.e, G.fake_bracket [ G.Arg e ]) |> G.e
            | _ -> e);
      }
  in
  visitor.Map_AST.vexpr cond

let convert_extra x =
  match x with
  | MetavarRegexp (mvar, re) -> CondRegexp (mvar, re)
  | MetavarPattern (mvar, opt_xlang, formula) ->
      CondNestedFormula (mvar, opt_xlang, formula)
  | MetavarComparison comp -> (
      match comp with
      (* do we care about strip and base? should not Eval_generic handle it?
       * - base is handled automatically, in the Generic AST all integer
       *   literals are normalized and represented in base 10.
       * - for strip the user should instead use a more complex condition that
       *   converts the string into a number (e.g., "1234" in 1234).
       *)
      | { metavariable = mvar; comparison; strip; base = _NOT_NEEDED } ->
          let cond =
            (* if strip=true we rewrite the condition and insert Python's `int`
             * function to parse the integer value of mvar. *)
            match strip with
            | None
            | Some false ->
                comparison
            | Some true -> rewrite_metavar_comparison_strip mvar comparison
          in
          CondEval cond)
  | PatWherePython _ ->
      (*
  logger#debug "convert_extra: %s" s;
  Parse_rule.parse_metavar_cond s
*)
      failwith (Common.spf "convert_extra: TODO: %s" (show_extra x))

let (convert_formula_old : formula_old -> formula) =
 fun e ->
  let rec aux e =
    match e with
    | Pat x -> Leaf (P (x, None))
    | PatInside x -> Leaf (P (x, Some Inside))
    | PatNot (t, x) -> Not (t, Leaf (P (x, None)))
    | PatNotInside (t, x) -> Not (t, Leaf (P (x, Some Inside)))
    | PatEither (t, xs) ->
        let xs = List.map aux xs in
        Or (t, xs)
    | Patterns (t, xs) ->
        let xs = List.map aux xs in
        And (t, xs)
    | PatExtra (t, x) ->
        let e = convert_extra x in
        Leaf (MetavarCond (t, e))
  in
  aux e

let formula_of_pformula = function
  | New f -> f
  | Old oldf -> convert_formula_old oldf

let partition_rules rules =
  rules
  |> Common.partition_either (fun r ->
         match r.mode with
         | Search f -> Left (r, f)
         | Taint s -> Right (r, s))
