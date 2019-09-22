(* Lossless PDF compressor *)
let version = "Version 2.3 (build of 31st October 2019)"

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
      raise (Failure "Bad owner or user password when reading document")

let pw = ref ""
let input_file = ref ""
let output_file = ref ""

let specs =
  [("-pw", Arg.Set_string pw, " Provide owner or user password")]

let anon_fun s =
  if !input_file = "" then input_file := s else output_file := s

let usage_msg =
  "Syntax: cpdfsqueeze <input file> [-pw <password>] <output file>\n"

let validate_command_line () = 
  if !input_file = "" || !output_file = "" then
    begin
      prerr_string usage_msg;
      exit 1
    end

let optstring = function
  | "" -> None
  | x -> Some x

let go () =
  let pdf = pdfread_pdf_of_file (optstring !pw) (optstring !pw) !input_file in
    Pdfwrite.pdf_to_file_options ~recrypt:(optstring !pw) false None true pdf !output_file

let _ =
 try
   Arg.parse specs anon_fun usage_msg;
   validate_command_line ();
   go ()
 with
   (* FIXME Add exit 1 on bad password *)
   e ->
     prerr_string
       ("cpdfsqueeze encountered an unexpected error. Technical Details follow:\n" ^
        Printexc.to_string e ^ "\n\n");
      flush stderr;
     exit 2
