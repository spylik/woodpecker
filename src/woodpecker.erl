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
%%% be aware, it can get ban when going to spam the remote server
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
-define(NOTEST, true).
-ifdef(TEST).
    -compile(export_all).
-endif.

-include("woodpecker.hrl").
-include_lib("stdlib/include/ms_transform.hrl").
-include("deps/teaser/include/utils.hrl").

%% gen server is here
-behaviour(gen_server).

%% gen_server api
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% public api
-export([
        start_link/1,
        stop/1,
        stop/2,
        get_topic/1,
        get_nofin_topic/1,
        get/2,
        get/3
    ]).

% --------------------------------- gen_server part --------------------------------------

% @doc start api when State is #woodpecker_state
-spec start_link(State) -> Result when
    State   :: woodpecker_state(),
    Result  :: {ok,Pid} | ignore | {error,Error},
    Pid     :: pid(),
    Error   :: {already_started,Pid} | term().

start_link(State) when 
				State#woodpecker_state.server =/= undefined 
        andalso State#woodpecker_state.connect_to_port =/= undefined
        andalso State#woodpecker_state.connect_to =/= undefined ->
    gen_server:start_link({local, State#woodpecker_state.server}, ?MODULE, {State, self()}, []).

% @doc API for stop gen_server. Default is sync call.
-spec stop(Server) -> Result when
    Server  :: server(),
    Result  :: term().

stop(Server) ->
    stop('sync', Server).

% @doc API for stop gen_server. We support async casts and sync calls aswell.
-spec stop(SyncAsync, Server) -> Result when
    SyncAsync   :: 'sync' | 'async',
    Server      :: server(),
    Result      :: term().

stop('sync', Server) ->
    gen_server:stop(Server);
stop('async', Server) ->
    gen_server:cast(Server, stop).

% @doc when #erlpusher_state.report_to undefined, we going to send output to parent pid
-spec init({State, Parent}) -> Result when
    State   :: woodpecker_state(),
    Parent  :: pid(),
    Result  :: {ok, NState},
    NState  :: woodpecker_state().

init({State = #woodpecker_state{report_to = 'undefined'}, Parent}) ->
    init({State#woodpecker_state{report_to = Parent}, Parent});

init({State = #woodpecker_state{
        server = Server, 
        heartbeat_freq = Heartbeat_freq,
        max_paralell_requests = Max_paralell_requests,
        requests_allowed_by_api = Requests_allowed_by_api
    }, _Parent}) ->
    Ets = generate_ets_name(Server),
    _ = ets:new(Ets, [set, protected, {keypos, #wp_api_tasks.ref}, named_table]),

    TRef = erlang:send_after(Heartbeat_freq, self(), heartbeat),

    % return state
    {ok, 
        State#woodpecker_state{
            ets = Ets,
            heartbeat_tref = TRef,
            report_topic = generate_topic(State),
            report_nofin_topic = generate_nofin_topic(State),
            api_requests_quota = Requests_allowed_by_api,
            paralell_requests_quota = Max_paralell_requests
        }}.

%--------------handle_call-----------------

% @doc callbacks for gen_server handle_call.
-spec handle_call(Message, From, State) -> Result when
    Message :: term(),
    From :: {pid(), Tag},
    Tag :: term(),
    State :: term(),
    Result :: {reply, Result, State}.

%% handle_call for all other thigs
handle_call(Msg, _From, State) ->
    error_logger:warning_msg("we are in undefined handle_call with message ~p~n",[Msg]),
    {reply, ok, State}.
%-----------end of handle_call-------------

%--------------handle_cast-----------------

% @doc callbacks for gen_server handle_call.
-spec handle_cast(Message, State) -> Result when
    Message :: 'stop' | newtaskmsg(),
    State   :: woodpecker_state(),
    Result  :: {noreply, State} | {stop, normal, State}.

%% create task
handle_cast({'create_task', Method, Priority, Url}, State) ->
    TempRef = erlang:make_ref(),
    ets:insert(State#woodpecker_state.ets, 
        Task = #wp_api_tasks{
            ref = TempRef,
            status = 'new',
            priority = Priority,
            method = Method,
            url = Url,
            insert_date = get_time()
        }),
    Quota = get_quota(State),
    ?debug(State),
    ?debug(Quota),
    NewState = case Priority of
        'urgent' ->
            gun_request(Task, State#woodpecker_state{api_requests_quota = Quota});
        'high' when Quota > 0 ->
            gun_request(Task, State#woodpecker_state{api_requests_quota = Quota});
        _ ->
            State
    end,
    ?here,
    {noreply, NewState};

% handle_cast for stop
handle_cast(stop, State) ->
    {stop, normal, State};

% handle_cast for all other thigs
handle_cast(Msg, State) ->
    error_logger:warning_msg("we are in undefined handle cast with message ~p~n",[Msg]),
    {noreply, State}.
%-----------end of handle_cast-------------


%--------------handle_info-----------------

% @doc callbacks for gen_server handle_info.
-spec handle_info(Message, State) -> Result when
    Message :: term(),
    State   :: term(),
    Result  :: {noreply, State}.

%% heartbeat
handle_info('heartbeat', State = #woodpecker_state{
        heartbeat_tref = Heartbeat_tref, 
        requests_allowed_in_period = Requests_allowed_in_period,
        ets = Ets,
        heartbeat_freq = Heartbeat_freq
    }) ->
    _ = erlang:cancel_timer(Heartbeat_tref),
    
    NewThan = get_time() - Requests_allowed_in_period,
    OldQuota = get_quota(State, NewThan),
    
    % going to run task if have quota
    NewState = run_task(State#woodpecker_state{api_requests_quota = OldQuota}, 'order_stage', prepare_ms(State)),

    % going to delete completed requests
    _ = clean_completed(Ets,NewThan),

    % going to retry requests with status processing and got_nofin 
    _ = retry_staled_requests(NewState),

    % new heartbeat time refference
    TRef = erlang:send_after(Heartbeat_freq, self(), heartbeat),

    % return state    
    {noreply, 
        NewState#woodpecker_state{
            heartbeat_tref=TRef
        }
    };

%% gun_response, nofin state
handle_info({'gun_response',_ConnPid,ReqRef,nofin,200,_Headers}, State) ->
    ?warning("got gun_response ~p",[gun_response]),
    ets:update_element(
        State#woodpecker_state.ets, ReqRef, [
            {#wp_api_tasks.status, 'got_gun_response'}, 
            {#wp_api_tasks.last_response_date, get_time()}
        ]),
    {noreply, State};

%% gun_data, nofin state
handle_info({'gun_data',_ConnPid,ReqRef,'nofin',Data}, State) ->
    %error_logger:info_msg("got data with nofin state for ReqRef ~p",[ReqRef]),
    case ets:lookup(State#woodpecker_state.ets, ReqRef) of
        [Task] -> 
            Chunked = chunk_data(Task#wp_api_tasks.chunked_data, Data),
            ets:insert(State#woodpecker_state.ets, 
                Task#wp_api_tasks{
                status = 'got_nofin_data',
                last_response_date = get_time(),
                chunked_data = Chunked
            }),

            % chunked output
            send_nofin_output(State, #woodpecker_frame{data=Chunked, recipe_pid=self(), task=Task});

        [] -> error_logger:error_msg("[got_nofin] ReqRef ~p not found in ETS table. Data is ~p", [ReqRef, Data])
    end,
    {noreply, State};

%% gun_data, fin state
handle_info({'gun_data',_ConnPid,ReqRef,'fin',Data}, State) ->
    %error_logger:info_msg("got data with fin state for ReqRef ~p",[ReqRef]),
    case ets:lookup(State#woodpecker_state.ets, ReqRef) of
        [Task] ->
            Chunked = chunk_data(Task#wp_api_tasks.chunked_data, Data),
            ets:insert(State#woodpecker_state.ets, 
                Task#wp_api_tasks{
                    status = 'got_fin_data',
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
handle_info({'recipe', ReqRef, NewStatus}, State) ->
    ets:update_element(State#woodpecker_state.ets, ReqRef, {#wp_api_tasks.status, NewStatus}),
    {noreply, State};

%% unexepted 'DOWN'
handle_info({'DOWN', ReqRef, 'process', ConnPid, Reason}, State) ->
    ?debug("got DOWN for ConnPid ~p, ReqRef ~p with Reason: ~p",[ConnPid, ReqRef, Reason]),
    ets:update_element(State#woodpecker_state.ets, ReqRef, 
        {#wp_api_tasks.status, 'need_retry'}
    ),
    NewState = flush_gun(State, ConnPid),
    {noreply, NewState};

%% gun_error
handle_info({'gun_error', ConnPid, ReqRef, {Reason,Descr}}, State) ->
    error_logger:error_msg("got gun_error for ConnPid ~p, ReqRef ~p with reason: ~p, ~p",[ConnPid, ReqRef, Reason, Descr]),
    ets:update_element(State#woodpecker_state.ets, ReqRef, 
        {#wp_api_tasks.status, 'need_retry'}
    ),
    NewState = flush_gun(State, ConnPid),
    {noreply, NewState};

%% gun_down
handle_info({'gun_down',ConnPid,_,_,_,_}, State) ->
    error_logger:info_msg("got gun_down for ConnPid ~p",[ConnPid]),
%    NewState = flush_gun(State, ConnPid),
    {noreply, State};

%% handle_info for all other thigs
handle_info(Msg, State) ->
    error_logger:warning_msg("we are in undefined handle info with message ~p~n",[Msg]),
    {noreply, State}.
%-----------end of handle_info-------------

% @doc call back for terminate (we going to cancel timer here)
-spec terminate(Reason, State) -> term() when
    Reason :: 'normal' | 'shutdown' | {'shutdown',term()} | term(),
    State :: term().

terminate(_Reason, State) ->
    flush_gun(State, undefined),
    _ = erlang:cancel_timer(State#woodpecker_state.heartbeat_tref).

% @doc call back for code_change
-spec code_change(OldVsn, State, Extra) -> Result when
    OldVsn :: Vsn | {down, Vsn},
    Vsn :: term(),
    State :: term(),
    Extra :: term(),
    Result :: {ok, NewState},
    NewState :: term().

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

% ============================ end of gen_server part ==========================
% --------------------------------- other functions ----------------------------

% ----------------------- other private functions ---------------------------

%% open new connection to the server or do nothing if connection present
connect(#woodpecker_state{
        connect_to = Connect_to,
        connect_to_port = Connect_to_port,
        gun_pid = 'undefined'} = State) ->
    error_logger:info_msg("Going connect to ~p:~p",[Connect_to,Connect_to_port]),
    {ok, Pid} = gun:open(Connect_to, Connect_to_port, #{retry=>0}),
	GunMonRef = monitor(process, Pid),
    case gun:await_up(Pid) of
        {ok, Protocol} ->
            error_logger:info_msg("Connected to ~p:~p ~p",[Connect_to,Connect_to_port,Protocol]),
            State#woodpecker_state{gun_pid=Pid, gun_mon_ref=GunMonRef};
        {error, 'timeout'} ->
            error_logger:warning_msg("Timeout during conneciton to ~p:~p",[Connect_to,Connect_to_port]),
            flush_gun(State#woodpecker_state{gun_pid=Pid, gun_mon_ref=GunMonRef}, Pid)
    end;
connect(State) -> State.

gun_request(Task, State) ->
    update_request_to_processing(State, Task, Task#wp_api_tasks.ref),
    request(connect(State), Task).

% @doc get_quota with respect of previous requests
-spec get_quota(State) -> Result when
    State   :: woodpecker_state(),
    Result  :: pos_integer().

get_quota(State = #woodpecker_state{requests_allowed_in_period = Requests_allowed_in_period}) ->
    get_quota(State, get_time() - Requests_allowed_in_period).

% @doc get_quota with respect of previous requests
-spec get_quota(State,NewThan) -> Result when
    State   :: woodpecker_state(),
    NewThan :: pos_integer(),
    Result  :: pos_integer().

get_quota(#woodpecker_state{
        requests_allowed_by_api = Requests_allowed_by_api,
        ets = Ets}, NewThan) ->
    RequestsInPeriod = requests_in_period(Ets,NewThan),
    ?debug(RequestsInPeriod),
    ?debug(Requests_allowed_by_api),
    Requests_allowed_by_api-RequestsInPeriod.

% @doc do request
request(#woodpecker_state{gun_pid='undefined'} = State, Task) ->
    ets:update_element(State#woodpecker_state.ets, Task#wp_api_tasks.ref, [
            {#wp_api_tasks.status, 'need_retry'}
        ]);
request(#woodpecker_state{
        gun_pid = GunPid, 
        api_requests_quota = Api_requests_quota,
        paralell_requests_quota = Paralell_requests_quota
    } = State, #wp_api_tasks{method = 'get'} = Task) ->
    ReqRef = gun:get(GunPid, Task#wp_api_tasks.url),
    update_request_to_processing(State, Task, ReqRef),
    State#woodpecker_state{api_requests_quota = Api_requests_quota-1, paralell_requests_quota = Paralell_requests_quota-1}.

% @doc chunk data
chunk_data(undefined, NewData) ->
    NewData;
chunk_data(OldData, NewData) ->
    <<OldData/binary, NewData/binary>>.

% @doc update request in ets to processing
update_request_to_processing(_, _, 'undefined') -> 'undefined';
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

% @doc gun clean_up
flush_gun(State, GunPid) ->
    %error_logger:info_msg("We are in flush gun section with state ~p", [State]),
    case GunPid =:= 'undefined' of
        true when State#woodpecker_state.gun_mon_ref =/= undefined ->
            demonitor(State#woodpecker_state.gun_mon_ref),
            gun:close(State#woodpecker_state.gun_pid);
            %gun:flush(State#woodpecker_state.gun_pid);
        true ->
            ok;
        false when State#woodpecker_state.gun_pid =:= undefined ->
            error_logger:error_msg("Something going wrong. We got GunPid to flush while in state is undefined. Going to flush GunPid"),
            gun:close(GunPid);
            %gun:flush(GunPid);
        false when State#woodpecker_state.gun_pid =:= GunPid ->
            demonitor(State#woodpecker_state.gun_mon_ref),
            gun:close(State#woodpecker_state.gun_pid)
            %gun:flush(State#woodpecker_state.gun_pid)
    end,
    State#woodpecker_state{gun_pid='undefined', gun_mon_ref='undefined'}.

%% get requests quota
requests_in_period(Ets, DateFrom) ->
    MS = [{
            #wp_api_tasks{status = '$2', last_response_date = '$1', _ = '_'},
                [
                    {'orelse',
                        {'and',
                            {'and',
                                {'=/=','$2','need_retry'},
                                {'>','$1',{const,DateFrom}},
                                {'=/=','$1','undefined'}
                            },
                            {'=/=','$2','need_retry'}
                        },    
                        {'=:=','$2','processing'}
                    }
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
                            {'=:=','$1','processing'},
                            {'<','$3',{const,LessThanProcessing}}
                        },
                        {'and',
                            {'=:=','$1','got_nofin_data'},
                            {'<','$2',{const,LessThanNofin}}
                        }
                    }
                ], ['$_']
            }],
    lists:map(
        fun(Task) ->
            ets:insert(Ets, 
                Task#wp_api_tasks{
                    status = 'need_retry',
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
                        {'=:=','$2', 'complete'},
                        {'=:=','$2', 'got_fin_data'}
                    }
                ], ['$1']
            }],
    lists:map(
        fun(Key) ->
            ets:delete(Ets, Key)
        end,
        ets:select(Ets, MS)).

%% run task from ets-queue
prepare_ms(#woodpecker_state{
        degr_for_incomplete_requests = Degr_for_incomplete_requests,
        max_degr_for_incomplete_requests = Max_degr_for_incomplete_requests
    }) ->
    Time = get_time(),
    Order = [
        [[{
            #wp_api_tasks{
                priority = 'urgent', 
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
                    status = 'need_retry', 
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
                    status = 'need_retry',
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
                    status = 'new',
                    _ = '_'
                },
                [], ['$_']
            }]
        ] || Priority <- ['high', 'normal', 'low']
    ]],
    Order.

% @doc run task
-spec run_task(State, Stage, Tasks) -> Result when
    State   :: woodpecker_state(),
    Stage   :: stage(),
    Tasks   :: [ets:match_spec()],
    Result  :: woodpecker_state().

% when head is empty going to check tail
run_task(State, 'order_stage', [[]|T2]) ->
    run_task(State, 'order_stage', T2);

% when tasks list is empty, just return #woodpecker_state.api_requests_quota.
run_task(State = #woodpecker_state{
       max_paralell_requests = Max_paralell_requests
    }, _Stage, []) ->
    State#woodpecker_state{paralell_requests_quota = Max_paralell_requests};

% when we do not have free slots
run_task(State = #woodpecker_state{
        api_requests_quota = Api_requests_quota,
        paralell_requests_quota = Paralell_requests_quota,
        max_paralell_requests = Max_paralell_requests
    }, _Stage, _Tasks) when Api_requests_quota =< 0 orelse Paralell_requests_quota =< 0 -> 
    State#woodpecker_state{paralell_requests_quota = Max_paralell_requests};

% run_task order_stage (when have free slots we able to select tasks with current parameters)
run_task(State = #woodpecker_state{
        api_requests_quota = Api_requests_quota,
        ets = Ets
    }, 'order_stage', [[H|T1]|T2]) when Api_requests_quota > 0 ->
    Tasks = ets:select(Ets, H),
    NewState = run_task(State, 'cast_stage', Tasks),
    run_task(NewState, 'order_stage', [T1|T2]);

%% run_task cast_stage
run_task(State, 'cast_stage', [H|T]) ->
    run_task(gun_request(H, State), 'cast_stage', T).

%% generate ETS table name
generate_ets_name(Server) ->
    list_to_atom(lists:append([atom_to_list(Server), "_api_tasks"])).

%% get time
get_time() ->
    erlang:convert_time_unit(erlang:system_time(), native, milli_seconds).

% @doc generate report topic
-spec generate_topic(State) -> Result when
    State   :: woodpecker_state(),
    Result  :: binary().

generate_topic(_State = #woodpecker_state{
        report_topic = undefined,
        server = Server
    }) ->
    list_to_binary(lists:concat([atom_to_list(Server), ".output"]));
generate_topic(State) ->
    State#woodpecker_state.report_topic.

% @doc generate nofin report topic
-spec generate_nofin_topic(State) -> Result when
    State   :: woodpecker_state(),
    Result  :: binary().

generate_nofin_topic(_State = #woodpecker_state{
        report_topic = undefined,
        server = Server
    }) ->
    list_to_binary(lists:concat([Server, ".nofin_output"]));
generate_nofin_topic(State) ->
    State#woodpecker_state.report_topic.

% @doc send nofin output (when report_nofin_to undefined we do nothing)
send_nofin_output(_State = #woodpecker_state{report_nofin_to=undefined}, _Frame) ->
    ok;
send_nofin_output(_State = #woodpecker_state{
        report_nofin_to=erlroute, 
        report_nofin_topic=Report_Nofin_topic, 
        server=Server
    }, Frame) ->
    erlroute:pub(?MODULE, Server, ?LINE, Report_Nofin_topic, Frame, 'hybrid', '$erlroute_cmp_woodpecker');
send_nofin_output(_State = #woodpecker_state{report_nofin_to=ReportNofinTo}, Frame) ->
    ReportNofinTo ! Frame.

%% send output
send_output(_State = #woodpecker_state{
        report_to = 'erlroute', 
        report_topic = Report_topic, 
        server = Server
    }, Frame) ->
    erlroute:pub(?MODULE, Server, ?LINE, Report_topic, Frame, 'hybrid', '$erlroute_cmp_woodpecker');
send_output(_State = #woodpecker_state{report_to=ReportTo}, Frame) ->
    ReportTo ! Frame.

%---------------------- public api others functions ----------------------

% @doc get erlroute publish topic from Server state for not-yet finalyzed data 
% (for parse on the fly)
-spec get_nofin_topic(Server) -> Result when
    Server  :: server(),
    Result  :: binary().

get_nofin_topic(Server) ->
    gen_server:call(Server, 'get_nofin_topic').

% @doc get erlroute publish topic from Server state
-spec get_topic(Server) -> Result when
    Server  :: server(),
    Result  :: binary().

get_topic(Server) ->
    gen_server:call(Server, 'get_topic').

% @doc ask woodpecker to GET data from Url with default 'low' priority
-spec get(Server, Url) -> 'ok' when
    Server  :: server(),
    Url     :: url().

get(Server, Url) ->
    get(Server, Url, 'low').

% @doc ask woodpecker to GET data from Url with default 'low' priority
-spec get(Server, Url, Proprity) -> 'ok' when
    Server      :: server(),
    Url         :: url(),
    Proprity    :: priority().

get(Server, Url, Proprity) ->
    gen_server:cast(Server, {create_task,get,Proprity,Url}).
