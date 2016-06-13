open Malfunction
open Malfunction_sexp

type inttype = [`Int | `Int32 | `Int64 | `Bigint]
type intconst = [`Int of int | `Int32 of Int32.t | `Int64 of Int64.t | `Bigint of Z.t]
type unary_int_op =
  [`Neg | `Not]
type binary_int_op =
  [ `Add | `Sub | `Mul | `Div | `Mod
  | `And | `Or | `Xor | `Lsl | `Lsr | `Asr
  | `Lt | `Gt | `Lte | `Gte | `Eq ]

type sequence_type =
  [`Array | `Bytevec | `Floatvec]
type mutability =
  [ `Imm | `Mut ]

type block_tag = int
let max_tag = 200
let tag_of_int n =
  if 0 <= n && n < max_tag then
    n
  else
    invalid_arg "tag out of range"

type t =
| Mvar of Ident.t
| Mlambda of Ident.t list * t
| Mapply of t * t list
| Mlet of binding list * t
| Mint of intconst
| Mstring of string
| Mglobal of Longident.t
| Mswitch of t * (case list * t) list

(* Integers *)
| Mintop1 of unary_int_op * inttype * t
| Mintop2 of binary_int_op * inttype * t * t

(* Sequences *)
| Mseqget of sequence_type * t * t
| Mseqset of sequence_type * t * t * t
| Mseqlen of sequence_type * t

(* Blocks *)
| Mblock of int * t list
| Mfield of int * t

and binding =
  [ `Unnamed of t | `Named of Ident.t * t | `Recursive of (Ident.t * t) list ]

and case = [`Tag of int | `Deftag | `Intrange of int * int]

type moduleexp =
| Mmod of binding list * t list

(* Compiling from sexps *)

let fail loc fmt =
  let k ppf =
    raise (SyntaxError (loc, Format.flush_str_formatter ())) in
  Format.kfprintf k Format.str_formatter ("@[" ^^ fmt ^^ "@]")

module StrMap = Map.Make (struct type t = string let compare = compare end)

let bind_local loc locals s ident =
  StrMap.add s ident locals

let parse_arglist = function
  | loc, List args ->
     let idents = args |> List.map (function
       | loc, Var s ->
          s, Ident.create s
       | loc, _ -> fail loc "Expected a list of variables") in
     let env = List.fold_left (fun env (s, ident) ->
       if StrMap.mem s env then
         fail loc "Parameter %s bound multiple times" s
       else
         bind_local loc env s ident) StrMap.empty idents in
     List.map snd idents, env
  | loc, _ -> fail loc "Expected a list of atoms"

let parse_tag = function
| loc, List [_, Atom "tag"; _, Int n] ->
   if 0 <= n && n < max_tag then n else fail loc "tag %d out of range [0,%d]" n (max_tag-1)
| loc, _ -> fail loc "invalid tag"

let unary_intops_by_name, binary_intops_by_name =
  let unary_ops = [ `Neg, "neg"; `Not, "not"; `Const, "i" ] in
  let binary_ops =
    [ `Add, "+" ; `Sub, "-" ; `Mul, "*" ; `Div, "/" ; `Mod, "%" ;
      `And, "&" ; `Or, "|" ; `Xor, "^" ; `Lsl, "<<" ; `Lsr, ">>"  ; `Asr, "a>>" ;
      `Lt, "<" ; `Gt, ">" ; `Lte, "<=" ; `Gte, ">=" ; `Eq, "==" ] in
  let types = [`Int, "" ; `Int32, "32" ; `Int64, "64" ; `Bigint, "big"] in
  let () = (* check that all cases are handled here *)
    List.iter (function (`Const | #unary_int_op), _ -> () | _ -> assert false) unary_ops;
    List.iter (function #binary_int_op, _ -> () | _ -> assert false) binary_ops;
    List.iter (function #inttype, _ -> () | _ -> assert false) types in
  List.fold_right (fun (ty,tyname) ->
    List.fold_right (fun (op,opname) ->
      StrMap.add (opname ^ tyname) (op, ty)) unary_ops) types StrMap.empty,
  List.fold_right (fun (ty,tyname) ->
    List.fold_right (fun (op,opname) ->
      StrMap.add (opname ^ tyname) (op, ty)) binary_ops) types StrMap.empty

let seqops_by_name op =
  List.fold_right (fun (ty,tyname) ->
    StrMap.add (op ^ "-" ^ tyname) ty)
    [`Array, "array"; `Bytevec, "bytevec"; `Floatvec, "floatvec"]
    StrMap.empty
let seq_get_by_name = seqops_by_name "get"
let seq_set_by_name = seqops_by_name "set"
let seq_len_by_name = seqops_by_name "len"

(*
(let
  (a 42)
  (b 17)
  (_ 421)
  (rec (a (lambda)))

*)

let rec parse_bindings loc env acc = function
  | [e] ->
     List.rev acc, env, e
  | (loc, List [_, Atom "_"; e]) :: bindings ->
     parse_bindings loc env (`Unnamed (parse_exp env e) :: acc) bindings
  | (loc, List [_, Var s; e]) :: bindings ->
     let ident = Ident.create s in
     let env' = bind_local loc env s ident in
     parse_bindings loc env' (`Named (ident, parse_exp env e) :: acc) bindings
  | (loc, List ((_, Atom "rec") :: recs)) :: bindings ->
     let recs = recs |> List.map (function
       | _, List [_, Var s; _, List ((_, Atom "lambda") :: _) as e] ->
          (s, Ident.create s, e)
       | _, List [_, Var s; _] ->
          fail loc "all members of a recursive binding must be functions"
       | loc, _ ->
          fail loc "expected recursive bindings") in
     let env' = List.fold_left (fun env (s, id, e) ->
       bind_local loc env s id) env recs in
     let recs = recs |> List.map (fun (s, id, e) ->
       (id, parse_exp env' e)) in
     parse_bindings loc env' (`Recursive recs :: acc) bindings
  | _ -> fail loc "no bindings?"

and parse_exp env (loc, sexp) = match sexp with
  | Var s when StrMap.mem s env ->
     Mvar (StrMap.find s env)

  | Var s ->
     fail loc "'%s' is unbound" s

  | List [_, Atom "lambda"; args; exp] ->
     let (params, newenv) = parse_arglist args in
     let env = StrMap.fold StrMap.add newenv env in
     Mlambda (params, parse_exp env exp)

  | List ((loc, Atom "apply") :: func :: args) ->
     Mapply (parse_exp env func, List.map (parse_exp env) args)

  | List ((loc, Atom "let") :: bindings) ->
     let (bindings, env, e) = parse_bindings loc env [] bindings in
     Mlet (bindings, parse_exp env e)

  | List ((_, Atom "switch") :: exp :: cases) ->
     let parse_selector = function
       | _, List [_, Atom "tag"; _, Atom "_"] -> `Deftag
       | _, List ([_, Atom "tag"; _]) as t -> `Tag (parse_tag t)
       | _, Int n -> `Intrange (n, n)
       | _, List [_, Int min; _, Int max] -> `Intrange (min, max)
       | _, Atom "_" -> `Intrange (min_int, max_int)
       | loc, _ -> fail loc "invalid selector" in

     let rec parse_case loc acc = function
       | [s; e] -> List.rev (parse_selector s :: acc), parse_exp env e
       | (s :: c) -> parse_case loc (parse_selector s :: acc) c
       | _ -> fail loc "invalid case" in

     let cases = List.map (function
       | loc, List c -> parse_case loc [] c
       | loc, _ -> fail loc "invalid case") cases in

     if (List.length (List.sort_uniq compare cases) <> List.length cases) then
       fail loc "duplicate cases";

     Mswitch (parse_exp env exp, cases)

  | List [_, Atom s; e] when StrMap.mem s unary_intops_by_name ->
     let validate_const (pi, ps) = function
       | _, Int n -> Mint (pi n)
       | loc, Atom s -> (try Mint (ps s) with Failure _ | Invalid_argument _ -> 
         fail loc "invalid literal %s" s)
       | loc, _ -> fail loc "invalid literal" in
     let const_parser = function
       | `Int -> (fun x -> `Int x), (fun x -> `Int (int_of_string x))
       | `Int32 -> (fun x -> `Int32 (Int32.of_int x)), (fun x -> `Int32 (Int32.of_string x)) 
       | `Int64 -> (fun x -> `Int64 (Int64.of_int x)), (fun x -> `Int64 (Int64.of_string x))
       | `Bigint -> (fun x -> `Bigint (Z.of_int x)), (fun x -> `Bigint (Z.of_string x)) in
     begin match StrMap.find s unary_intops_by_name with
     | (`Neg | `Not) as op, ty -> Mintop1 (op, ty, parse_exp env e)
     | `Const, ty -> validate_const (const_parser ty) e
     end

  | List [_, Atom s; e1; e2] when StrMap.mem s binary_intops_by_name ->
     let (op, ty) = StrMap.find s binary_intops_by_name in
     Mintop2 (op, ty, parse_exp env e1, parse_exp env e2)

  | List [_, Atom op; seq; idx] when StrMap.mem op seq_get_by_name ->
     Mseqget (StrMap.find op seq_get_by_name, parse_exp env seq, parse_exp env idx)

  | List [_, Atom op; seq; idx; v] when StrMap.mem op seq_set_by_name ->
     Mseqset (StrMap.find op seq_set_by_name, parse_exp env seq, parse_exp env idx, parse_exp env v)

  | List [_, Atom op; seq] when StrMap.mem op seq_len_by_name ->
     Mseqlen (StrMap.find op seq_len_by_name, parse_exp env seq)

  | List ((_, Atom "block") :: tag :: fields) ->
     Mblock (parse_tag tag, List.map (parse_exp env) fields)

  | List [_, Atom "field"; _, Int n; e] ->
     Mfield (n, parse_exp env e)

  | Int k ->
     Mint (`Int k)
  | String s ->
     Mstring s

  | List ((_, Atom "global") :: path) ->
     Mglobal (path
       |> List.map (function
         | _, Var s -> s
         | _, _ -> fail loc "module path required")
       |> function
         | [] -> fail loc "empty global path"
         | path1 :: pathrest ->
            List.fold_left (fun id s ->
              Longident.Ldot (id, s)) (Longident.Lident path1) pathrest)

  | List ((_, Atom s) :: _) ->
     fail loc "Unknown operation %s" s

  | Atom s -> fail loc "bad syntax: %s" s

  | _ -> fail loc "syntax error"


let parse_mod (loc, sexp) = match sexp with
  | List ((_, Atom "module") :: rest) ->
     let (bindings, env, exports) = parse_bindings loc StrMap.empty [] rest in
     let exports = match exports with
       | _, List ((_, Atom "export") :: exports) ->
          List.map (parse_exp env) exports
       | _ -> fail loc "export list?" in
     Mmod (bindings, exports)
  | _ -> fail loc "mod?"

let read_expression lexbuf =
  parse_exp StrMap.empty (Malfunction_sexp.read_next_sexp lexbuf)

let read_module lexbuf =
  parse_mod (Malfunction_sexp.read_only_sexp lexbuf)