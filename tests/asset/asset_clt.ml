open Lwt.Infix 
open Lwt_log_core 

module Conf = Raft_udp_conf 

module Test_utl = Asset_test_utl 

module Asset_clt = Raft_app_clt.Make(struct

  type tx = Asset_pb.tx 

  let encode tx = 
    let encoder = Pbrt.Encoder.create () in 
    Asset_pb.encode_tx tx encoder; 
    Pbrt.Encoder.to_bytes encoder

end)

(** App module for the test execution *)
module App = struct 

  type t = Raft_app_clt.t 

  let content_of_url url = 
    Lwt.return @@ "This is a dummy content of course" ^ url

  let handle_tx t tx = 
    Asset_clt.send t tx 
    >|=(function 
      | Raft_app_clt.Send_result_ok -> t 
      | Raft_app_clt.Send_result_error s -> 
        Printf.eprintf "Send error in handle_tx, details: %s" s; 
        t 
    ) 

end (* App *)

module Test_utl_exec = Test_utl.Make(App)

let nb_of_tests = 200

let max_nb_of_transfers = 200 

let nb_of_keys = 200 

(* Create the tests *)

let env = Test_utl.make_env ~nb_of_keys () 

let tests = 
  let rec aux = function
    | 0 -> [] 
    | n -> 
      let nb_of_transfers = Random.int max_nb_of_transfers + 1 in 
      (Test_utl.make_test ~env ~nb_of_transfers ()) :: (aux @@ n - 1)
  in 
  aux nb_of_tests

let execute_nth_test logger ~nth ~app l = 
  let rec aux nth l = 
    match nth, l with
    | 0, test::tl -> 
      if Test_utl.is_done test 
      then 
        log_f ~logger ~level:Notice "Test nth: %i is done" nth
        >|=(fun () -> (tl, app))
      else 
        log_f ~logger ~level:Notice "Executing test nth: %i" nth
        >>=(fun () -> 
          Test_utl_exec.execute_test test app 
          >|=(fun (test, app) -> (test::tl, app))
        )

    | nth, test::tl -> 
      aux (nth - 1) tl  
      >|=(fun (tests, app) -> (test::tests, app))

    | _ -> 
      Printf.eprintf "Programatic error\n";
      assert(false)
  in 
  aux nth l 
  
let rec execute_all_tests logger app = function
  | [] -> 
    Lwt_io.printlf 
      "Success ..."

  | l  -> 
    let nth = Random.int @@ List.length l in  
    execute_nth_test logger ~nth ~app l
    >>=(fun (l, app) ->
      execute_all_tests logger app l 
    )

let main log () = 
  let to_file = 
    if log 
    then Some (Printf.sprintf "client%i.log" (Unix.getpid ())) 
    else None
  in 
  Raft_utl_lwt.make_logger ?to_file ()  
  >>=(fun logger -> 
    Raft_app_clt.make logger (Conf.default_configuration ()) 
    >>= (fun client -> execute_all_tests logger client tests)
  ) 

let () =
  let log = ref false in 
  let log_spec = Arg.Set log  in
  
  Arg.parse [
    ("--log", log_spec, " : enable logging");
  ] (fun _ -> ()) "client.ml";

  Random.self_init ();
  Lwt_main.run (main !log ())