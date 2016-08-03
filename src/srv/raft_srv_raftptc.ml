open Lwt.Infix 

module L = Lwt_log_core

module Counter = Raft_utl_counter

module UPb = Raft_udp_pb
module APb = Raft_app_pb
module Server_stats = Raft_srv_serverstats
module Client_ipc = Raft_srv_clientipc 
module Log = Raft_srv_log 
module Log_record = Raft_srv_logrecord
module Conf = Raft_com_conf
module Compaction = Raft_srv_compaction

module RState = Raft_state
module RLog   = Raft_log
module RPb    = Raft_pb 

module Raft_ipc = Raft_srv_raftipc

type client_request   = Raft_app_pb.client_request * Raft_srv_clientipc.handle
type client_response  = Raft_app_pb.client_response * Raft_srv_clientipc.handle 
type client_responses = client_response list 
type app_requests = Raft_app_pb.app_request list 
type app_response = Raft_app_pb.app_response 

let section = L.Section.make (Printf.sprintf "%10s" "RaftIPC")

module StringMap = Map.Make(struct
  type t = string
  let compare (x:string) (y:string) = Pervasives.compare x y
end)

module Pending_requests = struct 

  type t = client_request StringMap.t
  
  let add t request_id client_request = 
    StringMap.add request_id client_request t
  
  let get_and_remove t request_id =
    match StringMap.find request_id t with
    | client_request ->
      let t = StringMap.remove request_id t  in
      (t, Some client_request)
    | exception Not_found ->
      (t, None)

  let empty = StringMap.empty 

end (* Pending_requests *)

(*
 * All the outgoing RAFT messages are sent in a dedicated
 * concurrent thread [state.outgoing_message_processing]. The 
 * RAFT protocol nevers requires the sender of a RAFT message to block and wait for any 
 * responses. (In fact that response might never come).
 *
 * In order to send those message concurrently, an [Lwt_stream] is used to decouple
 * the threads which wants to compute the outgoing messages from the one which 
 * actually sends them.  
 * 
 * For the caller of this API sending a response is simply pushing the 
 * response to the stream (immediate). The Lwt scheduler will then 
 * pick it up asynchronously by scheduling [state.outgoing_message_processing]
 *
 *)
  
(* Abstract type which internally capture the necessary information to 
 * be maintain between all the RAFT events. 
 * In particular a [connection_state] keeps track of the outstanding 
 * [Add_log] client request. The response to this request can only
 * be sent when the data is commited (ie replicated on a majority 
 * of nodes). Therefore the response will not be returned immediately
 * and some kind of state needs to be kept. 
 *)
type connection_state = {
  pending_requests : Pending_requests.t;
    (* Keeps track of pending request from client *)
  ipc : Raft_ipc.t;
    (* RAFT IPC handling *)
}

type state = {
  logger: Lwt_log_core.logger; 
  stats: Raft_srv_serverstats.t;
  raft_state: RState.t; 
  connection_state: connection_state; 
  log_record_handle : Log_record.t;
}

type t = state 

let make ~logger ~stats ~ipc ~raft_state ~log_record_handle () = 
  {
    logger;
    stats;
    raft_state;
    log_record_handle; 
    connection_state = {
      pending_requests = Pending_requests.empty; 
      ipc;
    }
  }

type result = (state * client_responses * app_requests) 

let handle_notifications logger stats connection_state compaction_handle notifications = 

  (* 
   * Go over each notifications and compute the client response by looking
   * up the map of pending request. 
   *)
  let connection_state, client_responses, app_requests = 
    Counter.Perf.f1 (Server_stats.not_processing stats) (fun notifications -> 
      List.fold_left (fun acc notification ->

      let connection_state, client_responses, app_requests = acc in 
      let {pending_requests; _} = connection_state in 

      match notification with
      | RPb.Committed_data {RPb.rev_log_entries} -> 
        let txs = List.rev_map (fun {RPb.id; data; _} ->
            {APb.tx_id = id; tx_data = data;}
        ) rev_log_entries in
        
        let app_request = APb.(Commit_txs {txs}) in 
        let connection_state = {connection_state with pending_requests} in 
        (connection_state, client_responses, app_request::app_requests) 

      | RPb.New_leader _
      | RPb.No_leader  -> 
        (* TODO need to go through all the pending requests. 
         *)
        acc
      ) (connection_state, [], []) notifications  
    ) notifications 
  in

  (* !! TODO 
   *
   * While the log is commited at the RAFT level, it is not yet confirmed by the 
   * application. 
   *
   * There is therefore a bug when the application crashes while committing
   * log/transaction. The RAFT server has commited the entry and assumes that it
   * is also committed by the application. This will result in one or many
   * log/transaction being unknown to the application. 
   *
   * One robust solution could be that upon connection initialization, the app 
   * and RAFT server can reconcile their latest commited log/transaction.  
   *)

  (* 
   * The RAFT protocol dictates that all commited log entries must be stored
   * permanently on DISK. This way, if a server crashes it can recover. 
   *)
  Lwt_list.iter_s (function
    | RPb.Committed_data {RPb.rev_log_entries} -> 
      Log_record.append_commited_data ~logger ~rev_log_entries compaction_handle 
    | _ -> Lwt.return_unit
  ) notifications
  >|=(fun () -> (connection_state, client_responses, app_requests))

let send_raft_messages {ipc; _ } messages  = 
  Raft_ipc.send_messages ipc messages 

let handle_raft_message ~now state msg = 
  let { 
    logger;
    stats;
    raft_state; 
    connection_state; 
    log_record_handle; 
  } = state in 

  L.log ~logger ~level:L.Notice ~section "Raft Message Received"
  >>=(fun () -> Log.print_state logger section raft_state)
  >>=(fun () -> Log.print_msg_received logger section msg raft_state.RState.id)
  >>=(fun () ->
    Server_stats.tick_raft_msg_recv stats;

    let perf = Server_stats.msg_processing stats in 
    let ret  = Counter.Perf.f3 perf Raft_logic.handle_message raft_state msg now in

    let (raft_state, outgoing_messages, notifications) = ret in 

    handle_notifications logger stats connection_state log_record_handle notifications 
    >|=(fun (connection_state, client_responses, app_requests) ->
      send_raft_messages connection_state outgoing_messages;

      ({state with raft_state; connection_state}, client_responses, app_requests)
    )
  )

let handle_timeout ~now state timeout_type = 
  let { 
    logger; 
    stats; 
    raft_state; 
    connection_state; 
    log_record_handle; 
  } = state in 
  begin match timeout_type with
  | RPb.Heartbeat -> (
    Server_stats.tick_heartbeat stats;
    L.log ~logger ~section ~level:L.Notice "Heartbeat timeout" 
    >|= (fun () ->
      Counter.Perf.f2 (Server_stats.hb_processing stats)
        Raft_logic.handle_heartbeat_timeout raft_state now
    )
    >|= (fun (raft_state, outgoing_messages) -> (raft_state, outgoing_messages, []))
  )

  | RPb.New_leader_election -> (
    Printf.printf "NEW LEADER ELECTION [%2i] \n%!" raft_state.RState.id;
    L.log ~logger ~level:L.Notice ~section "Leader Election timeout"
    >|= (fun () ->
      Raft_logic.handle_new_election_timeout raft_state now
    ))
  end

  >>=(fun (raft_state, outgoing_messages, notifications) ->

    handle_notifications logger stats connection_state log_record_handle notifications 
    >|=(fun (connection_state, client_responses, app_requests) ->
      send_raft_messages connection_state outgoing_messages;
      (
        {state with raft_state; connection_state}, 
        client_responses,
        app_requests
      )
    )
  ) 

let handle_client_requests ~now  state client_requests = 

  let _  = now in 

  let datas = List.map (fun (client_request, _)  -> 
    match client_request with
    | APb.Add_tx {APb.tx_id;tx_data} -> 
      (tx_data, tx_id)
  ) client_requests in 

  let {raft_state; logger; _ } = state in 

  let new_log_response  = 
    Raft_logic.handle_add_log_entries raft_state datas now 
  in 

  match new_log_response with
  | Raft_logic.Delay
  | Raft_logic.Forward_to_leader _ -> 
    L.log ~logger ~level:L.Notice ~section "Log Rejected "
    >|= (fun () ->

      let client_responses = List.fold_left (fun client_responses (_, handle) -> 
        (APb.(Add_log_not_a_leader {
         leader_id = RState.current_leader raft_state
        }), handle)::client_responses
      ) [] client_requests in  

      (state, client_responses, [] (* app_requests *))
    )

  | Raft_logic.Appended (raft_state, outgoing_messages) -> 
    L.log_f 
      ~logger 
      ~level:L.Notice 
      ~section "Logs Added (log size: %i) (nb logs: %i)" 
      raft_state.RState.log.RLog.log_size (List.length datas)  
    >|= (fun () ->
      let {connection_state; _ } = state in 
      let {pending_requests; _ } = connection_state in 

      let pending_requests = List.fold_left (fun pending_requests -> function
        | (APb.Add_tx {APb.tx_id ; _}, _) as r -> 
            Pending_requests.add pending_requests tx_id r 
      ) pending_requests client_requests in 

      let connection_state = {connection_state with pending_requests; } in  

      send_raft_messages connection_state outgoing_messages;
      let client_responses = [] in 
      let app_requests = [] in 
      ({state with raft_state; connection_state}, client_responses, app_requests)
    )
      
let process_app_validation logger (pending_requests, client_responses) validation = 
  let {
    APb.tx_id; 
    APb.result
  } = validation in 
  
  let pending_requests, client_request = Pending_requests.get_and_remove pending_requests tx_id in 

  match client_request, result with
  | None, _ -> 
    (* This is a violation invariant since no pending request should be removed at
     * this stage. 
     * However not critical for now. 
     *)
    L.log_f ~logger ~level:L.Warning ~section "Could not find pending request after validation for tx_id: %s" tx_id 
    >|=(fun () -> 
      (pending_requests, client_responses)
    ) 

  | Some (APb.Add_tx _, handle) , APb.Validation_success -> 
    (* Validation is successful and the corresponding client request  
     * has been retrieved, we can insert start the addition of the request
     * from the RAFT protocol point of view. 
     *) 
    L.log_f ~logger ~level:L.Notice ~section 
      "Validation success from App for tx_id: %s" tx_id 
    >|= (fun () -> 
      let client_response = APb.Add_log_success in 
      let client_response = (client_response, handle) in 
      (pending_requests, client_response::client_responses) 
    )

  | Some (_, handle), APb.Validation_failure {APb.error_message; error_code}  -> 
    (* Validation has failed, the log entry is rejected. The failure is propagated 
     * back to the client which initiated the request and the log entry is never
     * created in the RAFT consensus. 
     *)
    L.log_f ~logger ~level:L.Notice ~section 
      "Validation failure from App, tx_id: %s, code: %i, msg: %s" tx_id error_code error_message
    >|=(fun () -> 
      let client_response = APb.Add_log_validation_failure in 
      let client_response = (client_response, handle) in 
      (pending_requests, client_response::client_responses)
    )

let handle_app_response ~now state app_response = 

  let _ = now in 

  let {connection_state; logger; _ } = state in 
  let {pending_requests; _} = connection_state in 

  match app_response with

  | APb.Committed_txs {APb.validations} -> 
    Lwt_list.fold_left_s (process_app_validation logger) (pending_requests, []) validations
    >|=(fun (pending_requests, client_responses) ->
      let connection_state = {connection_state with pending_requests } in 
      let state = {state with connection_state} in 
      (state, client_responses, [] (* app_requests *))
    )

let handle_compaction_update compacted_intervals state = 
  let {
    logger; 
    raft_state; 
    _ 
  } = state in 
  Compaction.update_state logger compacted_intervals raft_state
  >|=(fun raft_state -> 
    {state with raft_state;} 
  ) 

let raft_state {raft_state; _ } = raft_state 