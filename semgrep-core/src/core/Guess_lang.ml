(*
   Guess whether a given file is indeed written in the specified
   programming language.
*)

open Common

(*
   Evaluation will be left-to-right and lazy, using the usual (&&) and (||)
   operators.
*)
type test =
  | And of test * test
  | Or of test * test
  | Not of test
  | Test_path of (string -> bool)

let eval test path =
  let rec eval = function
    | And (f, g) -> eval f && eval g
    | Or (f, g) -> eval f || eval g
    | Not f -> not (eval f)
    | Test_path f -> f path
  in
  eval test

(****************************************************************************)
(* Helpers *)
(****************************************************************************)

let string_chop_prefix ~pref s =
  let len = String.length s in
  let preflen = String.length pref in
  if len >= preflen && String.sub s 0 preflen = pref then
    Some (String.sub s preflen (len - preflen))
  else None

let has_suffix suffixes =
  let f path =
    List.exists (fun suf -> Filename.check_suffix path suf) suffixes
  in
  Test_path f

let prepend_period_if_needed s =
  match s with
  | "" -> "."
  | s -> if s.[0] <> '.' then "." ^ s else s

(*
   Both '.d.ts' and '.ts' are considered extensions of 'hello.d.ts'.
*)
let has_extension extensions =
  has_suffix (List.map prepend_period_if_needed extensions)

let has_lang_extension lang = has_extension (Lang.ext_of_lang lang)

let has_an_extension =
  let f path = Filename.extension path <> "" in
  Test_path f

let is_executable =
  let f path =
    Sys.file_exists path
    &&
    let st = Unix.stat path in
    match st.st_kind with
    | S_REG ->
        (* at least some user has exec permission *)
        st.st_perm land 0o111 <> 0
    | _ -> false
  in
  (* ".exe" is intended for Windows, although this would be a binary file, not
     a script. *)
  Or (has_extension [ ".exe" ], Test_path f)

let get_first_line path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> try input_line ic with End_of_file -> (* empty file *) "")

(*
   Get the first N bytes of the file, which is ideally obtained from
   a single filesystem block.
*)
let get_first_block ?(block_size = 4096) path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let len = min block_size (in_channel_length ic) in
      really_input_string ic len)

let shebang_re = lazy (Pcre.regexp "^#![ \t]*([^ \t]*)[ \t]*([^ \t].*)?$")

let split_cmd_re = lazy (Pcre.regexp "[ \t]+")

(*
   A shebang supports at most the name of the script and one argument:

   #!/bin/bash -e -u
     ^^^^^^^^^ ^^^^^
       arg0    arg1

   To deal with that, the '/usr/bin/env' command offer the '-S' option prefix,
   which will split what follows '-S' into multiple arguments. So we
   may find things like these:

   #!/usr/bin/env -S bash -e -u
     ^^^^^^^^^^^^ ^^^^^^^^^^^^^
         arg0         arg1

   It's 'env' that will parse its argument and execute the command
   ['bash'; '-e'; '-u'] as expected.

   Examples:

     "#!/bin/bash -e -u"            -> ["/bin/bash"; "-e -u"]
     "#!/usr/bin/env -S bash -e -u" -> ["/usr/bin/env"; "bash"; "-e"; "-u"]
*)
let parse_shebang_line s =
  let matched =
    try Some (Pcre.exec ~rex:(Lazy.force shebang_re) s) with Not_found -> None
  in
  match matched with
  | None -> None
  | Some matched -> (
      match Pcre.get_substrings matched with
      | [| _; arg0; "" |] -> Some [ arg0 ]
      | [| _; "/usr/bin/env" as arg0; arg1 |] -> (
          (* approximate emulation of 'env -S'; should work if the command
             contains no quotes around the arguments. *)
          match string_chop_prefix ~pref:"-S" arg1 with
          | Some packed_args ->
              let args =
                Pcre.split ~rex:(Lazy.force split_cmd_re) packed_args
                |> List.filter (fun fragment -> fragment <> "")
              in
              Some (arg0 :: args)
          | None -> Some [ arg0; arg1 ])
      | [| _; arg0; arg1 |] -> Some [ arg0; arg1 ]
      | [| _ |] -> None
      | _ -> assert false)

let get_shebang_command path = get_first_line path |> parse_shebang_line

let uses_shebang_command_name cmd_names =
  let f path =
    match get_shebang_command path with
    | Some ("/usr/bin/env" :: cmd_name :: _) -> List.mem cmd_name cmd_names
    | Some (cmd_path :: _) ->
        let cmd_name = Filename.basename cmd_path in
        List.mem cmd_name cmd_names
    | _ -> false
  in
  Test_path f

(* PCRE regexp using the default options *)
let regexp pat =
  let rex = Pcre.regexp pat in
  let f path =
    let s = get_first_block path in
    Pcre.pmatch ~rex s
  in
  Test_path f

let is_executable_script cmd_names =
  And
    ( Not has_an_extension,
      And (is_executable, uses_shebang_command_name cmd_names) )

(*
   General test for a script:
   - must have one of the approved extensions (e.g. "bash" or "sh")
   - or has no extension but has executable permission
     and one of the approved commands occurs on the shebang line.
     Example:

       #!/bin/bash -e
              ^^^^

       #!/usr/bin/env bash
                      ^^^^
*)
let is_script lang cmd_names =
  Or (is_executable_script cmd_names, has_lang_extension lang)

(****************************************************************************)
(* Language-specific definitions *)
(****************************************************************************)

(*
   Inspect Hack files, which may use the '.php' extension in addition to
   the Hack-specific extensions ('.hack' etc.).

   See https://docs.hhvm.com/hack/source-code-fundamentals/program-structure
*)
let is_hack =
  Or
    ( is_script Lang.Hack [ "hhvm" ],
      And
        ( has_extension [ ".php" ],
          Or
            ( uses_shebang_command_name [ "hhvm" ],
              (* optional '#!' line followed by '<?hh': *)
              regexp "^(?:#![^\\n]*\\n)?<\\?hh\\s" ) ) )

let is_python2 = is_script Lang.Python2 [ "python"; "python2" ]

let is_python3 = is_script Lang.Python3 [ "python"; "python3" ]

let inspect_file_p (lang : Lang.t) path =
  let test =
    match lang with
    | Bash -> is_script lang [ "bash"; "sh" ]
    | C -> has_lang_extension lang
    | Cplusplus -> has_lang_extension lang
    | Csharp -> has_lang_extension lang
    | Go -> has_lang_extension lang
    | HTML -> has_lang_extension lang
    | Hack -> is_hack
    | JSON -> has_lang_extension lang
    | Java -> has_lang_extension lang
    | Javascript ->
        And
          ( Not (has_extension [ ".min.js" ]),
            is_script lang [ "node"; "nodejs"; "js" ] )
    | Kotlin -> has_lang_extension lang
    | Lua -> is_script lang [ "lua" ]
    | OCaml -> is_script lang [ "ocaml"; "ocamlscript" ]
    | PHP -> And (is_script lang [ "php" ], Not is_hack)
    | Python -> Or (is_python2, is_python3)
    | Python2 -> is_python2
    | Python3 -> is_python3
    | R -> is_script lang [ "Rscript" ]
    | Ruby -> is_script lang [ "ruby" ]
    | Rust -> is_script lang [ "run-cargo-script" ]
    | Scala -> is_script lang [ "scala" ]
    | Typescript ->
        And (Not (has_extension [ ".d.ts" ]), is_script lang [ "ts-node" ])
    | Vue -> has_lang_extension lang
    | Yaml -> has_lang_extension lang
    | HCL -> has_lang_extension lang
  in
  eval test path

let wrap_with_error_message lang path bool_res :
    (string, Semgrep_core_response_t.skipped_target) result =
  match bool_res with
  | true -> Ok path
  | false ->
      Error
        {
          path;
          reason = Wrong_language;
          details =
            spf "target file doesn't look like language %s"
              (Lang.to_string lang);
          skipped_rule = None;
        }

let inspect_file lang path =
  let bool_res = inspect_file_p lang path in
  wrap_with_error_message lang path bool_res

let inspect_files lang paths = Common.partition_result (inspect_file lang) paths
