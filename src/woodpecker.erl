%%% --------------------------------------------------------------------------------
%%% File:    woodpecker.erl
%%% @author  Oleksii Semilietov <spylik@gmail.com>
%%%
%%% @doc
%%% Woodpecker is queue manager for gun (https://github.com/ninenines/gun)
%%%
%%% Woodpecker support 4 types of requests priority:
%%% 
%%% 'urgent' - process request immidiatly. Do not check the queue and count of requests. 
%%% BE AWARE, it can get ban from remote API when going to spam it with too much requests.
%%% 'need-retry' policy: every one second without freezing till max_retry occurs
%%% 
%%% 'high' - process request immidiatly, but with carry of count of requests.
%%%
%%% 'normal' - process request with full carry of the queue
%%%
%%% 'low' - low priority (will fire after 'normal')
%%%
%%% @end
%%% --------------------------------------------------------------------------------

-module(woodpecker).
-define(NOTEST, true).
-ifdef(TEST).
    -compile(export_all).
-endif.

-include("woodpecker.hrl").
%-include("deps/teaser/include/utils.hrl").

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
        get_async/2,
        get_async/3,
        get_async/5,
        post_async/3,
        post_async/4,
        post_async/6
    ]).

% ============================ gen_server part =================================

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
        max_paralell_requests_per_conn = Max_paralell_requests_per_conn,
        requests_allowed_by_api = Requests_allowed_by_api
    }, _Parent}) ->
    Ets = generate_ets_name(Server),
    _ = ets:new(Ets, [ordered_set, protected, {keypos, #wp_api_tasks.ref}, named_table]),

    TRef = erlang:send_after(Heartbeat_freq, self(), heartbeat),

    % return state
    {ok, 
        State#woodpecker_state{
            ets = Ets,
            heartbeat_tref = TRef,
            report_topic = generate_topic(State),
            report_nofin_topic = generate_nofin_topic(State),
            api_requests_quota = Requests_allowed_by_api,
            paralell_requests_quota = Max_paralell_requests_per_conn
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

% @doc callbacks for gen_server handle_cast.
-spec handle_cast(Message, State) -> Result when
    Message :: 'stop' | newtaskmsg(),
    State   :: woodpecker_state(),
    Result  :: {noreply, State} | {stop, normal, State}.

% @doc gen_server callback for create_task message (when we do not allow dupes)
handle_cast({'create_task', Method, Priority, Url, Headers, Body, Tags}, State = #woodpecker_state{ets = Ets, allow_dupes = false}) ->
    MS = [{
            #wp_api_tasks{status = '$1', method = Method, priority = Priority, url = Url, headers = Headers, body = Body, tags = Tags, _ = '_'},
                [
                    {'=/=','$1','got_fin_data'}
                ],
                [true]
            }
        ],
    NewState = case ets:select_count(Ets, MS) > 0 of 
        false -> create_task({Method, Priority, Url, Headers, Body, Tags}, State);
        true -> State
    end,
    {noreply, NewState};

% @doc gen_server callback for create_task message (when we allow dupes)
handle_cast({'create_task', Method, Priority, Url, Headers, Body, Tags}, State = #woodpecker_state{allow_dupes = true}) ->
    {noreply, create_task({Method, Priority, Url, Headers, Body, Tags}, State)};

% @doc handle_cast for stop
handle_cast(stop, State) ->
    {stop, normal, State};

% @doc handle_cast for undexepted things
handle_cast(Msg, State) ->
    error_logger:warning_msg("we are in undefined handle cast with message ~p~n",[Msg]),
    {noreply, State}.
%-----------end of handle_cast-------------


%--------------handle_info-----------------

% @doc callbacks for gen_server handle_info.
-spec handle_info(Message, State) -> Result when
    Message :: 'heartbeat' | gun_response() | gun_data() | gun_push() | gun_error() | down(),
    State   :: term(),
    Result  :: {noreply, State}.

%% heartbeat
handle_info('heartbeat', State = #woodpecker_state{
        heartbeat_tref = Heartbeat_tref, 
        requests_allowed_in_period = Requests_allowed_in_period,
        max_paralell_requests_per_conn = Max_paralell_requests_per_conn,
        ets = Ets,
        heartbeat_freq = Heartbeat_freq,
        flush_completed_req = Flush_completed_req
    }) ->
    _ = erlang:cancel_timer(Heartbeat_tref),
    
    NewThan = get_time() - Requests_allowed_in_period,
    OldQuota = get_quota(State, NewThan),
  
    % going to run task if have quota
    NewState = run_task(State#woodpecker_state{
            api_requests_quota = OldQuota, 
            paralell_requests_quota = Max_paralell_requests_per_conn-active_requests(Ets)
        }, 'order_stage', prepare_ms(State)),

    % going to delete completed requests
    _ = case Flush_completed_req of
        true -> 
            clean_completed(Ets,NewThan);
        false ->
            ok
    end,

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
handle_info({'gun_response',_ConnPid,ReqRef,'nofin',200,Headers}, State) ->
    ets:update_element(
        State#woodpecker_state.ets, ReqRef, [
            {#wp_api_tasks.status, 'got_gun_response'}, 
            {#wp_api_tasks.last_response_date, get_time()},
            {#wp_api_tasks.response_headers, Headers}
        ]),
    {noreply, State};

%% gun_data, nofin state
handle_info({'gun_data',_ConnPid,ReqRef,'nofin',Data}, State = #woodpecker_state{ets = Ets}) ->
    case ets:lookup(Ets, ReqRef) of
        [Task] ->
            LastDate = get_time(),
            Chunked = chunk_data(Task#wp_api_tasks.data, Data),
            ets:update_element(Ets, ReqRef, [
                {#wp_api_tasks.status, 'got_nofin_data'},
                {#wp_api_tasks.last_response_date, LastDate},
                {#wp_api_tasks.data, Chunked}
            ]),
            % chunked output
            send_nofin_output(State, Task#wp_api_tasks{
                    status = 'got_nofin_data',
                    last_response_date = LastDate,
                    data = Chunked
                });

        [] -> error_logger:error_msg("[got_nofin] ReqRef ~p not found in ETS table. Data is ~p", [ReqRef, Data])
    end,
    {noreply, State};

%% gun_data, fin state
handle_info({'gun_data',_ConnPid,ReqRef,'fin',Data}, State = #woodpecker_state{ets = Ets}) ->
    case ets:lookup(Ets, ReqRef) of
        [Task] ->
            LastDate = get_time(),
            Chunked = chunk_data(Task#wp_api_tasks.data, Data),
            ets:update_element(Ets, ReqRef, [
                {#wp_api_tasks.status, 'got_fin_data'},
                {#wp_api_tasks.last_response_date, LastDate},
                {#wp_api_tasks.data, Chunked}
            ]),
            % final output
            send_output(State, Task#wp_api_tasks{
                    status = 'got_fin_data',
                    last_response_date = LastDate,
                    data = Chunked
                });
        [] -> error_logger:error_msg("[got_fin] ReqRef ~p not found in ETS table (maybe already cleaned). Data is ~p", [ReqRef, Data])
    end,
    {noreply, State};

% @doc gun_error with ReqRef
handle_info({'gun_error', ConnPid, ReqRef, Reason}, State) ->
    error_logger:error_msg("got gun_error for ConnPid ~p, ReqRef ~p with reason: ~p",[ConnPid, ReqRef, Reason]),
    ets:update_element(State#woodpecker_state.ets, ReqRef, [
        {#wp_api_tasks.status, 'need_retry'},
        {#wp_api_tasks.response_headers, 'undefined'},
        {#wp_api_tasks.data, 'undefined'}
    ]),
    {noreply, flush_gun(State, ConnPid)};

% @doc gun_error
handle_info({'gun_error', ConnPid, Reason}, State) ->
    error_logger:error_msg("got gun_error for ConnPid ~p with reason: ~p",[ConnPid, Reason]),
    {noreply, flush_gun(State, ConnPid)};

% @doc gun_down
handle_info({'gun_down',ConnPid,_,_,_,_}, State) ->
    {noreply, flush_gun(State, ConnPid)};

% @doc expected down with state 'normal'
handle_info({'DOWN', _MonRef, 'process', ConnPid, 'normal'}, State) ->
    {noreply, flush_gun(State, ConnPid)};

% @doc expected down with state 'shutdown'
handle_info({'DOWN', _MonRef, 'process', ConnPid, 'shutdown'}, State) ->
    {noreply, flush_gun(State, ConnPid)};

% @doc unexepted 'DOWN'
handle_info({'DOWN', MonRef, 'process', ConnPid, Reason}, State) ->
    error_logger:error_msg("got DOWN for ConnPid ~p, MonRef ~p with Reason: ~p",[ConnPid, MonRef, Reason]),
    {noreply, flush_gun(State, ConnPid)};

% @doc handle_info for all other thigs
handle_info(Msg, State) ->
    error_logger:warning_msg("we are in undefined handle info with message ~p~n",[Msg]),
    {noreply, State}.
%-----------end of handle_info-------------

% @doc call back for terminate (we going to cancel timer here)
-spec terminate(Reason, State) -> term() when
    Reason :: 'normal' | 'shutdown' | {'shutdown',term()} | term(),
    State :: term().

terminate(_Reason, State) ->
%    _ = flush_gun(State, 'undefined'),
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

% --------------------------- end of gen_server part ---------------------------

% --------------------------------- other functions ----------------------------

% ----------------------- other private functions ---------------------------

% @doc create task
-spec create_task({Method, Priority, Url, Headers, Body, Tags}, State) -> Result when
    Method      :: method(),
    Priority    :: priority(),
    Url         :: url(),
    Headers     :: headers(),
    Body        :: body(),
    Tags        :: tags(),
    State       :: woodpecker_state(),
    Result      :: woodpecker_state().

create_task({Method, Priority, Url, Headers, Body, Tags}, State = #woodpecker_state{ets = Ets}) ->
    TempRef = erlang:make_ref(),
    ets:insert(Ets, 
        Task = #wp_api_tasks{
            ref = {temp, TempRef},
            status = 'new',
            priority = Priority,
            method = Method,
            url = Url,
            insert_date = get_time(),
            headers = Headers,
            body = Body,
            tags = Tags
        }),
    Quota = get_quota(State),
    case Priority of
        'urgent' ->
            request(connect(State#woodpecker_state{api_requests_quota = Quota}), Task);
        'high' when Quota > 0 ->
            request(connect(State#woodpecker_state{api_requests_quota = Quota}), Task);
        _ ->
            State
    end.

% @doc open new connection to the server or do nothing if connection present
-spec connect(State) -> Result when
    State :: woodpecker_state(),
    Result :: woodpecker_state().

connect(#woodpecker_state{
        connect_to = Connect_to,
        connect_to_port = Connect_to_port,
        current_gun_pid = 'undefined',
        max_total_req_per_conn = Max_total_req_per_conn,
        gun_pids = Gun_pids} = State) ->
    error_logger:info_msg("Going connect to ~p:~p",[Connect_to,Connect_to_port]),
    {ok, Pid} = gun:open(Connect_to, Connect_to_port, #{retry=>0}),
	GunMonRef = monitor(process, Pid),
    case gun:await_up(Pid, 10000, GunMonRef) of
        {ok, Protocol} ->
            error_logger:info_msg("Connected to ~p:~p ~p",[Connect_to,Connect_to_port,Protocol]),
            State#woodpecker_state{
                current_gun_pid = Pid, 
                gun_pids = Gun_pids#{Pid => #gun_pid_prop{gun_mon = GunMonRef, req_per_gun_quota = Max_total_req_per_conn}}
            };
        {'error', Reason} ->
            error_logger:warning_msg("Some error '~p' occur in gun during connection ~p:~p",[Reason, Connect_to, Connect_to_port]),
            demonitor(GunMonRef, [flush]),
            gun:close(Pid),
            State
    end;
connect(State) -> State.

% @doc do request
-spec request(State, Task) -> Result when
    State   :: woodpecker_state(),
    Task    :: wp_api_tasks(),
    Result  :: woodpecker_state().

request(#woodpecker_state{current_gun_pid='undefined'} = State, Task) ->
    ets:update_element(State#woodpecker_state.ets, Task#wp_api_tasks.ref, [
            {#wp_api_tasks.status, 'need_retry'},
            {#wp_api_tasks.response_headers, 'undefined'},
            {#wp_api_tasks.data, 'undefined'}
        ]),
    State;
request(#woodpecker_state{
        current_gun_pid = GunPid,
        gun_pids = GunPids,
        api_requests_quota = Api_requests_quota,
        ets = Ets,
        paralell_requests_quota = Paralell_requests_quota
    } = State, #wp_api_tasks{method = 'get', url = Url, headers = Headers, ref = OldReqRef, retry_count = Retry_count} = Task) ->
    ReqRef = case Headers of 
        'undefined' -> 
            gun:get(GunPid, Url);
        _ -> 
            gun:get(GunPid, Url, Headers)
    end,
    ets:delete(Ets, OldReqRef),
    ets:insert(State#woodpecker_state.ets, 
        Task#wp_api_tasks{
            ref = ReqRef,
            status = 'processing',
            request_date = get_time(),
            retry_count = Retry_count + 1
        }),

    #{GunPid := #gun_pid_prop{req_per_gun_quota = RPGQ} = GunPidProp} = GunPids,
    case RPGQ of 
        'infinity' -> 
            State#woodpecker_state{
                api_requests_quota = Api_requests_quota-1, 
                paralell_requests_quota = Paralell_requests_quota-1
            };
        _ ->
            NewRPGQ = RPGQ-1,
            check_reach_rpgq_quota(
                State#woodpecker_state{
                    api_requests_quota = Api_requests_quota-1, 
                    paralell_requests_quota = Paralell_requests_quota-1,
                    gun_pids = GunPids#{GunPid => GunPidProp#gun_pid_prop{req_per_gun_quota = NewRPGQ}}
                }, 
                GunPid, NewRPGQ
            )
    end.

% @doc check is we need new gun_pid for next requests
-spec check_reach_rpgq_quota(State, GunPid, NewRPGQ) -> Result when
    State   :: woodpecker_state(),
    GunPid  :: gun_pid(),
    NewRPGQ :: non_neg_integer(),
    Result  :: woodpecker_state().

check_reach_rpgq_quota(#woodpecker_state{
        timeout_for_processing_requests = Timeout_for_processing_requests,
        timeout_for_got_gun_response_requests = Timeout_for_got_gun_response_requests,
        timeout_for_nofin_requests = Timeout_for_nofin_requests
    } = State, GunPid, 0) ->
    TotalWaitTime = 10000 + Timeout_for_processing_requests + Timeout_for_got_gun_response_requests + Timeout_for_nofin_requests,
    {'ok',_Tref} = timer:apply_after(TotalWaitTime, gun, close, [GunPid]),
    State#woodpecker_state{
        current_gun_pid = 'undefined'
    };

check_reach_rpgq_quota(State, _GunPid, _RPGQ) ->
    State.

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
    Requests_allowed_by_api-RequestsInPeriod.

% @doc join chunked data
-spec chunk_data (OldData, NewData) -> Result when
    OldData :: 'undefined' | binary(),
    NewData :: binary(),
    Result  :: binary().

chunk_data('undefined', NewData) ->
    NewData;
chunk_data(OldData, NewData) ->
    <<OldData/binary, NewData/binary>>.

% @doc going to clean_up all guns
% when do not specify which GunPid we will clean all gun processes
-spec flush_gun(State, GunPid) -> Result when
    State   :: woodpecker_state(),
    GunPid  :: gun_pid(),
    Result  :: woodpecker_state().

flush_gun(#woodpecker_state{
            gun_pids = Gun_pids
        } = State, 'undefined') ->
    error_logger:error_msg("Going to flush all gun processes"),
    _ = lists:map(fun({Pid, #gun_pid_prop{gun_mon = MonRef}}) ->
            _ = case is_process_alive(Pid) of
                true -> 
                    demonitor(MonRef, [flush]),
                    gun:close(Pid);
                false -> ok
            end,
            gun:close(Pid)
    end, maps:to_list(Gun_pids)),
    State#woodpecker_state{
        gun_pids = maps:new(), 
        current_gun_pid = 'undefined'
    };

% @doc gun clean_up for specified gun_pid
flush_gun(#woodpecker_state{
            gun_pids = Gun_pids,
            current_gun_pid = Current_gun_pid
        } = State, GunPid) ->
    #gun_pid_prop{gun_mon = MonRef} = maps:get(GunPid, Gun_pids, #gun_pid_prop{}),
    Alive = is_process_alive(GunPid),
    _ = case MonRef =/= 'undefined' of
        true when Alive =:= true ->
            demonitor(MonRef, [flush]),
            gun:close(GunPid);
        false when Alive =:= true ->
            gun:close(GunPid);
        _ -> ok
    end,
    case GunPid =:= Current_gun_pid of
        true -> 
            State#woodpecker_state{
                current_gun_pid = 'undefined',
                gun_pids = maps:without([GunPid], Gun_pids)
            };
        false ->
            State#woodpecker_state{
                gun_pids = maps:without([GunPid], Gun_pids)
            }
    end.

% @doc get requests quota
-spec requests_in_period(Ets, DateFrom) -> Result when
    Ets         :: atom(),
    DateFrom    :: pos_integer(),
    Result      :: non_neg_integer().

requests_in_period(Ets, DateFrom) ->
    MS = [{
            #wp_api_tasks{status = '$2', last_response_date = '$1', request_date = '$3', _ = '_'},
                [
                    {'orelse',
                        {'andalso',
                            {'>','$1',{const,DateFrom}},
                            {'=/=','$1','undefined'},
                            {'=/=','$2','need_retry'}
                        },    
                        {'andalso', 
                            {'>','$3',{const,DateFrom}},
                            {'=/=','$3','undefined'},
                            {'=:=','$2','processing'}
                        }
                    }
                ],
                [true]
            }
        ],
    ets:select_count(Ets, MS).

% @doc get active requests
-spec active_requests(Ets) -> Result when
    Ets         :: atom(),
    Result      :: non_neg_integer().

active_requests(Ets) ->
    MS = [{
            #wp_api_tasks{status = '$1', _ = '_'},
                [
                    {'orelse',
                        {'=:=','$1','processing'},
                        {'=:=','$1','got_gun_response'},
                        {'=:=','$1','got_nofin_data'}
                    }
                ],
                [true]
            }
        ],
    ets:select_count(Ets, MS).

% @doc retry staled requests
-spec retry_staled_requests(State) -> Result when
    State   :: woodpecker_state(),
    Result  :: list().

retry_staled_requests(_State = #woodpecker_state{
        timeout_for_nofin_requests = Timeout_for_nofin_requests,
        timeout_for_processing_requests = Timeout_for_processing_requests,
        timeout_for_got_gun_response_requests = Timeout_for_got_gun_response_requests,
        ets = Ets
    }) ->
    Time = get_time(),
    MS = [{
            #wp_api_tasks{status = '$1', last_response_date = '$2', request_date = '$3', _ = '_'},
                [   
                    {'orelse',
                        {'and',
                            {'=:=','$1','got_gun_response'},
                            {'<','$3',{const,Time - Timeout_for_got_gun_response_requests}}
                        },
                        {'and',
                            {'=:=','$1','processing'},
                            {'<','$3',{const,Time - Timeout_for_processing_requests}}
                        },
                        {'and',
                            {'=:=','$1','got_nofin_data'},
                            {'<','$2',{const,Time - Timeout_for_nofin_requests}}
                        }
                    }
                ], ['$_']
            }],
    lists:map(
        fun(#wp_api_tasks{ref = ReqRef}) ->
            ets:update_element(
                Ets, ReqRef, [
                    {#wp_api_tasks.status, 'need_retry'},
                    {#wp_api_tasks.response_headers, 'undefined'},
                    {#wp_api_tasks.data, 'undefined'}
                ])
        end,
        ets:select(Ets, MS)).

% @doc clean completed request (match spec)
-spec clean_completed(Ets, OldThan) -> Result when
    Ets         :: atom(),
    OldThan     :: pos_integer(),
    Result      :: list().

clean_completed(Ets,OldThan) ->
    MS = [{
            #wp_api_tasks{ref = '$1', status = 'got_fin_data', request_date = '$3', _ = '_'},
                [   
                    {'<', '$3', OldThan}
                ], ['$1']
            }],
    lists:map(
        fun(Key) ->
            ets:delete(Ets, Key)
        end,
        ets:select(Ets, MS)).

% @doc run task from ets-queue
-spec prepare_ms(State) -> Result when
    State   :: woodpecker_state(),
    Result  :: [[ets:match_spec()]].

prepare_ms(#woodpecker_state{
        freeze_for_incomplete_requests = Freeze_for_incomplete_requests,
        max_freeze_for_incomplete_requests = Max_freeze_for_incomplete_requests
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
                        {'<','$3',{'-',{const,Time},{'*','$1', Freeze_for_incomplete_requests}}},
                        {'<','$3',{'-',{const,Time},Max_freeze_for_incomplete_requests}}
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
    Tasks   :: [[ets:match_spec()]],
    Result  :: woodpecker_state().

% when head is empty going to check tail
run_task(State, 'order_stage', [[]|T2]) ->
    run_task(State, 'order_stage', T2);

% when tasks list is empty, just return #woodpecker_state.api_requests_quota.
run_task(State = #woodpecker_state{
       max_paralell_requests_per_conn = Max_paralell_requests_per_conn,
       ets = Ets
    }, _Stage, []) ->
    State#woodpecker_state{paralell_requests_quota = Max_paralell_requests_per_conn - active_requests(Ets)};

% when we do not have free slots
run_task(State = #woodpecker_state{
        api_requests_quota = Api_requests_quota,
        paralell_requests_quota = Paralell_requests_quota,
        max_paralell_requests_per_conn = Max_paralell_requests_per_conn
    }, _Stage, _Tasks) when Api_requests_quota =< 0 orelse Paralell_requests_quota =< 0 -> 
    State#woodpecker_state{paralell_requests_quota = Max_paralell_requests_per_conn};

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
    run_task(request(connect(State), H), 'cast_stage', T).

% @doc generate ETS table name
-spec generate_ets_name(Server) -> Result when
    Server  :: server(),
    Result  :: atom().

generate_ets_name(Server) ->
    list_to_atom(lists:append([atom_to_list(Server), "_api_tasks"])).

% @doc get time
-spec get_time() -> Result when 
    Result  :: pos_integer().
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

%------------------------------- send output -----------------------------
% @doc send nofin output (when report_nofin_to undefined we do nothing)
-spec send_nofin_output(State, Frame) -> no_return() when
    State   :: woodpecker_state(),
    Frame   :: wp_api_tasks().

send_nofin_output(_State = #woodpecker_state{report_nofin_to='undefined'}, _Frame) ->
    ok;
send_nofin_output(_State = #woodpecker_state{
        report_nofin_to=erlroute, 
        report_nofin_topic=Report_Nofin_topic, 
        server=Server
    }, Frame) ->
    erlroute:pub(?MODULE, Server, ?LINE, Report_Nofin_topic, Frame, 'hybrid', '$erlroute_cmp_woodpecker');
send_nofin_output(_State = #woodpecker_state{report_nofin_to=ReportNofinTo}, Frame) ->
    ReportNofinTo ! Frame.

% @doc send output
-spec send_output(State, Frame) -> no_return() when
    State   :: woodpecker_state(),
    Frame   :: wp_api_tasks().

send_output(_State = #woodpecker_state{report_to='undefined'}, _Frame) ->
    ok;
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

% -------------------------------- POST API ------------------------------

% @doc ask woodpecker to POST data async to the URL with default 'normal' priority, empty headers
-spec post_async(Server, Url, Body) -> 'ok' when
    Server  :: server(),
    Url     :: url(),
    Body    :: body().

post_async(Server, Url, Body) ->
    post_async(Server, Url, 'normal', 'undefined', Body, 'undefined').

% @doc ask woodpecker to POST data async to the Url with empty headers
-spec post_async(Server, Url, Body, Priority) -> 'ok' when
    Server      :: server(),
    Url         :: url(),
    Body        :: body(),
    Priority    :: priority().

post_async(Server, Url, Body, Priority) -> 
    post_async(Server, Url, Priority, 'undefined', Body, 'undefined').


% @doc full-featured POST API.
% ask woodpecker to POST async data to the Url
-spec post_async(Server, Url, Priority, Headers, Body, Tags) -> 'ok' when
    Server      :: server(),
    Url         :: url(),
    Headers     :: headers(),
    Priority    :: priority(),
    Body        :: body(),
    Tags        :: tags().

post_async(Server, Url, Priority, Headers, Body, Tags) ->
    gen_server:cast(Server, {create_task, 'post', Priority, Url, Headers, Body, Tags}).


% -------------------------------- GET API -------------------------------

% @doc ask woodpecker to async GET data from Url with default 'normal' priority, empty headers
-spec get_async(Server, Url) -> 'ok' when
    Server  :: server(),
    Url     :: url().

get_async(Server, Url) ->
    get_async(Server, Url, 'normal', 'undefined', 'undefined').

% @doc ask woodpecker to async GET data from Url with empty headers
-spec get_async(Server, Url, Priority) -> 'ok' when
    Server      :: server(),
    Url         :: url(),
    Priority    :: priority().

get_async(Server, Url, Priority) -> 
    get_async(Server, Url, Priority, 'undefined', 'undefined').

% @doc full-featured GET API.
% ask woodpecker to async GET data from Url (body must be always empty for GET requsts)
-spec get_async(Server, Url, Priority, Headers, Tags) -> 'ok' when
    Server      :: server(),
    Url         :: url(),
    Headers     :: headers(),
    Priority    :: priority(),
    Tags        :: tags().

get_async(Server, Url, Priority, Headers, Tags) ->
    gen_server:cast(Server, {create_task, 'get', Priority, Url, Headers, 'undefined', Tags}).
