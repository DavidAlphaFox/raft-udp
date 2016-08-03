(** RAFT Protocol handling
 
    This module handles all the RAFT server events (raft msgs, timeout and 
    client requests.
  *)

(** {2 Types} *)

type client_request = Raft_app_pb.client_request * Raft_srv_clientipc.handle

type client_response = Raft_app_pb.client_response * Raft_srv_clientipc.handle 

type client_responses = client_response list 

type app_requests = Raft_app_pb.app_request list 

type app_response = Raft_app_pb.app_response 

type t

(** {2 Creators} *)

val make : 
  logger:Lwt_log_core.logger -> 
  stats:Raft_srv_serverstats.t -> 
  ipc:Raft_srv_raftipc.t -> 
  raft_state:Raft_state.t ->
  log_record_handle:Raft_srv_logrecord.t ->
  unit -> 
  t 

(** {2 Accessors} *) 

val raft_state : t -> Raft_state.t 
(** [raft_state t] accessor for the raft state  *)

(** {2 Logic } *) 

type result = (t * client_responses * app_requests) 

val handle_raft_message :
  now   : float -> 
  t -> 
  Raft_pb.message ->
  result Lwt.t  
(** [handle_raft_message ~logger ~stats ~now state msg] handles RAFT protocol 
    messages from other servers. 
  *)

val handle_timeout :
  now   : float -> 
  t ->
  Raft_pb.timeout_event_time_out_type ->
  result Lwt.t  
(** [handle_raft_message ~logger ~stats ~now state msg] handles RAFT protocol 
    timeout event. 
  *)

val handle_client_requests :
  now   : float -> 
  t ->
  client_request list ->
  result Lwt.t  
(** [handle_client_request ~logger ~stats ~now state msg] handles RAFT protocol 
    client requests. 
  *)

val handle_app_response :
  now   : float -> 
  t ->
  app_response ->
  result Lwt.t  
(** [handle_app_response ~logger ~stats ~now state msg] handles the response received
    from the application server. 
  *)

val handle_compaction_update : 
  Raft_pb.log_interval list -> 
  t -> 
  t Lwt.t  