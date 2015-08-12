%% --------------------------------------------------------------------------------
%% File:    woodpecker.erl
%% @author  Oleksii Semilietov <spylik@gmail.com>
%%
%% @doc
%% Woodpecker is  
%%
%% We support 4 types of requests priority:
%% 
%% urgent - process request immidiatly without carry of queue and count of requests. 
%% be aware, we can got ban when going to use it.
%% need-retry every one second without degradation till max_retry occurs
%% 
%% high - process request immidiatly, but with carry of count of requests.
%%
%% normal - process request with carry of queue
%%
%% low - low priority (usually used for get_order_book / etc public api)

%%
%% @end
%% --------------------------------------------------------------------------------

-module(woodpecker).

-include("woodpecker.hrl").
%-include_lib("stdlib/include/ms_transform.hrl").

% gen server is here
-behaviour(gen_server).

% gen_server api
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

% public api
-export([
        start_link/1,
        get_bitstamp_orderbook/0,
        get_bitstamp_transactions/0,
        get_bitstamp_rate/0
    ]).

% time debugging
-ifndef(TIMEON).
-define(TIMEON, maria_libs:timeon(?LINE,?MODULE,self())).
-define(TIMEOFF, maria_libs:timeoff(?LINE,?MODULE,self())).
-endif.

% record for keep state
-record(state, {
        server,                             % servername
        connect_to,                         % connect_to servername
        requests_allowed_by_api,            % count of requests allowd by api per period
        requests_allowed_in_period,         % period
        ets,                                % generated ets_name
        gun_pid,                            % gun connection Pid
        gun_ref,                            % gun monitor refference
        api_requests_quota,                 % current api requests quota
        timeout_for_processing_requests,    % timeout for requests with status "processing"
        timeout_for_nofin_requests,         % timeout for requests with status "nofin"
        degradation_for_incomplete_requests,% Degradation for incomplete requests (retry_count * to this variable)
        heartbeat_freq,                     % heartbeat frequency (in milliseconds)
        heartbeat_tref                      % last heartbeat time refference
    }).

% defaults (we can change it via start_link/1 arguments
-define(REQUESTS_ALLOWED_BY_API, 600).          % 600 requests per
-define(REQUESTS_ALLOWED_IN_PERIOD, 600000).       % 10 minutes in seconds
-define(TIMEOUT_FOR_PROCESSING_REQUESTS, 60000).   % 1 munutes in seconds 
-define(TIMEOUT_FOR_NOFIN_REQUESTS, 180000).       % 3 munutes in seconds
-define(DEGRADATION_FOR_INCOMPLETE_REQUEST, 1000). % 1 second
-define(HEARTBEAT_FREQ, 1000).                  % every one second (in millisecond)

% --------------------------------- gen_server part --------------------------------------

% start api
start_link(Prop) ->
    gen_server:start_link(
        {local, proplists:get_value(server,Prop)}, 
        ?MODULE, Prop, []).

init(Prop) ->
    Server = proplists:get_value(server,Prop),
    Requests_allowed_by_api = ?REQUESTS_ALLOWED_BY_API,
    Requests_allowed_in_period = ?REQUESTS_ALLOWED_IN_PERIOD,
    Timeout_for_processing_requests = ?TIMEOUT_FOR_PROCESSING_REQUESTS,
    Timeout_for_nofin_requests = ?TIMEOUT_FOR_NOFIN_REQUESTS,
    Degradation_for_incomplete_requests = ?DEGRADATION_FOR_INCOMPLETE_REQUEST,
    Heartbeat_freq = ?HEARTBEAT_FREQ,

    Ets = generate_ets_name(Server),
    ets:new(Ets, [ordered_set, protected, {keypos, #api_tasks.ref}, named_table]),

    TRef = erlang:send_after(Heartbeat_freq, self(), heartbeat),

    % return state
    {ok, 
        #state{
            server = Server, 
            ets = Ets,
            requests_allowed_by_api = Requests_allowed_by_api,
            api_requests_quota = Requests_allowed_by_api,
            requests_allowed_in_period = Requests_allowed_in_period,
            timeout_for_processing_requests = Timeout_for_processing_requests,
            timeout_for_nofin_requests = Timeout_for_nofin_requests,
            degradation_for_incomplete_requests = Degradation_for_incomplete_requests,
            heartbeat_freq = Heartbeat_freq,
            heartbeat_tref = TRef
        }}.

%--------------handle_call-----------------

% handle_call for all other thigs
handle_call(Msg, _From, State) ->
    lager:warning("we are in undefined handle_call with message ~p~n",[Msg]),
    {reply, ok, State}.
%-----------end of handle_call-------------

%--------------handle_cast-----------------

% create task
handle_cast({create_task, Method, Priority, Url}, State) ->
    TempRef = erlang:make_ref(),
    ets:insert(State#state.ets, 
        Task = #api_tasks{
            ref = TempRef,
            status = new,
            priority = Priority,
            method = Method,
            url = Url,
            insert_date = erlang:convert_time_unit(erlang:system_time(), native, milli_seconds),
            max_retry = 9999,               % temp
            retry_count = 0                 % temp
        }),
    case Priority of
        urgent ->
            gen_server:cast(self(), [gun_request, Task]);
        high when State#state.api_requests_quota > 0 ->
            gen_server:cast(self(), [gun_request, Task]);
        _ ->
            ok
    end,
    {noreply, State};

% gun_request
handle_cast([gun_request, Task], State) ->
    update_processing_request(State, Task, Task#api_tasks.ref),
    NewState = connect(State, State#state.gun_pid),
    request(NewState, Task, NewState#state.gun_pid),
    {noreply, NewState};


% handle_cast for all other thigs
handle_cast(Msg, State) ->
    lager:warning("we are in undefined handle cast with message ~p~n",[Msg]),
    {noreply, State}.
%-----------end of handle_cast-------------


%--------------handle_info-----------------

% every-second heartbeat
%
% todo: due a lot of heartbeat routine maybe we need to move this routine to separate process
% to prevent blocking new data arrivals
%
handle_info(heartbeat, State) ->
%    lager:notice("got heartbeat"),
    _ = erlang:cancel_timer(State#state.heartbeat_tref),
    
    NewThan = erlang:convert_time_unit(erlang:system_time(), native, milli_seconds) - State#state.requests_allowed_in_period,
    
    % we going to run task
    Quota = run_task(
        State#state.ets,
        State#state.requests_allowed_by_api-requests_in_period(State#state.ets,NewThan) 
    ),

    % going to delete completed requests
    clean_completed(State#state.ets,NewThan),

    % going to change state to need_retry for staled requests (processing, got_nofin) 
    retry_staled_requests(State),

    % new heartbeat time refference
    TRef = erlang:send_after(State#state.heartbeat_freq, self(), heartbeat),

    % return state    
    {noreply, 
        State#state{
            api_requests_quota=Quota, 
            heartbeat_tref=TRef
        }
    };

% gun_response, nofin state
handle_info({gun_response,_ConnPid,ReqRef,nofin,200,_Headers}, State) ->
    ets:update_element(State#state.ets, ReqRef, [{#api_tasks.status, got_gun_response}, {#api_tasks.last_response_date, erlang:convert_time_unit(erlang:system_time(), native, milli_seconds)}]),
    {noreply, State};

% gun_data, nofin state
handle_info({gun_data,_ConnPid,ReqRef,nofin,Data}, State) ->
    [Task] = ets:lookup(State#state.ets, ReqRef),
    case Task#api_tasks.chunked_data of
        undefined -> 
            Chunked = Data;
        _ -> 
            OldData = Task#api_tasks.chunked_data,
            Chunked = <<OldData/binary, Data/binary>>
    end,
    ets:insert(State#state.ets, 
        Task#api_tasks{
            status = got_nofin_data,
            last_response_date = erlang:convert_time_unit(erlang:system_time(), native, milli_seconds),
            chunked_data = Chunked
        }),
    lager:notice("got data with nofin state for ReqRef ~p",[ReqRef]),
    {noreply, State};

% gun_data, fin state
handle_info({gun_data,_ConnPid,ReqRef,fin,Data}, State) ->
    [Task] = ets:lookup(State#state.ets, ReqRef),
    case Task#api_tasks.chunked_data of
        undefined -> 
            Chunked = Data;
        _ ->
            OldData = Task#api_tasks.chunked_data,
            Chunked = <<OldData/binary, Data/binary>>
    end,
    ets:insert(State#state.ets, 
        Task#api_tasks{
            status = got_fin_data,
            last_response_date = erlang:convert_time_unit(erlang:system_time(), native, milli_seconds),
            chunked_data = Chunked
        }),
    msg_router:pub(?MODULE, State#state.server, <<"gun_data">>, [{data, Chunked}, {send_recipe, self(), ReqRef}]),
    lager:notice("got data with fin state for ReqRef ~p",[ReqRef]),
    {noreply, State};

% recipe
handle_info({recipe, ReqRef, NewStatus}, State) ->
    ets:update_element(State#state.ets, ReqRef, {#api_tasks.status, NewStatus}),
    {noreply, State};

% gun_error
handle_info({gun_error,ConnPid,ReqRef,{Reason,Descr}}, State) ->
    lager:error("got gun_error for ReqRef ~p with reason: ~p, ~p",[ReqRef, Reason, Descr]),
    ets:update_element(State#state.ets, ReqRef, {#api_tasks.status, need_retry}),
    NewState = flush_gun(State, ConnPid),
    {noreply, NewState};

% gun_down
handle_info({gun_down,ConnPid,_,_,_,_}, State) ->
    NewState = flush_gun(State, ConnPid),
    {noreply, NewState};

% unexepted normal 'DOWN'
handle_info({'DOWN', _ReqRef, _, ConnPid, _}, State) ->
    NewState = flush_gun(State, ConnPid),
    {noreply, NewState};

% handle_info for all other thigs
handle_info(Msg, State) ->
    lager:warning("we are in undefined handle info with message ~p~n",[Msg]),
    {noreply, State}.
%-----------end of handle_info-------------


terminate(_Reason, State) ->
    flush_gun(State, undefined).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

% ===================================== end of gen_server part ==================================
% ----------------------------------- other functions --------------------------------

% ----------------------- other private functions ---------------------------

% We going to do more in one openned connection to reduce new connection overhead.
% But if connection closed, we going to open new one when we have new tasks
connect(State, undefined) ->
    lager:alert("need new connection"),
    {ok, Pid} = gun:open("www.bitstamp.net", 443, #{retry=>0}),
    case gun:await_up(Pid) of
        {ok, http} ->
            GunRef = monitor(process, Pid),
            State#state{gun_pid=Pid, gun_ref=GunRef};
        {error, timeout} ->
            flush_gun(State, Pid)
    end;
connect(State, _) ->
    lager:notice("we have connection"),
    State.

% request
request(State, Task, undefined) ->
    lager:notice("going to update to need_retry"),
    ets:update_element(State#state.ets, Task#api_tasks.ref, [{#api_tasks.status, need_retry}]),
    undefined;
request(State, Task, GunPid) when Task#api_tasks.method =:= get ->
    ReqRef = gun:get(GunPid, Task#api_tasks.url),
    update_processing_request(State, Task, ReqRef).

% update request in ets
update_processing_request(_, _, undefined) ->
    ok;
update_processing_request(State, Task, ReqRef) ->
    case Task#api_tasks.ref =/= ReqRef of
        true ->
            ets:delete(State#state.ets, Task#api_tasks.ref);
        false ->
            ok
    end,
    ets:insert(State#state.ets, 
        Task#api_tasks{
            ref = ReqRef,
            status = processing,
            request_date = erlang:convert_time_unit(erlang:system_time(), native, milli_seconds),
            retry_count = Task#api_tasks.retry_count + 1
        }).

% gun clean_up
flush_gun(State, ConnRef) ->
    case ConnRef =/= undefined andalso State#state.gun_pid =:= ConnRef of
        true -> 
            demonitor(State#state.gun_ref),
            gun:close(State#state.gun_pid),
            gun:flush(State#state.gun_pid);
        false -> 
            gun:close(ConnRef),
            gun:flush(ConnRef),
            gun:close(State#state.gun_pid),
            gun:flush(State#state.gun_pid)
    end,
    State#state{gun_pid=undefined, gun_ref=undefined}.

% get requests quota
requests_in_period(Ets, DateFrom) ->
    MS = [{
            {api_tasks,'_','$2','_','_','_','_','_','_','$1','_','_','_','_'},
                [
                    {'=/=','$2',need_retry},
                    {'=/=','$1',undefined},
                    {'>','$1',{const,DateFrom}}
                ],
                [true]
            }
        ],
    ets:select_count(Ets, MS).

% retry staled requests
retry_staled_requests(State) ->
    UnixTime = erlang:convert_time_unit(erlang:system_time(), native, milli_seconds),
    LessThanNofin = UnixTime - State#state.timeout_for_nofin_requests,
    LessThanProcessing = UnixTime - State#state.timeout_for_processing_requests,
    MS = [{
            {api_tasks,'_','$1','_','_','_','_','_','_','_','$2','_','_','_'},
                [
                    {'orelse',
                        [
                            {'=:=','$1',processing},
                            {'andalso',
                                {'=/=','$2',undefined},
                                {'<','$2',{const,LessThanProcessing}}
                            }
                        ],

                        [
                            {'=:=','$1',got_nofin_data},
                            {'andalso',
                                {'=/=','$2',undefined},
                                {'<','$2',{const,LessThanNofin}}
                            }
                        ]
                    }
                ],
                ['$_']
            }
        ],
    lists:map(
        fun(Task) ->
            lager:notice("Task is ~p",[Task]),
            ets:insert(State#state.ets, 
                Task#api_tasks{
                    status = need_retry,
                    chunked_data = undefined
            })
        end,
        ets:select(State#state.ets, MS)).

% going to clean completed requests
clean_completed(Ets,OldThan) ->
    ets:safe_fixtable(Ets,true),
    clean_completed(Ets, OldThan, ets:first(Ets)),
    ets:safe_fixtable(Ets,false).

clean_completed(_Ets, _OldThan, '$end_of_table') ->
    true;

clean_completed(Ets, OldThan, LastKey) ->
    case ets:lookup(Ets, LastKey) of
        [Data = #api_tasks{}] when Data#api_tasks.request_date =/= undefined, Data#api_tasks.request_date < OldThan, Data#api_tasks.status=:= complete ->
            ets:delete(Ets, LastKey),
            clean_completed(Ets, OldThan,ets:next(Ets, LastKey));
        [Data = #api_tasks{}] when Data#api_tasks.request_date =/= undefined, Data#api_tasks.request_date < OldThan ->
            clean_completed(Ets, OldThan,ets:next(Ets, LastKey));
        _ -> 
            ok
    end.

% run task from ets-queue
run_task(Ets, Quota) ->

%!!!!!!!!!!!!!!!!!! need implement    degradation_for_incomplete_requests
    
    %   F = ets:fun2ms(fun(MS = #api_tasks{status=need_retry, priority=high, retry_count=RetryCount, max_retry=MaxRetry, request_date=RequestData}) when RetryCount < MaxRetry, RequestData < UnixTime-RetryCount orelse RequestData < UnixTime-3600 -> MS end),
%   io:format("F1 is ~p",[F]),
    UnixTime = erlang:convert_time_unit(erlang:system_time(), native, milli_seconds),
    Order = [
        % priority = urgent, status=need_retry, retry_count < max_retry
        [{
            {api_tasks,'_',need_retry,urgent,'_','_','_','_','_','_','_','_','$2','$1'},
            [
                {'<','$1','$2'}
            ], 
            ['$_']
        }],


        % priority = high, status=need_retry, retry_count < 10, retry_count < max_retry 
        [{
            {api_tasks,'_',need_retry,high,'_','_','_','_','_','_','_','_','$2','$1'},
            [
                {'<','$1',10},
                {'<','$1','$2'}
            ], 
            ['$_']
        }],

        % priority = high, status=need_retry, retry_count > 10 andalso retry_count < max_retry, request_date < UnixTime-retry_count orelse request_date < UnixTime-3600
        [{
            {api_tasks,'_',need_retry,high,'_','_','_','_','_','$3','_','_','$2','$1'},
            [
                {'<','$1','$2'},
                {'orelse',
                    {'<','$3',{'-',{const,UnixTime},'$1'}},
                    {'<','$3',{'-',{const,UnixTime},3600000}}
                }
            ],
            ['$_']
        }],

        % priority = high, status=new
        [{{api_tasks,'_',new,high,'_','_','_','_','_','_','_','_','_','_'},[],['$_']}],


        % priority = normal, status=need_retry, retry_count < 10 andalso retry_count < max_retry
        [{
            {api_tasks,'_',need_retry,normal,'_','_','_','_','_','_','_','_','$2','$1'},
            [
                {'<','$1',10},
                {'<','$1','$2'}
            ], 
            ['$_']
        }],

        % priority = normal, status=need_retry, retry_count > 10 andalso retry_count < max_retry, request_date < UnixTime-retry_count orelse request_date < UnixTime-3600
        [{
            {api_tasks,'_',need_retry,normal,'_','_','_','_','_','$3','_','_','$2','$1'},
            [
                {'<','$1','$2'},
                {'orelse',
                    {'<','$3',{'-',{const,UnixTime},'$1'}},
                    {'<','$3',{'-',{const,UnixTime},3600000}}
                }
            ],
            ['$_']
        }],

        % priority = normal, status=new
        [{{api_tasks,'_',new,normal,'_','_','_','_','_','_','_','_','_','_'},[],['$_']}],


        % priority = low, status=need_retry, retry_count < 10 andalso retry_count < max_retry
        [{
            {api_tasks,'_',need_retry,low,'_','_','_','_','_','_','_','_','$2','$1'},
            [
                {'<','$1',10},
                {'<','$1','$2'}
            ], 
            ['$_']
        }],

        % priority = low, status=need_retry, retry_count > 10 andalso retry_count < max_retry, request_date < UnixTime-retry_count orelse request_date < UnixTime-3600
        [{
            {api_tasks,'_',need_retry,low,'_','_','_','_','_','$3','_','_','$2','$1'},
            [
                {'<','$1','$2'},
                {'orelse',
                    {'<','$3',{'-',{const,UnixTime},'$1'}},
                    {'<','$3',{'-',{const,UnixTime},3600000}}
                }
            ],
            ['$_']
        }],

        % priority = low, status=new
        [{{api_tasks,'_',new,low,'_','_','_','_','_','_','_','_','_','_'},[],['$_']}]
    ],
    run_task(Ets, Quota, order_stage, Order).

run_task(Ets, Quota, order_stage, [H|T]) ->
    case Quota > 0 of
        true ->
%            lager:notice("Spec is ~p",[H]),
            QuotaNew = run_task(Ets, Quota, cast_stage, ets:select(Ets, H)),
            run_task(Ets, QuotaNew, order_stage, T);
        false ->
            0
    end;

run_task(Ets, Quota, cast_stage, [H|T]) ->
    case Quota > 0 of
        true ->
            gen_server:cast(self(), [gun_request, H]),
            run_task(Ets, Quota - 1, cast_stage, T);
        false ->
            0
    end;
run_task(_Ets, Quota, _, []) ->
    Quota.

% generate ETS table name
generate_ets_name(Server) ->
    list_to_atom(lists:append([atom_to_list(Server), "_api_tasks"])).

%---------------------- public api others functions ----------------------

get_bitstamp_rate() ->
    gen_server:cast(self(), {create_task,get,low,"/api/eur_usd/"}).
get_bitstamp_orderbook() ->
    gen_server:cast(self(), {create_task,get,low,"/api/order_book/"}).
get_bitstamp_transactions() ->
    gen_server:cast(self(), {create_task,get,low,"/api/transactions/?time=hour"}).
