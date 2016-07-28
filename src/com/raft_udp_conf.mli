(** Configuration utilities. *)

val default_configuration : 
  unit -> 
  Raft_udp_pb.configuration

val sockaddr_of_server_id : 
  [< `Client | `Raft ] ->
  Raft_udp_pb.configuration ->
  int -> 
  Unix.sockaddr option

val sockaddr_of_server_config: 
  [< `Client | `Raft ] ->
  Raft_udp_pb.server_ipc_configuration->
  Unix.sockaddr

val get_id_cmdline :
  Raft_udp_pb.configuration -> 
  (int ref * Arg.spec) 

val server_ipc_configuration : 
  Raft_udp_pb.configuration -> 
  int ->
  Raft_udp_pb.server_ipc_configuration option 
