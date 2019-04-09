open Lwt.Infix

open Intf

module Html_cache = Hashtbl.Make (struct
    type t = Html.query
    let hash = Hashtbl.hash (* TODO: WRONG!! *)
    let equal {Html.available_compilers; compilers; show_available; show_failures_only; show_diff_only; show_latest_only; maintainers; logsearch} y =
      List.equal Compiler.equal available_compilers y.Html.available_compilers &&
      List.equal Compiler.equal compilers y.Html.compilers &&
      List.equal Compiler.equal show_available y.Html.show_available &&
      Bool.equal show_failures_only y.Html.show_failures_only &&
      Bool.equal show_diff_only y.Html.show_diff_only &&
      Bool.equal show_latest_only y.Html.show_latest_only &&
      String.equal (fst maintainers) (fst y.Html.maintainers) &&
      String.equal (fst logsearch) (fst y.Html.logsearch) &&
      Option.equal (fun (_, comp1) (_, comp2) -> Intf.Compiler.equal comp1 comp2) (snd logsearch) (snd y.Html.logsearch)
  end)

module Maintainers_cache = Hashtbl.Make (String)
module Revdeps_cache = Hashtbl.Make (String)

type merge =
  | Old
  | New

module Pkg_htbl = CCHashtbl.Make (struct
    type t = string * Compiler.t
    let hash = Hashtbl.hash (* TODO: Improve *)
    let equal (full_name, comp) y =
      String.equal full_name (fst y) &&
      Intf.Compiler.equal comp (snd y)
  end)

let detect_section old_state new_state =
  let open Intf.State in
  let open Intf.Pkg_diff in
  match old_state, new_state with
  | Bad, Bad | Partial, Partial | Good, Good
  | NotAvailable, NotAvailable | InternalFailure, InternalFailure ->
      assert false
  | Bad, Partial -> Important
  | Bad, (Good | NotAvailable) -> Low
  | Bad, InternalFailure -> Medium
  | Partial, Bad -> Important
  | Partial, Good -> Low
  | Partial, (NotAvailable | InternalFailure) -> Medium
  | Good, (Bad | Partial | NotAvailable | InternalFailure) -> Important
  | NotAvailable, (Bad | Partial | InternalFailure) -> Important
  | NotAvailable, Good -> Low
  | InternalFailure, (Bad | Partial) -> Important
  | InternalFailure, (Good | NotAvailable) -> Low

let add_diff htbl acc ((full_name, comp) as pkg) =
  match Pkg_htbl.find_all htbl pkg with
  | [((Old | New), Intf.State.NotAvailable)] -> acc
  | [(Old, state)] ->
      let section = detect_section state Intf.State.NotAvailable in
      Intf.Pkg_diff.(section, {full_name; comp; diff = NotAvailableAnymore state}) :: acc
  | [(New, state)] ->
      let section = detect_section Intf.State.NotAvailable state in
      Intf.Pkg_diff.(section, {full_name; comp; diff = NowInstallable state}) :: acc
  | [(New, new_state); (Old, old_state)] when Intf.State.equal new_state old_state -> acc
  | [(New, new_state); (Old, old_state)] ->
      let section = detect_section old_state new_state in
      Intf.Pkg_diff.(section, {full_name; comp; diff = StatusChanged (old_state, new_state)}) :: acc
  | _ -> assert false

let split_diff (important, medium, low) = function
  | Intf.Pkg_diff.Important, diff -> (diff :: important, medium, low)
  | Intf.Pkg_diff.Medium, diff -> (important, diff :: medium, low)
  | Intf.Pkg_diff.Low, diff -> (important, medium, diff :: low)

let generate_diff old_pkgs new_pkgs =
  old_pkgs >>= fun old_pkgs ->
  new_pkgs >|= fun new_pkgs ->
  let pkg_htbl = Pkg_htbl.create 10_000 in
  let aux pos pkg =
    Intf.Pkg.instances pkg |>
    List.iter begin fun inst ->
      let comp = Intf.Instance.compiler inst in
      let state = Intf.Instance.state inst in
      Pkg_htbl.add pkg_htbl (Intf.Pkg.full_name pkg, comp) (pos, state)
    end
  in
  List.iter (aux Old) old_pkgs;
  List.iter (aux New) new_pkgs;
  List.sort_uniq ~cmp:Ord.(pair string Intf.Compiler.compare) (Pkg_htbl.keys_list pkg_htbl) |>
  List.fold_left (add_diff pkg_htbl) [] |>
  List.fold_left split_diff ([], [], [])

type t = {
  html_tbl : string Html_cache.t;
  mutable pkgs : Intf.Pkg.t list Lwt.t;
  mutable old_pkgs : Intf.Pkg.t list Lwt.t;
  mutable compilers : Intf.Compiler.t list Lwt.t;
  mutable old_compilers : Intf.Compiler.t list Lwt.t;
  mutable maintainers : string list Maintainers_cache.t Lwt.t;
  mutable revdeps : int Revdeps_cache.t Lwt.t;
  mutable pkgs_diff : (Pkg_diff.t list * Pkg_diff.t list * Pkg_diff.t list) Lwt.t;
  mutable html_diff : string Lwt.t;
}

let create () = {
  html_tbl = Html_cache.create 32;
  pkgs = Lwt.return_nil;
  old_pkgs = Lwt.return_nil;
  compilers = Lwt.return_nil;
  old_compilers = Lwt.return_nil;
  maintainers = Lwt.return (Maintainers_cache.create 0);
  revdeps = Lwt.return (Revdeps_cache.create 0);
  pkgs_diff = Lwt.return ([], [], []);
  html_diff = Lwt.return "";
}

let clear_and_init self ~pkgs ~compilers ~maintainers ~revdeps ~html_diff =
  self.maintainers <- maintainers ();
  self.revdeps <- revdeps ();
  self.compilers <- compilers ~old:false;
  self.old_compilers <- compilers ~old:true;
  self.pkgs <- pkgs ~old:false;
  self.old_pkgs <- pkgs ~old:true;
  self.pkgs_diff <- generate_diff self.old_pkgs self.pkgs;
  self.html_diff <- html_diff ();
  Html_cache.clear self.html_tbl

let get_html ~conf self query =
  self.pkgs >>= fun pkgs ->
  Html.get_html ~conf query pkgs >>= fun html ->
  Html_cache.add self.html_tbl query html;
  Lwt.return html

let get_html ~conf self query =
  match Html_cache.find_opt self.html_tbl query with
  | Some html -> Lwt.return html
  | None -> get_html ~conf self query

let get_pkgs ~old self =
  if old then
    self.old_pkgs
  else
    self.pkgs

let get_compilers ~old self =
  if old then
    self.old_compilers
  else
    self.compilers

let get_maintainers self k =
  self.maintainers >|= fun maintainers ->
  Option.get_or ~default:[] (Maintainers_cache.find_opt maintainers k)

let get_revdeps self k =
  self.revdeps >|= fun revdeps ->
  Option.get_or ~default:(-1) (Revdeps_cache.find_opt revdeps k)

let get_diff self =
  self.pkgs_diff

let get_html_diff self =
  self.html_diff
