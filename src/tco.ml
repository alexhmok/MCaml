(* tco.ml *)
open Knormal

(* Identify self-recursive calls and transform them.
   Knormal emits an App as either
     KCall(f, args)                                         (* dest = None *)
   or
     KSeq(KCall(f, args), KLet(d, KVar "$ret", KUnit))      (* dest = Some d *)
   so a tail call in a typed context is always wrapped in the KSeq form.
   We have to match that wrapper explicitly — a naive `KCall` match only
   catches the unwrapped case. *)
let rec optimize_tail func_name k =
  match k with
  | KLet (x, e1, e2) ->
      (* Recurse into the body, e1 cannot be a tail call in Let *)
      KLet (x, e1, optimize_tail func_name e2)

  | KIf (cond, e1, e2) ->
      KIf (cond, optimize_tail func_name e1, optimize_tail func_name e2)

  (* Typed tail-call pattern from App with Some dest — drops the dead
     $ret = $ret copy that the KLet would otherwise emit. *)
  | KSeq (KCall (f, args), KLet (_, KVar "$ret", KUnit)) when f = func_name ->
      KLoop (f, args)

  | KSeq (e1, e2) ->
      KSeq (e1, optimize_tail func_name e2)

  | KCall (f, args) when f = func_name ->
      KLoop (f, args)

  | _ -> k