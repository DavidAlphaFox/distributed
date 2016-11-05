(* The name server provides registration of names to process ids.
   
   main_proc
     - spawn and monitor registra, if registra goes down it's restarted

   registra
     - listen for register and whois messages and process them in a receive loop
     - for a register request just update the mapping in the named_processes mutable
     - for a whois request
        1) if the entry exists in named_processes then send response
        2) if it doesn't exist then spawn a wait_for_register_proc to wait for a registration
           by the requested name

   wait_for_register_proc
    - just wait for a registration message for a given name then sends the pid back to then
      original whois requester                    
*)
module D = Distributed_lwt.Make(Message)

let logger =
  Lwt_log.add_rule "*" Lwt_log.Fatal ; 
  Lwt_log.channel ~template:"$(date).$(milliseconds) {$(level)} : $(message)" ~close_mode:`Close ~channel:Lwt_io.stdout () 

let config = D.Remote { D.Remote_config.node_name = "name_server" ; 
                        D.Remote_config.logger = logger ;   
                        D.Remote_config.local_port = 45000 ;
                        D.Remote_config.heart_beat_frequency = 5.0 ;
                        D.Remote_config.heart_beat_timeout = 10.0 ;
                        D.Remote_config.connection_backlog = 10 ;
                        D.Remote_config.node_ip = "127.0.0.1" ;
                        D.Remote_config.remote_nodes = [] ;
                      } 

let named_processes : (string, Distributed.Process_id.t) Hashtbl.t = Hashtbl.create 10

let option_get = function
  | Some v -> v
  | _ -> assert false

let wait_for_register_proc pid_to_send_to name_to_wait_for = D.(
    let pid = ref None in
    receive_loop [
      case (function Message.Register _ -> true | _ -> false)
        (function
          | Message.Register (name, registered_pid) ->
            if name = name_to_wait_for 
            then (pid := Some registered_pid ; return false)
            else return true
          | _ -> assert false
        ) ;
      case (fun _ -> true) 
        (fun _ -> return true) 
    ] >>= fun () ->
    pid_to_send_to >! (Message.Whois_result (option_get !pid)) 
  )  

let registra () = D.(
    receive_loop [
      case (function Message.Register _ -> true | _ -> false)
        (function
          | Message.Register (name, registered_pid) ->
            Hashtbl.add named_processes name registered_pid ;
            registered_pid >! Message.Register_ok >>= fun () ->
            lift_io (Lwt_io.printlf "Successfully registered name %s" name) >>= fun () ->
            return true
          | _ -> assert false
        );
      case (function Message.Whois _ -> true  | _ -> false)
        (function
          | Message.Whois (name,requester_pid) ->
            catch 
              (fun () ->
                 let pid = Hashtbl.find named_processes name in
                 requester_pid >! Message.Whois_result pid >>= fun () ->
                 lift_io (Lwt_io.printlf "Lookup of processes named %s succeeded" name) >>= fun () ->
                 return true                
              )
              (fun _ -> 
                 get_self_node >>= fun self_node ->
                 spawn self_node (wait_for_register_proc requester_pid name) >>= fun _ ->
                 lift_io (Lwt_io.printlf "Lookup of processes named %s failed, waiting for registration" name) >>= fun () ->
                 return true
              )
          | _ -> assert false
        ) ;
      case (fun _ -> true)
        (fun m ->
           lift_io (Lwt_io.printlf "Ignoring message %s" (Message.string_of_message m)) >>= fun () -> 
           return true
        )
    ]
  )

let main_proc () = D.(
    get_self_node >>= fun self_node ->
    spawn ~monitor:true self_node (registra ()) >>= fun _ ->
    receive_loop [
      termination_case 
        (function
          | _ -> 
            spawn ~monitor:true self_node (registra ()) >>= fun _ ->
            return true
        ) ;
      case (fun _ -> true)
        (fun _ -> return true)
    ]
  )

let () = 
  Lwt_main.run (D.run_node ~process:(main_proc ()) config)