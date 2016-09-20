% ATTENTION: do not run this tests on production nodes
% we using mlibs:random_atom for creating random names for servers, 
% but atoms will not garbage collected

-module(woodpecker_tests).

-include_lib("eunit/include/eunit.hrl").
-include("woodpecker.hrl").
-compile(export_all).

-export([init/2,start_cowboy/1]).

-define(TESTMODULE, woodpecker).
-define(TESTSERVER, test_wp_server).
-define(TESTHOST, "127.0.0.1").
-define(TESTPORT, 8082).

% --------------------------------- fixtures ----------------------------------

% tests for cover standart otp behaviour
otp_test_() ->
    {setup,
        fun() -> error_logger:tty(false) end,
        {inorder,
            [
                {<<"gen_server able to start via ?TESTSERVER:start_link(#woodpecker_state{})">>,
                    fun() ->
                        ?TESTMODULE:start_link(#woodpecker_state{server = ?TESTSERVER, connect_to = ?TESTHOST, connect_to_port = ?TESTPORT}),
                        ?assertEqual(
                            true,
                            is_pid(whereis(?TESTSERVER))
                        )
                end},
                {<<"gen_server able to stop via ?TESTSERVER:stop(?TESTSERVER)">>,
                    fun() ->
                        ?assertEqual(ok, ?TESTMODULE:stop('sync',?TESTSERVER)),
                        ?assertEqual(
                            false,
                            is_pid(whereis(?TESTSERVER))
                        )
                end},
                {<<"gen_server able to start and stop via ?TESTSERVER:start_link() / ?TESTSERVER:stop(sync)">>,
                    fun() ->
                        ?TESTMODULE:start_link(#woodpecker_state{server = ?TESTSERVER, connect_to = ?TESTHOST, connect_to_port = ?TESTPORT}),
                        ?assertEqual(ok, ?TESTMODULE:stop('sync',?TESTSERVER)),
                        ?assertEqual(
                            false,
                            is_pid(whereis(?TESTSERVER))
                        )
                end},
                {<<"gen_server able to start and stop via ?TESTSERVER:start_link() / ?TESTSERVER:stop()">>,
                    fun() ->
                        ?TESTMODULE:start_link(#woodpecker_state{server = ?TESTSERVER, connect_to = ?TESTHOST, connect_to_port = ?TESTPORT}),
                        ?assertEqual(ok, ?TESTMODULE:stop(?TESTSERVER)),
                        ?assertEqual(
                            false,
                            is_pid(whereis(?TESTSERVER))
                        )
                end},
                {<<"gen_server able to start and stop via ?TESTSERVER:start_link() ?TESTSERVER:stop(async)">>,
                    fun() ->
                        ?TESTMODULE:start_link(#woodpecker_state{server = ?TESTSERVER, connect_to = ?TESTHOST, connect_to_port = ?TESTPORT}),
                        ?TESTMODULE:stop('async',?TESTSERVER),
                        timer:sleep(1), % for async cast
                        ?assertEqual(
                            false,
                            is_pid(whereis(?TESTSERVER))
                        )
                end}

            ]
        }
    }.

tests_with_gun_and_cowboy_test_() ->
    {setup,
        % setup
        fun() ->
            ToStop = tutils:setup_start([{'apps',[ranch,cowboy,crypto,asn1,public_key,ssl,cowlib,gun]}]),
            CowboyRanchRef = start_cowboy(10),
            [{'tostop', ToStop}, {'ranch_ref', CowboyRanchRef}]
        end,
        % cleanup
        fun([{'tostop', ToStop},{'ranch_ref', CowboyRanchRef}]) ->
            cowboy:stop_listener(CowboyRanchRef),
            tutils:cleanup_stop(ToStop)
        end, 
        {inparallel,
            [
                {<<"able to send single GET request with urgent priority in single connection">>,
                    fun() ->
                        simple_test(get, 'urgent', 1)
                end},
                {<<"able to send 2 GET requests with urgent priority in single connection">>,
                    fun() ->
                        simple_test(get, 'urgent', 2)
                end},
                {<<"able to send single GET request with high priority in single connection">>,
                    fun() ->
                        simple_test(get, 'high', 1)
                end},
                {<<"able to send 2 GET requests with high priority in single connection">>,
                    fun() ->
                        simple_test(get, 'high', 2)
                end},
                {<<"able to send single GET request with normal priority in single connection">>,
                    fun() ->
                        simple_test(get, 'normal',1)
                end},
                {<<"able to send 2 GET requests with normal priority in single connection">>,
                    fun() ->
                        simple_test(get, 'normal',2)
                end},
                {<<"able to send single GET request with low priority in single connection">>,
                    fun() ->
                        simple_test(get, 'low',1)
                end},
                {<<"able to send 2 GET requests with low priority in single connection">>,
                    fun() ->
                        simple_test(get, 'low', 2)
                end},
                {<<"Must ignore max_paralell_requests for urgent priority requests.">>,
                    fun() ->
                        QueryParam = erlang:unique_integer([monotonic,positive]),
                        MQParam = integer_to_binary(QueryParam),
                        WaitAt = tutils:spawn_wait_loop_max(25,100),
                        Server = mlibs:random_atom(),
                        Max_paralell_requests = 2,
                        ETSTable = woodpecker:generate_ets_name(Server),
                        ?TESTMODULE:start_link(#woodpecker_state{server = Server, connect_to = ?TESTHOST, connect_to_port = ?TESTPORT, report_to = WaitAt, heartbeat_freq = 10000, max_paralell_requests = Max_paralell_requests}),
                        [?TESTMODULE:get(Server,lists:append(["/?query=",integer_to_list(QueryParam)]),'urgent') || _A <- lists:seq(1,15)],
                        timer:sleep(20),
                        Tasks = ets:tab2list(ETSTable),
                        ?assertEqual(15, length(Tasks)),
                        Tst = ets:select(ETSTable,[{{wp_api_tasks,'_','_',urgent,'_','_','_','_','_','_','_','_','$2','$1','_'},[{'<','$1',10},{'<','$1','$2'}],['$_']}]),
                        ?assertEqual(15, length(Tst)),
                        Server ! 'heartbeat',
                        [Acc] = tutils:recieve_loop([], 220, WaitAt),
                        ?assertEqual(15, length(Acc)),
                        FF = hd(Acc),
                        FirstPid = maps:get(pid, binary_to_term(FF#woodpecker_frame.data)),
                        lists:map(fun(#woodpecker_frame{data = DataFrame}) ->
                            Data = binary_to_term(DataFrame),
                            ?assertEqual(#{'query' => MQParam}, cowboy_req:match_qs([{'query', [], 'undefined'}], Data)),
                            ?assertEqual(FirstPid, maps:get(pid, Data))
                        end, Acc),
                        ?TESTMODULE:stop(Server)
                end},
                {<<"Must ignore max_paralell_requests for high priority requests.">>,
                    fun() ->
                        QueryParam = erlang:unique_integer([monotonic,positive]),
                        MQParam = integer_to_binary(QueryParam),
                        WaitAt = tutils:spawn_wait_loop_max(25,100),
                        Server = mlibs:random_atom(),
                        Max_paralell_requests = 2,
                        ETSTable = woodpecker:generate_ets_name(Server),
                        ?TESTMODULE:start_link(#woodpecker_state{server = Server, connect_to = ?TESTHOST, connect_to_port = ?TESTPORT, report_to = WaitAt, heartbeat_freq = 10000, max_paralell_requests = Max_paralell_requests}),
                        [?TESTMODULE:get(Server,lists:append(["/?query=",integer_to_list(QueryParam)]),'high') || _A <- lists:seq(1,15)],
                        timer:sleep(20),
                        Tasks = ets:tab2list(ETSTable),
                        ?assertEqual(15, length(Tasks)),
                        Tst = ets:select(ETSTable,[{{wp_api_tasks,'_','_',high,'_','_','_','_','_','_','_','_','$2','$1','_'},[{'<','$1',10},{'<','$1','$2'}],['$_']}]),
                        ?assertEqual(15, length(Tst)),
                        Server ! 'heartbeat',
                        [Acc] = tutils:recieve_loop([], 220, WaitAt),
                        ?assertEqual(15, length(Acc)),
                        FF = hd(Acc),
                        FirstPid = maps:get(pid, binary_to_term(FF#woodpecker_frame.data)),
                        lists:map(fun(#woodpecker_frame{data = DataFrame}) ->
                            Data = binary_to_term(DataFrame),
                            ?assertEqual(#{'query' => MQParam}, cowboy_req:match_qs([{'query', [], 'undefined'}], Data)),
                            ?assertEqual(FirstPid, maps:get(pid, Data))
                        end, Acc),
                        ?TESTMODULE:stop(Server)
                end},
                {<<"Must respect max_paralell_requests for normal priority requests">>,
                    fun() ->
                        QueryParam = erlang:unique_integer([monotonic,positive]),
                        MQParam = integer_to_binary(QueryParam),
                        WaitAt = tutils:spawn_wait_loop_max(10,100),
                        Server = mlibs:random_atom(),
                        Max_paralell_requests = 2,
                        ETSTable = woodpecker:generate_ets_name(Server),
                        ?TESTMODULE:start_link(#woodpecker_state{server = Server, connect_to = ?TESTHOST, connect_to_port = ?TESTPORT, report_to = WaitAt, heartbeat_freq = 10000, max_paralell_requests = Max_paralell_requests}),
                        [?TESTMODULE:get(Server,lists:append(["/?query=",integer_to_list(QueryParam)]),'normal') || _A <- lists:seq(1,20)],
                        timer:sleep(20),
                        Tasks = ets:tab2list(ETSTable),
                        ?assertEqual(20, length(Tasks)),
                        Tst = ets:select(ETSTable,[{{wp_api_tasks,'_',new,normal,'_','_','_','_','_','_','_','_','$2','$1','_'},[{'<','$1',10},{'<','$1','$2'}],['$_']}]),
                        ?assertEqual(20, length(Tst)),
                        Server ! 'heartbeat',
                        [Acc] = tutils:recieve_loop([], 220, WaitAt),
                        ?TESTMODULE:stop(Server),
                        ?assertEqual(Max_paralell_requests, length(Acc)),
                        FF = hd(Acc),
                        FirstPid = maps:get(pid, binary_to_term(FF#woodpecker_frame.data)),
                        lists:map(fun(#woodpecker_frame{data = DataFrame}) ->
                            Data = binary_to_term(DataFrame),
                            ?assertEqual(#{'query' => MQParam}, cowboy_req:match_qs([{'query', [], 'undefined'}], Data)),
                            ?assertEqual(FirstPid, maps:get(pid, Data))
                        end, Acc)
                end},
                {<<"Must respect max_paralell_requests for low priority requests">>,
                    fun() ->
                        QueryParam = erlang:unique_integer([monotonic,positive]),
                        MQParam = integer_to_binary(QueryParam),
                        WaitAt = tutils:spawn_wait_loop_max(10,100),
                        Server = mlibs:random_atom(),
                        Max_paralell_requests = 2,
                        ETSTable = woodpecker:generate_ets_name(Server),
                        ?TESTMODULE:start_link(#woodpecker_state{server = Server, connect_to = ?TESTHOST, connect_to_port = ?TESTPORT, report_to = WaitAt, heartbeat_freq = 10000, max_paralell_requests = Max_paralell_requests}),
                        [?TESTMODULE:get(Server,lists:append(["/?query=",integer_to_list(QueryParam)]),'low') || _A <- lists:seq(1,20)],
                        timer:sleep(20),
                        Tasks = ets:tab2list(ETSTable),
                        ?assertEqual(20, length(Tasks)),
                        Tst = ets:select(ETSTable,[{{wp_api_tasks,'_',new,low,'_','_','_','_','_','_','_','_','$2','$1','_'},[{'<','$1',10},{'<','$1','$2'}],['$_']}]),
                        ?assertEqual(20, length(Tst)),
                        Server ! 'heartbeat',
                        [Acc] = tutils:recieve_loop([], 220, WaitAt),
                        ?TESTMODULE:stop(Server),
                        ?assertEqual(Max_paralell_requests, length(Acc)),
                        FF = hd(Acc),
                        FirstPid = maps:get(pid, binary_to_term(FF#woodpecker_frame.data)),
                        lists:map(fun(#woodpecker_frame{data = DataFrame}) ->
                            Data = binary_to_term(DataFrame),
                            ?assertEqual(#{'query' => MQParam}, cowboy_req:match_qs([{'query', [], 'undefined'}], Data)),
                            ?assertEqual(FirstPid, maps:get(pid, Data))
                        end, Acc)
                end}
            ]
        }
    }.

% simple test
simple_test(get, Priority, NumberOfRequests) ->
    QueryParam = erlang:unique_integer([monotonic,positive]),
    MQParam = integer_to_binary(QueryParam),
    WaitAt = tutils:spawn_wait_loop_max(3,100),
    Server = mlibs:random_atom(),
    ?TESTMODULE:start_link(#woodpecker_state{server = Server, connect_to = ?TESTHOST, connect_to_port = ?TESTPORT, report_to = WaitAt, heartbeat_freq = 10}),
    [?TESTMODULE:get(Server,lists:append(["/?query=",integer_to_list(QueryParam)]),Priority) || _A <- lists:seq(1,NumberOfRequests)],
    [Acc] = tutils:recieve_loop([], 220, WaitAt),
    ?assertEqual(NumberOfRequests, length(Acc)),
    FF = hd(Acc),
    FirstPid = maps:get(pid, binary_to_term(FF#woodpecker_frame.data)),
    lists:map(fun(#woodpecker_frame{data = DataFrame}) ->
        Data = binary_to_term(DataFrame),
        ?assertEqual(#{'query' => MQParam}, cowboy_req:match_qs([{'query', [], 'undefined'}], Data)),
        ?assertEqual(FirstPid, maps:get(pid, Data))
    end, Acc),
    ?TESTMODULE:stop(Server).


start_cowboy(Acceptors) ->
    Dispatch = cowboy_router:compile([
            {'_', [
                {"/", ?MODULE, []}
            ]}
        ]
    ),
    {ok, CowboyPid} = cowboy:start_clear(http, Acceptors, [{port, ?TESTPORT}], #{
        env => #{dispatch => Dispatch}
    }), CowboyPid.

init(Req0, Opts) ->
    Method = cowboy_req:method(Req0),
    Req = process_req(Method, Req0),
    {ok, Req, Opts}.

process_req(_Method, Req) ->
    cowboy_req:reply(200, #{<<"content-type">> => <<"text/plain; charset=utf-8">>}, term_to_binary(Req), Req).
