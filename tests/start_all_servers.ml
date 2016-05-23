let arg_of_server i = 
  let arg = [| 
    "./server.native";
    "--id";
    string_of_int i;
    "";
  |] in 
  begin 
    if i = 1 
    then arg.(3) <- "--print-header" 
    else ();
  end;
  arg

module Conf = Raft_udp_conf
module Udp  = Raft_udp_pb
   

let () = 

  let {Udp.servers_udp_configuration ;_  } = Conf.default_configuration () in 

  let nb_of_servers = List.length servers_udp_configuration in 

  for i = 0 to nb_of_servers - 1  do
    match Unix.fork () with
    | 0 -> Unix.execv "./server.native" (arg_of_server i)
    | _ -> Unix.sleep 1
  done;


  for i = 0 to nb_of_servers - 1  do
    ignore @@ Unix.wait ();
    Printf.eprintf "Child died \n"
  done;

  ()