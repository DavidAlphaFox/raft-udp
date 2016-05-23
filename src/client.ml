open Lwt.Infix

module Conf = Raft_udp_conf
module U    = Lwt_unix
module Pb   = Raft_udp_pb

let configuration = Conf.default_configuration ()

let test_add_log_request = Pb.(Add_log {
  request_id = string_of_int (Unix.getpid());
    data = Bytes.of_string "Hi";
  })

let return_error s =
  Lwt_io.eprintl s
  >|=(fun () -> None)

let send_request fd client_request =
  let encoder = Pbrt.Encoder.create () in
  Pb.encode_client_request client_request encoder;
  let buffer     = Pbrt.Encoder.to_bytes encoder in
  let buffer_len = Bytes.length buffer in

  Lwt.catch (fun () ->
  U.write fd buffer 0 buffer_len
  >>= (fun nb_byte_written ->
    if nb_byte_written <>  buffer_len
    then return_error "Wrong nb of byte written"
    else
      let buffer = Bytes.create 1024 in
      U.read fd buffer 0 1024
      >>= (fun bytes_read ->
        if bytes_read <> 0 && bytes_read <> 1024
        then
          let decoder = Pbrt.Decoder.of_bytes buffer in
          Lwt.return (Some (Pb.decode_client_response decoder))
        else
          return_error "Wrong nb of byte read"
      )
  )) (* with *) (fun exn ->
    Lwt_io.eprintlf "Error in IPC with RAFT server, details: %s" 
      (Printexc.to_string exn) 
    >|=(fun () -> None) 
  )

let send_log ad n' () =
  fun () ->
    let fd = U.socket U.PF_INET U.SOCK_STREAM 0 in
    U.connect fd ad
    >>= (fun () ->
      let rec aux = function
        | 0 -> Lwt.return_unit
        | n ->
          begin
            if n mod 20 = 0
            then Lwt_io.printlf "[%4i]" (n' - n)
            else Lwt.return_unit
          end
          >>=(fun () ->
          send_request fd test_add_log_request
          )
          >>= (function
            | None -> Lwt_io.eprintl "Error occured"
            | Some client_response ->
              begin match client_response with
              | Pb.Add_log_success -> 
                (*
                Format.(fprintf std_formatter "%a\n%!" Pb.pp_client_response client_response);
                *)
                U.sleep 0.0000 >>= (fun () ->aux (n -1))
              | Pb.Add_log_replication_failure
              | Pb.Pong _
              | Pb.Add_log_not_a_leader _ ->
                Lwt_io.eprintl "Error received from RAFT server" 

              end
          )
      in
      aux n'
    )
    >>=(fun () -> U.close fd)

let main () =

  match Conf.sockaddr_of_server_id `Client configuration 0 with
  | None ->
     Lwt_io.eprintl "No address know for server 0"

  | Some ad ->
    let send_log_f = send_log ad 100000 () in
    send_log_f ()

let () =
  Lwt_main.run (main ())