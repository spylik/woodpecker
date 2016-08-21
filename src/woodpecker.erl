%%% --------------------------------------------------------------------------------
%%% File:    woodpecker.erl
%%% @author  Oleksii Semilietov <spylik@gmail.com>
%%%
%%% @doc
%%% Woodpecker is  
%%%
%%% We support 4 types of requests priority:
%%% 
%%% urgent - process request immidiatly without carry of queue and count of requests. 
%%% be aware, we can got ban when going to use it.
%%% need-retry every one second without degradation till max_retry occurs
%%% 
%%% high - process request immidiatly, but with carry of count of requests.
%%%
%%% normal - process request with carry of queue
%%%
%%% low - low priority (usually used for get_order_book / etc public api)

%%%
%%% @end
%%% --------------------------------------------------------------------------------

-module(woodpecker).

-include("woodpecker.hrl").
-include_lib("stdlib/include/ms_transform.hrl").

%% gen server is here
-behaviour(gen_server).

%% gen_server api
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% public api
-export([
        start_link/1,
        get/2,
        get/3
    ]).

% --------------------------------- gen_server part --------------------------------------

%% start api
start_link(State) when 
				State#woodpecker_state.server =/= undefined 
        andalso State#woodpecker_state.connect_to_port =/= undefined
        andalso State#woodpecker_state.connect_to =/= undefined ->
    %error_logger:info_msg("Woodpecker start with state ~p",[State]),
    gen_server:start_link({local, State#woodpecker_state.server}, ?MODULE, [State, self()], []).

% when #erlpusher_state.report_to undefined, we going to send output to parent pid
init([State = #woodpecker_state{report_to = undefined}, Parent]) ->
    init([State#woodpecker_state{report_to = Parent}, Parent]);

init([State = #woodpecker_state{
        server = Server, 
        heartbeat_freq = Heartbeat_freq
    }, _Parent]) ->
    Ets = generate_ets_name(Server),
    _ = ets:new(Ets, [set, protected, {keypos, #wp_api_tasks.ref}, named_table]),

    TRef = erlang:send_after(Heartbeat_freq, self(), heartbeat),

    % return state
    {ok, 
        State#woodpecker_state{
            ets = Ets,
            heartbeat_tref = TRef,
            report_topic = generate_topic(State),
            report_nofin_topic = generate_nofin_topic(State)
        }}.

%--------------handle_call-----------------

%% handle_call for all other thigs
handle_call(Msg, _From, State) ->
    error_logger:warning_msg("we are in undefined handle_call with message ~p~n",[Msg]),
    {reply, ok, State}.
%-----------end of handle_call-------------

%--------------handle_cast-----------------

%% create task
handle_cast({create_task, Method, Priority, Url}, State) ->
    %error_logger:info_msg("Woodpecker got new task: ~p: ~p", [Method,Url]),
    TempRef = erlang:make_ref(),
    ets:insert(State#woodpecker_state.ets, 
        Task = #wp_api_tasks{
            ref = TempRef,
            status = new,
            priority = Priority,
            method = Method,
            url = Url,
            insert_date = get_time()
        }),
    case Priority of
        urgent ->
            gen_server:cast(self(), [gun_request, Task]);
        high when State#woodpecker_state.api_requests_quota > 0 ->
            gen_server:cast(self(), [gun_request, Task]);
        _ ->
            ok
    end,
    {noreply, State};

%% gun_request
handle_cast([gun_request, Task], State) ->
    update_request_to_processing(State, Task, Task#wp_api_tasks.ref),
    NewState = connect(State, State#woodpecker_state.gun_pid),
    request(NewState, Task, NewState#woodpecker_state.gun_pid),
    {noreply, NewState};


%% handle_cast for all other thigs
handle_cast(Msg, State) ->
    error_logger:warning_msg("we are in undefined handle cast with message ~p~n",[Msg]),
    {noreply, State}.
%-----------end of handle_cast-------------


%--------------handle_info-----------------

%% heartbeat
handle_info(heartbeat, State = #woodpecker_state{
        heartbeat_tref = Heartbeat_tref, 
        requests_allowed_in_period = Requests_allowed_in_period,
        ets = Ets,
        heartbeat_freq = Heartbeat_freq,
        requests_allowed_by_api = Requests_allowed_by_api
    }) ->
    _ = erlang:cancel_timer(Heartbeat_tref),
    
    NewThan = get_time() - Requests_allowed_in_period,
    
    % we going to run task
    RequestsInPeriod = requests_in_period(Ets,NewThan),
    OldQuota = Requests_allowed_by_api-RequestsInPeriod,
    Quota = run_task(State#woodpecker_state{api_requests_quota = OldQuota}),

    % going to delete completed requests
    _ = clean_completed(Ets,NewThan),

    % going to retry requests with status processing and got_nofin 
    _ = retry_staled_requests(State),

    % new heartbeat time refference
    TRef = erlang:send_after(Heartbeat_freq, self(), heartbeat),

    % return state    
    {noreply, 
        State#woodpecker_state{
            api_requests_quota=Quota, 
            heartbeat_tref=TRef
        }
    };

%% gun_response, nofin state
handle_info({gun_response,_ConnPid,ReqRef,nofin,200,_Headers}, State) ->
    ets:update_element(
        State#woodpecker_state.ets, ReqRef, [
            {#wp_api_tasks.status, got_gun_response}, 
            {#wp_api_tasks.last_response_date, get_time()}
        ]),
    {noreply, State};

%% gun_data, nofin state
handle_info({gun_data,_ConnPid,ReqRef,nofin,Data}, State) ->
    %error_logger:info_msg("got data with nofin state for ReqRef ~p",[ReqRef]),
    case ets:lookup(State#woodpecker_state.ets, ReqRef) of
        [Task] -> 
            Chunked = chunk_data(Task#wp_api_tasks.chunked_data, Data),
            ets:insert(State#woodpecker_state.ets, 
                Task#wp_api_tasks{
                status = got_nofin_data,
                last_response_date = get_time(),
                chunked_data = Chunked
            }),

            % chunked output
            send_nofin_output(State, #woodpecker_frame{data=Chunked, recipe_pid=self(), task=Task});

        [] -> error_logger:error_msg("[got_nofin] ReqRef ~p not found in ETS table. Data is ~p", [ReqRef, Data])
    end,
    {noreply, State};

%% gun_data, fin state
handle_info({gun_data,_ConnPid,ReqRef,fin,Data}, State) ->
    %error_logger:info_msg("got data with fin state for ReqRef ~p",[ReqRef]),
    case ets:lookup(State#woodpecker_state.ets, ReqRef) of
        [Task] ->
            Chunked = chunk_data(Task#wp_api_tasks.chunked_data, Data),
            ets:insert(State#woodpecker_state.ets, 
                Task#wp_api_tasks{
                    status = got_fin_data,
                    last_response_date = get_time(),
                    chunked_data = Chunked
                }
            ),

            % final output
            send_output(State, #woodpecker_frame{data=Chunked, recipe_pid=self(), task=Task});
        [] -> error_logger:error_msg("[got_fin] ReqRef ~p not found in ETS table in. Data is ~p", [ReqRef, Data])
    end,
    {noreply, State};

%% got recipe
handle_info({recipe, ReqRef, NewStatus}, State) ->
    ets:update_element(State#woodpecker_state.ets, ReqRef, {#wp_api_tasks.status, NewStatus}),
    {noreply, State};

% close and other events bringing gun to flush

%% gun_error
handle_info({gun_error,ConnPid,ReqRef,{Reason,Descr}}, State) ->
    error_logger:error_msg("got gun_error for ReqRef ~p with reason: ~p, ~p",[ReqRef, Reason, Descr]),
    ets:update_element(State#woodpecker_state.ets, ReqRef, 
        {#wp_api_tasks.status, need_retry}
    ),
    NewState = flush_gun(State, ConnPid),
    {noreply, NewState};

%% gun_down
handle_info({gun_down,ConnPid,_,_,_,_}, State) ->
    NewState = flush_gun(State, ConnPid),
    {noreply, NewState};

%% unexepted normal 'DOWN'
handle_info({'DOWN', _ReqRef, _, ConnPid, _}, State) ->
    NewState = flush_gun(State, ConnPid),
    {noreply, NewState};

%% handle_info for all other thigs
handle_info(Msg, State) ->
    error_logger:warning_msg("we are in undefined handle info with message ~p~n",[Msg]),
    {noreply, State}.
%-----------end of handle_info-------------

terminate(_Reason, State) ->
    flush_gun(State, undefined).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

% ============================ end of gen_server part ==========================
% --------------------------------- other functions ----------------------------

% ----------------------- other private functions ---------------------------

%% open new connection to the server or do nothing if connection present
connect(State = #woodpecker_state{
        connect_to = Connect_to,
        connect_to_port = Connect_to_port
    }, undefined) ->
    %error_logger:info_msg("need new connection ~p ~p",[Connect_to,Connect_to_port]),
    {ok, Pid} = gun:open(Connect_to, Connect_to_port, #{retry=>0}),
    case gun:await_up(Pid) of
        {ok, _Protocol} ->
			%error_logger:info_msg("Connection oppened with protocol ~p to ~p ~p",[Protocol, Connect_to,Connect_to_port]),
			GunRef = monitor(process, Pid),
            State#woodpecker_state{gun_pid=Pid, gun_ref=GunRef};
        {error, timeout} ->
            flush_gun(State, Pid)
    end;
connect(State, _) ->
    %error_logger:info_msg("we have connection"),
    State.

%% request
request(State, Task, undefined) ->
    %error_logger:info_msg("going to update task ~p to need_retry", [Task#wp_api_tasks.ref]),
    ets:update_element(State#woodpecker_state.ets, Task#wp_api_tasks.ref, [
            {#wp_api_tasks.status, need_retry}
        ]),
    undefined;
request(State, Task, GunPid) when Task#wp_api_tasks.method =:= get ->
    %error_logger:info_msg("going to update task ~p to processing", [Task#wp_api_tasks.ref]),
    ReqRef = gun:get(GunPid, Task#wp_api_tasks.url),
    update_request_to_processing(State, Task, ReqRef).

%% chunk data
chunk_data(undefined, NewData) ->
    NewData;
chunk_data(OldData, NewData) ->
    <<OldData/binary, NewData/binary>>.

%% update request in ets to processing
update_request_to_processing(_, _, undefined) ->
    ok;
update_request_to_processing(State, Task, ReqRef) ->
    case Task#wp_api_tasks.ref =/= ReqRef of
        true ->
            ets:delete(State#woodpecker_state.ets, Task#wp_api_tasks.ref);
        false ->
            ok
    end,
    ets:insert(State#woodpecker_state.ets, 
        Task#wp_api_tasks{
            ref = ReqRef,
            status = processing,
            request_date = get_time(),
            retry_count = Task#wp_api_tasks.retry_count + 1
        }).

%% gun clean_up
flush_gun(State, ConnRef) ->
    %error_logger:info_msg("We are in flush gun section with state ~p", [State]),
    case ConnRef =:= undefined of
        true when State#woodpecker_state.gun_ref =/= undefined ->
            demonitor(State#woodpecker_state.gun_ref),
            gun:close(State#woodpecker_state.gun_pid),
            gun:flush(State#woodpecker_state.gun_pid);
        true ->
            ok;
        false when State#woodpecker_state.gun_pid =:= undefined ->
            gun:close(ConnRef),
            gun:flush(ConnRef);
        false when State#woodpecker_state.gun_pid =:= ConnRef ->
            demonitor(State#woodpecker_state.gun_ref),
            gun:close(State#woodpecker_state.gun_pid),
            gun:flush(State#woodpecker_state.gun_pid)
    end,
    State#woodpecker_state{gun_pid=undefined, gun_ref=undefined}.

%% get requests quota
requests_in_period(Ets, DateFrom) ->
    MS = [{
            #wp_api_tasks{status = '$2', last_response_date = '$1', _ = '_'},
                [
                    {'=/=','$2',need_retry},
                    {'=/=','$1',undefined},
                    {'>','$1',{const,DateFrom}}
                ],
                [true]
            }
        ],
    ets:select_count(Ets, MS).

%% retry staled requests
retry_staled_requests(_State = #woodpecker_state{
        timeout_for_nofin_requests = Timeout_for_nofin_requests,
        timeout_for_processing_requests = Timeout_for_processing_requests,
        ets = Ets
    }) ->
    Time = get_time(),
    LessThanNofin = Time - Timeout_for_nofin_requests,
    LessThanProcessing = Time - Timeout_for_processing_requests,

    MS = [{
            #wp_api_tasks{status = '$1', last_response_date = '$2', request_date = '$3', _ = '_'},
                [   
                    {'orelse',
                        {'and',
                            {'=:=','$1',processing},
                            {'<','$3',{const,LessThanProcessing}}
                        },
                        {'and',
                            {'=:=','$1',got_nofin_data},
                            {'<','$2',{const,LessThanNofin}}
                        }
                    }
                ], ['$_']
            }],
    lists:map(
        fun(Task) ->
            ets:insert(Ets, 
                Task#wp_api_tasks{
                    status = need_retry,
                    chunked_data = undefined
            })
        end,
        ets:select(Ets, MS)).

%% clean completed request (match spec)
clean_completed(Ets,OldThan) ->
    MS = [{
            #wp_api_tasks{ref = '$1', status = '$2', request_date = '$3', _ = '_'},
                [   
                    {'<', '$3', OldThan},
                    {'orelse',
                        {'=:=','$2', complete},
                        {'=:=','$2', got_fin_data}
                    }
                ], ['$1']
            }],
    lists:map(
        fun(Key) ->
            ets:delete(Ets, Key)
        end,
        ets:select(Ets, MS)).

%% run task from ets-queue
run_task(State = #woodpecker_state{
        degr_for_incomplete_requests = Degr_for_incomplete_requests,
        max_degr_for_incomplete_requests = Max_degr_for_incomplete_requests
    }) ->
    Time = get_time(),
    Order = [
        [[{
            #wp_api_tasks{
                priority = urgent, 
                status = need_retry, 
                max_retry = '$2', 
                retry_count = '$1',
                _ = '_'
            }, [
                {'<','$1','$2'}
            ], 
            ['$_']}
        ]] | [[
            [{
                #wp_api_tasks{
                    priority = Priority, 
                    status = need_retry, 
                    max_retry = '$2', 
                    retry_count = '$1',
                    _ = '_'
                }, [
                    {'<','$1',10},
                    {'<','$1','$2'}
                ], ['$_']
            }],
            [{
                #wp_api_tasks{
                    priority = Priority, 
                    status = need_retry,
                    request_date = '$3',
                    max_retry = '$2', 
                    retry_count = '$1',
                    _ = '_'
                }, [
                    {'andalso',
                        {'>','$1',9},
                        {'<','$1','$2'}
                    },
                    {'orelse',
                        {'<','$3',{'-',{const,Time},{'*','$1', Degr_for_incomplete_requests}}},
                        {'<','$3',{'-',{const,Time},Max_degr_for_incomplete_requests}}
                    }
                ], ['$_']
            }],
            [{
                #wp_api_tasks{
                    priority = Priority, 
                    status = new,
                    _ = '_'
                },
                [], ['$_']
            }]
        ] || Priority <- [high, normal, low]
    ]],

    run_task(State, order_stage, Order).

%% run_task order_stage
run_task(State = #woodpecker_state{
        api_requests_quota = Api_requests_quota,
        ets = Ets    
    }, order_stage, [[H|T1]|T2]) ->
    case Api_requests_quota > 0 of
        true ->
            QuotaNew = run_task(State, cast_stage, ets:select(Ets, H)),
            run_task(State#woodpecker_state{api_requests_quota=QuotaNew}, order_stage, [T1|T2]);
        false ->
            0
    end;
run_task(State, order_stage, [[]|T2]) ->
    run_task(State, order_stage, T2);

%% run_task cast_stage
run_task(State = #woodpecker_state{
        api_requests_quota = Api_requests_quota
    }, cast_stage, [H|T]) ->
    case Api_requests_quota > 0 of
        true ->
%            io:format("going to cast request ~p~n",[H]),
            gen_server:cast(self(), [gun_request, H]),
            QuotaNew = Api_requests_quota -1,
            run_task(State#woodpecker_state{api_requests_quota=QuotaNew}, cast_stage, T);
        false ->
            0
    end;
run_task(State, _, []) ->
    State#woodpecker_state.api_requests_quota.

%% generate ETS table name
generate_ets_name(Server) ->
    list_to_atom(lists:append([atom_to_list(Server), "_api_tasks"])).

%% get time
get_time() ->
    erlang:convert_time_unit(erlang:system_time(), native, milli_seconds).

%% generate report topic
generate_topic(_State = #woodpecker_state{
        report_topic = undefined,
        server = Server
    }) ->
    list_to_binary(lists:concat([atom_to_list(Server), ".output"]));
generate_topic(State) ->
    State#woodpecker_state.report_topic.

%% generate nofin report topic
generate_nofin_topic(_State = #woodpecker_state{
        report_topic = undefined,
        server = Server
    }) ->
    list_to_binary(lists:concat([Server, ".nofin_output"]));
generate_nofin_topic(State) ->
    State#woodpecker_state.report_topic.

%% send nofin output (when report_nofin_to undefined we do nothing)
send_nofin_output(_State = #woodpecker_state{report_nofin_to=undefined}, _Frame) ->
    ok;
send_nofin_output(_State = #woodpecker_state{
        report_nofin_to=erlroute, 
        report_nofin_topic=Report_Nofin_topic, 
        server=Server
    }, Frame) ->
    erlroute:pub(?MODULE, Server, ?LINE, Report_Nofin_topic, Frame);
send_nofin_output(_State = #woodpecker_state{report_nofin_to=ReportNofinTo}, Frame) ->
    ReportNofinTo ! Frame.

%% send output
send_output(_State = #woodpecker_state{
        report_to=erlroute, 
        report_topic=Report_topic, 
        server=Server
    }, Frame) ->
    erlroute:pub(?MODULE, Server, ?LINE, Report_topic, Frame);
send_output(_State = #woodpecker_state{report_to=ReportTo}, Frame) ->
    ReportTo ! Frame.

%---------------------- public api others functions ----------------------

get(Pid, Url) ->
    get(Pid, Url, low).
get(Pid, Url, Proprity) ->
    gen_server:cast(Pid, {create_task,get,Proprity,Url}).
