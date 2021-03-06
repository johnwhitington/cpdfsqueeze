(* Lossless PDF compressor *)
open Pdfutil
open Pdfio

let version = "Version 2.3 (build of 17th October 2019)"

let shortversion = "2.3"

let _ =
  print_string
    ("cpdfsqueeze "
     ^ version
     ^ "\nCopyright Coherent Graphics Ltd http://www.coherentpdf.com/\n\n")

(* Wrap up the file reading functions to exit with code 1 when an encryption
problem occurs. This happens when object streams are in an encrypted document
and so it can't be read without the right password... The existing error
handling only dealt with the case where the document couldn't be decrypted once
it had been loaded. *)
let pdfread_pdf_of_file ?revision a b c =
  try Pdfread.pdf_of_file ?revision a b c with
    Pdf.PDFError s when String.length s >=10 && String.sub s 0 10 = "Encryption" ->
      Printf.eprintf "Bad owner or user password\n";
      exit 1

let opw = ref ""
let upw = ref ""
let input_file = ref ""
let output_file = ref ""

let specs =
  [("-upw", Arg.Set_string upw, " User password");
   ("-opw", Arg.Set_string opw, " Owner password")]

let anon_fun s =
  if !input_file = "" then input_file := s else output_file := s

let usage_msg =
  "Syntax: cpdfsqueeze <input file> [-upw <pw>] [-opw <pw>] <output file>\n"

let validate_command_line () = 
  if !input_file = "" || !output_file = "" then
    begin
      prerr_string usage_msg;
      exit 1
    end

let optstring = function
  | "" -> None
  | x -> Some x

(* Recompress anything which isn't compressed, unless it's metadata. *)
let recompress_stream pdf = function
  (* If there is no compression, compress with /FlateDecode *)
  | Pdf.Stream {contents = (dict, _)} as stream ->
      begin match
        Pdf.lookup_direct pdf "/Filter" dict, 
        Pdf.lookup_direct pdf "/Type" dict
      with
      | _, Some (Pdf.Name "/Metadata") -> ()
      | (None | Some (Pdf.Array [])), _ ->
          Pdfcodec.encode_pdfstream pdf Pdfcodec.Flate stream
      | _ -> ()
      end
  | _ -> assert false

let recompress_pdf pdf =
  if not (Pdfcrypt.is_encrypted pdf) then
    Pdf.iter_stream (recompress_stream pdf) pdf;
    pdf

(* Equality on PDF objects *)
let pdfobjeq pdf x y =
  let x = Pdf.lookup_obj pdf x 
  and y = Pdf.lookup_obj pdf y in
    begin match x with Pdf.Stream _ -> Pdf.getstream x | _ -> () end;
    begin match y with Pdf.Stream _ -> Pdf.getstream y | _ -> () end;
    compare x y

let really_squeeze pdf =
  let objs = ref [] in
    Pdf.objiter (fun objnum _ -> objs := objnum :: !objs) pdf;
    let toprocess =
      keep
        (fun x -> length x > 1)
        (collate (pdfobjeq pdf) (sort (pdfobjeq pdf) !objs))
    in
      (* Remove any pools of objects which are page objects, since Adobe Reader
       * gets confused when there are duplicate page objects. *)
      let toprocess =
        option_map
          (function
             [] -> assert false
           | h::_ as l ->
               match Pdf.lookup_direct pdf "/Type" (Pdf.lookup_obj pdf h) with
                 Some (Pdf.Name "/Page") -> None
               | _ -> Some l)
          toprocess
      in
        let pdfr = ref pdf in
        let changetable = Hashtbl.create 100 in
          iter
            (function [] -> assert false | h::t ->
               iter (fun e -> Hashtbl.add changetable e h) t)
            toprocess;
          (* For a unknown reason, the output file is much smaller if
             Pdf.renumber is run twice. This is bizarre, since Pdf.renumber is
             an old, well-understood function in use for years -- what is
             going on? Furthermore, if we run it 3 times, it gets bigger again! *)
          pdfr := Pdf.renumber changetable !pdfr;
          pdfr := Pdf.renumber changetable !pdfr;
          Pdf.remove_unreferenced !pdfr;
          pdf.Pdf.root <- !pdfr.Pdf.root;
          pdf.Pdf.objects <- !pdfr.Pdf.objects;
          pdf.Pdf.trailerdict <- !pdfr.Pdf.trailerdict

(* Squeeze the form xobject at objnum.

FIXME: For old PDFs (< v1.2) any resources from the page (or its ancestors in
the page tree!) are also needed - we must merge them with the ones from the
xobject itself. However, it it safe for now -- in the unlikely event that the
resources actually need to be available, the parse will fail, the squeeze of
this object will fail, and we bail out. *)
let xobjects_done = ref []

let squeeze_form_xobject pdf objnum =
  if mem objnum !xobjects_done then () else
    xobjects_done := objnum :: !xobjects_done;
    let obj = Pdf.lookup_obj pdf objnum in
      match Pdf.lookup_direct pdf "/Subtype" obj with
        Some (Pdf.Name "/Form") ->
          let resources =
            match Pdf.lookup_direct pdf "/Resources" obj with
              Some d -> d
            | None -> Pdf.Dictionary []
          in
            begin match
              Pdfops.stream_of_ops
                (Pdfops.parse_operators pdf resources [Pdf.Indirect objnum])
            with
              Pdf.Stream {contents = (_, Pdf.Got data)} ->
                (* Put replacement data in original stream, and overwrite /Length *)
                begin match obj with
                  Pdf.Stream ({contents = (d, _)} as str) ->
                    str :=
                      (Pdf.add_dict_entry d "/Length" (Pdf.Integer (bytes_size data)),
                       Pdf.Got data)
                | _ -> failwith "squeeze_form_xobject"
                end
            | _ -> failwith "squeeze_form_xobject"
            end
      | _ -> ()

(* For a list of indirects representing content streams, make sure that none of
them are duplicated in the PDF. This indicates sharing, which parsing and
rewriting the streams might destroy, thus making the file bigger. FIXME: The
correct thing to do is to preserve the multiple content streams. *)
let no_duplicates content_stream_numbers stream_numbers =
  not
    (mem false
       (map
         (fun n -> length (keep (eq n) content_stream_numbers) < 2)
         stream_numbers))

(* Give a list of content stream numbers, given a page reference number *)
let content_streams_of_page pdf refnum =
  match Pdf.direct pdf (Pdf.lookup_obj pdf refnum) with
    Pdf.Dictionary dict ->
      begin match lookup "/Contents" dict with
        Some (Pdf.Indirect i) -> [i]
      | Some (Pdf.Array x) ->
          option_map (function Pdf.Indirect i -> Some i | _ -> None) x
      | _ -> []
      end
  | _ -> []

(* For each object in the PDF marked with /Type /Page, for each /Contents
indirect reference or array of such, decode and recode that content stream. *)
let squeeze_all_content_streams pdf =
  let page_reference_numbers = Pdf.page_reference_numbers pdf in
    let all_content_streams_in_doc =
      flatten (map (content_streams_of_page pdf) page_reference_numbers)
    in
      xobjects_done := [];
      Pdf.objiter
        (fun objnum _ ->
          match Pdf.lookup_obj pdf objnum with
            Pdf.Dictionary dict as d
              when
                Pdf.lookup_direct pdf "/Type" d = Some (Pdf.Name "/Page")
              ->
                let resources =
                  match Pdf.lookup_direct pdf "/Resources" d with
                    Some d -> d
                  | None -> Pdf.Dictionary []
                in
                  begin try
                    let content_streams =
                      match lookup "/Contents" dict with
                        Some (Pdf.Indirect i) ->
                          begin match Pdf.direct pdf (Pdf.Indirect i) with
                            Pdf.Array x -> x
                          | _ -> [Pdf.Indirect i]
                          end
                      | Some (Pdf.Array x) -> x
                      | _ -> raise Not_found
                    in
                      if
                        no_duplicates
                          all_content_streams_in_doc
                          (map (function Pdf.Indirect i -> i | _ -> assert false) content_streams)
                      then
                        let newstream =
                          Pdfops.stream_of_ops
                            (Pdfops.parse_operators pdf resources content_streams)
                        in
                          let newdict =
                            Pdf.add_dict_entry
                              d "/Contents" (Pdf.Indirect (Pdf.addobj pdf newstream))
                          in
                            Pdf.addobj_given_num pdf (objnum, newdict);
                            (* Now process all xobjects related to this page *)
                            begin match Pdf.lookup_direct pdf "/XObject" resources with
                              Some (Pdf.Dictionary xobjs) ->
                                iter
                                  (function
                                     (_, Pdf.Indirect i) -> squeeze_form_xobject pdf i
                                    | _ -> failwith "squeeze_xobject")
                                  xobjs
                            | _ -> ()
                            end
                  with
                    (* No /Contents, which is ok. Or a parsing failure due to
                     uninherited resources. FIXME: Add support for inherited
                     resources. *)
                    Not_found -> ()
                  end
            | _ -> ())
        pdf

(* We run squeeze enough times for the number of objects to not change *)
let squeeze ?logto pdf =
  let log x =
    match logto with
      None -> print_string x; flush stdout
    | Some "nolog" -> ()
    | Some s ->
        let fh = open_out_gen [Open_wronly; Open_creat] 0o666 s in
          seek_out fh (out_channel_length fh);
          output_string fh x;
          close_out fh
  in
    try
      let n = ref (Pdf.objcard pdf) in
      log (Printf.sprintf "Beginning squeeze: %i objects\n" (Pdf.objcard pdf));
      while !n > (ignore (really_squeeze pdf); Pdf.objcard pdf) do
        n := Pdf.objcard pdf;
        log (Printf.sprintf "Squeezing... Down to %i objects\n" (Pdf.objcard pdf));
      done;
      log (Printf.sprintf "Squeezing page data and xobjects\n");
      squeeze_all_content_streams pdf;
      log (Printf.sprintf "Recompressing document\n");
      Pdfcodec.flate_level := 9;
      ignore (recompress_pdf pdf)
    with
      e ->
        raise
          (Pdf.PDFError
             (Printf.sprintf
                "Squeeze failed. No output written.\n Proximate error was:\n %s"
                (Printexc.to_string e)))

let filesize name =
  let x = open_in_bin name in
  let r = in_channel_length x in
    close_in x;
    r

let set_producer s pdf =
  let infodict =
    match Pdf.lookup_direct pdf "/Info" pdf.Pdf.trailerdict with
    | Some d -> d
    | None -> Pdf.Dictionary []
  in
    let infodict' = Pdf.add_dict_entry infodict "/Producer" (Pdf.String s) in
    let objnum = Pdf.addobj pdf infodict' in
      pdf.Pdf.trailerdict <-
        Pdf.add_dict_entry pdf.Pdf.trailerdict "/Info" (Pdf.Indirect objnum)

let go () =
  let i_size = filesize !input_file in
  Printf.printf "Initial file size is %i bytes\n" i_size;
  let pdf = pdfread_pdf_of_file (optstring !upw) (optstring !opw) !input_file in
  let was_decrypted = ref false in
  let pdf =
    if not (Pdfcrypt.is_encrypted pdf) then pdf else
      begin
        was_decrypted := true;
        match Pdfcrypt.decrypt_pdf_owner !opw pdf with
        | Some x -> x
        | None ->
            match fst (Pdfcrypt.decrypt_pdf !upw pdf) with
            | Some x -> x
            | None ->
                Printf.eprintf "Bad owner or user password\n";
                exit 1
      end
  in
    squeeze pdf;
    set_producer ("cpdfsqueeze " ^ shortversion ^ " http://coherentpdf.com/") pdf;
    Pdf.remove_unreferenced pdf;
    let best_password = if !opw <> "" then !opw else !upw in
    Printf.printf "Recrypting with password %s\n" best_password;
    if !was_decrypted then
      Pdfwrite.pdf_to_file_options ~recrypt:(Some best_password) ~generate_objstm:true false None false pdf !output_file
    else
      Pdfwrite.pdf_to_file_options ~generate_objstm:true false None false pdf !output_file;
    let o_size = filesize !output_file in
      Printf.printf
        "Final file size is %i bytes, %.2f%% of original.\n"
         o_size
         ((float o_size /. float i_size) *. 100.)

let _ =
  try
    Arg.parse specs anon_fun usage_msg;
    validate_command_line ();
    go ()
  with
    e ->
      prerr_string
        ("cpdfsqueeze encountered an unexpected error. Technical Details follow:\n" ^
         Printexc.to_string e ^ "\n\n");
      flush stderr;
      exit 2
