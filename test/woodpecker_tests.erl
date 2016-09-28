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
-define(SpawnWaitLoop, 200).
-define(RecieveLoop, 250).

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
                        simple(get, 'urgent', 1)
                end},
                {<<"able to send 2 GET requests with urgent priority in single connection">>,
                    fun() ->
                        simple(get, 'urgent', 2)
                end},
                {<<"able to send single GET request with high priority in single connection">>,
                    fun() ->
                        simple(get, 'high', 1)
                end},
                {<<"able to send 2 GET requests with high priority in single connection">>,
                    fun() ->
                        simple(get, 'high', 2)
                end},
                {<<"able to send single GET request with normal priority in single connection">>,
                    fun() ->
                        simple(get, 'normal',1)
                end},
                {<<"able to send 2 GET requests with normal priority in single connection">>,
                    fun() ->
                        simple(get, 'normal',2)
                end},
                {<<"able to send single GET request with low priority in single connection">>,
                    fun() ->
                        simple(get, 'low',1)
                end},
                {<<"able to send 2 GET requests with low priority in single connection">>,
                    fun() ->
                        simple(get, 'low', 2)
                end},
                {<<"Must ignore max_paralell_requests_per_conn for urgent priority requests.">>,
                    fun() ->
                        QueryParam = erlang:unique_integer([monotonic,positive]),
                        MQParam = integer_to_binary(QueryParam),
                        WaitAt = tutils:spawn_wait_loop_max(25,?SpawnWaitLoop),
                        Server = mlibs:random_atom(),
                        Max_paralell_requests_per_conn = 2,
                        ETSTable = woodpecker:generate_ets_name(Server),
                        ?TESTMODULE:start_link(#woodpecker_state{server = Server, connect_to = ?TESTHOST, connect_to_port = ?TESTPORT, report_to = WaitAt, heartbeat_freq = 10000, max_paralell_requests_per_conn = Max_paralell_requests_per_conn}),
                        [?TESTMODULE:async_get(Server,lists:append(["/?query=",integer_to_list(QueryParam)]),'urgent') || _A <- lists:seq(1,15)],
                        timer:sleep(20),
                        Tasks = ets:tab2list(ETSTable),
                        ?assertEqual(15, length(Tasks)),
                        Tst = ets:select(ETSTable,[{#wp_api_tasks{priority = urgent,max_retry = '$2',retry_count = '$1', _ = '_'},[{'<','$1',10},{'<','$1','$2'}],['$_']}]),
                        ?assertEqual(15, length(Tst)),
                        Server ! 'heartbeat',
                        [Acc] = tutils:recieve_loop([], ?RecieveLoop, WaitAt),
                        ?assertEqual(15, length(Acc)),
                        FF = hd(Acc),
                        FirstPid = maps:get(pid, binary_to_term(FF#wp_api_tasks.data)),
                        lists:map(fun(#wp_api_tasks{data = DataFrame}) ->
                            Data = binary_to_term(DataFrame),
                            ?assertEqual(#{'query' => MQParam}, cowboy_req:match_qs([{'query', [], 'undefined'}], Data)),
                            ?assertEqual(FirstPid, maps:get(pid, Data))
                        end, Acc),
                        ?TESTMODULE:stop(Server)
                end},
                {<<"Must ignore max_paralell_requests_per_conn for high priority requests.">>,
                    fun() ->
                        QueryParam = erlang:unique_integer([monotonic,positive]),
                        MQParam = integer_to_binary(QueryParam),
                        WaitAt = tutils:spawn_wait_loop_max(25,?SpawnWaitLoop),
                        Server = mlibs:random_atom(),
                        Max_paralell_requests_per_conn = 2,
                        ETSTable = woodpecker:generate_ets_name(Server),
                        ?TESTMODULE:start_link(#woodpecker_state{server = Server, connect_to = ?TESTHOST, connect_to_port = ?TESTPORT, report_to = WaitAt, heartbeat_freq = 10000, max_paralell_requests_per_conn = Max_paralell_requests_per_conn}),
                        [?TESTMODULE:async_get(Server,lists:append(["/?query=",integer_to_list(QueryParam)]),'high') || _A <- lists:seq(1,15)],
                        timer:sleep(20),
                        Tasks = ets:tab2list(ETSTable),
                        ?assertEqual(15, length(Tasks)),
                        Tst = ets:select(ETSTable,[{#wp_api_tasks{priority = high,max_retry = '$2',retry_count = '$1', _ = '_'},[{'<','$1',10},{'<','$1','$2'}],['$_']}]),
 
                        ?assertEqual(15, length(Tst)),
                        Server ! 'heartbeat',
                        [Acc] = tutils:recieve_loop([], ?RecieveLoop, WaitAt),
                        ?assertEqual(15, length(Acc)),
                        FF = hd(Acc),
                        FirstPid = maps:get(pid, binary_to_term(FF#wp_api_tasks.data)),
                        lists:map(fun(#wp_api_tasks{data = DataFrame}) ->
                            Data = binary_to_term(DataFrame),
                            ?assertEqual(#{'query' => MQParam}, cowboy_req:match_qs([{'query', [], 'undefined'}], Data)),
                            ?assertEqual(FirstPid, maps:get(pid, Data))
                        end, Acc),
                        ?TESTMODULE:stop(Server)
                end},
                {<<"Must respect max_paralell_requests_per_conn for normal priority requests (in single heartbeat)">>,
                    fun() ->
                        QueryParam = erlang:unique_integer([monotonic,positive]),
                        MQParam = integer_to_binary(QueryParam),
                        WaitAt = tutils:spawn_wait_loop_max(10,?SpawnWaitLoop),
                        Server = mlibs:random_atom(),
                        Max_paralell_requests_per_conn = 2,
                        ETSTable = woodpecker:generate_ets_name(Server),
                        ?TESTMODULE:start_link(#woodpecker_state{server = Server, connect_to = ?TESTHOST, connect_to_port = ?TESTPORT, report_to = WaitAt, heartbeat_freq = 10000, max_paralell_requests_per_conn = Max_paralell_requests_per_conn}),
                        [?TESTMODULE:async_get(Server,lists:append(["/?query=",integer_to_list(QueryParam)]),'normal') || _A <- lists:seq(1,20)],
                        timer:sleep(20),
                        Tasks = ets:tab2list(ETSTable),
                        ?assertEqual(20, length(Tasks)),
                        Tst = ets:select(ETSTable,[{#wp_api_tasks{status = 'new', priority = normal,max_retry = '$2',retry_count = '$1', _ = '_'},[{'<','$1',10},{'<','$1','$2'}],['$_']}]),
                        ?assertEqual(20, length(Tst)),
                        Server ! 'heartbeat',
                        [Acc] = tutils:recieve_loop([], ?RecieveLoop, WaitAt),
                        ?TESTMODULE:stop(Server),
                        ?assertEqual(Max_paralell_requests_per_conn, length(Acc)),
                        FF = hd(Acc),
                        FirstPid = maps:get(pid, binary_to_term(FF#wp_api_tasks.data)),
                        lists:map(fun(#wp_api_tasks{data = DataFrame}) ->
                            Data = binary_to_term(DataFrame),
                            ?assertEqual(#{'query' => MQParam}, cowboy_req:match_qs([{'query', [], 'undefined'}], Data)),
                            ?assertEqual(FirstPid, maps:get(pid, Data))
                        end, Acc)
                end},
                {<<"Must respect max_paralell_requests_per_conn for low priority requests">>,
                    fun() ->
                        QueryParam = erlang:unique_integer([monotonic,positive]),
                        MQParam = integer_to_binary(QueryParam),
                        WaitAt = tutils:spawn_wait_loop_max(10,?SpawnWaitLoop),
                        Server = mlibs:random_atom(),
                        Max_paralell_requests_per_conn = 2,
                        ETSTable = woodpecker:generate_ets_name(Server),
                        ?TESTMODULE:start_link(#woodpecker_state{server = Server, connect_to = ?TESTHOST, connect_to_port = ?TESTPORT, report_to = WaitAt, heartbeat_freq = 10000, max_paralell_requests_per_conn = Max_paralell_requests_per_conn}),
                        [?TESTMODULE:async_get(Server,lists:append(["/?query=",integer_to_list(QueryParam)]),'low') || _A <- lists:seq(1,20)],
                        timer:sleep(20),
                        Tasks = ets:tab2list(ETSTable),
                        ?assertEqual(20, length(Tasks)),
                        Tst = ets:select(ETSTable,[{#wp_api_tasks{status = 'new', priority = low,max_retry = '$2',retry_count = '$1', _ = '_'},[{'<','$1',10},{'<','$1','$2'}],['$_']}]),
                        ?assertEqual(20, length(Tst)),
                        Server ! 'heartbeat',
                        [Acc] = tutils:recieve_loop([], ?RecieveLoop, WaitAt),
                        ?TESTMODULE:stop(Server),
                        ?assertEqual(Max_paralell_requests_per_conn, length(Acc)),
                        FF = hd(Acc),
                        FirstPid = maps:get(pid, binary_to_term(FF#wp_api_tasks.data)),
                        lists:map(fun(#wp_api_tasks{data = DataFrame}) ->
                            Data = binary_to_term(DataFrame),
                            ?assertEqual(#{'query' => MQParam}, cowboy_req:match_qs([{'query', [], 'undefined'}], Data)),
                            ?assertEqual(FirstPid, maps:get(pid, Data))
                        end, Acc)
                end},
                {<<"Must do not respect requests_allowed_by_api/requests_allowed_in_period for urgent priority requests">>,
                    fun() ->
                        QueryParam = erlang:unique_integer([monotonic,positive]),
                        MQParam = integer_to_binary(QueryParam),
                        WaitAt = tutils:spawn_wait_loop_max(20,?SpawnWaitLoop),
                        Server = mlibs:random_atom(),
                        Requests_allowed_by_api = 1,
                        Requests_allowed_in_period = 10000,
                        SendReq = 10,
                        ETSTable = woodpecker:generate_ets_name(Server),
                        ?TESTMODULE:start_link(#woodpecker_state{server = Server, connect_to = ?TESTHOST, connect_to_port = ?TESTPORT, report_to = WaitAt, heartbeat_freq = 10000, requests_allowed_in_period = Requests_allowed_in_period, requests_allowed_by_api = Requests_allowed_by_api}),
                        [?TESTMODULE:async_get(Server,lists:append(["/?query=",integer_to_list(QueryParam)]),'urgent') || _A <- lists:seq(1,SendReq)],
                        timer:sleep(20),
                        Tasks = ets:tab2list(ETSTable),
                        ?assertEqual(SendReq, length(Tasks)),
                        Tst = ets:select(ETSTable,[{#wp_api_tasks{priority = urgent,max_retry = '$2',retry_count = '$1', _ = '_'},[{'<','$1',10},{'<','$1','$2'}],['$_']}]),
                        ?assertEqual(SendReq, length(Tst)),
                        [Acc] = tutils:recieve_loop([], ?RecieveLoop, WaitAt),
                        ?TESTMODULE:stop(Server),
                        ?assertEqual(SendReq, length(Acc)),
                        FF = hd(Acc),
                        FirstPid = maps:get(pid, binary_to_term(FF#wp_api_tasks.data)),
                        lists:map(fun(#wp_api_tasks{data = DataFrame}) ->
                            Data = binary_to_term(DataFrame),
                            ?assertEqual(#{'query' => MQParam}, cowboy_req:match_qs([{'query', [], 'undefined'}], Data)),
                            ?assertEqual(FirstPid, maps:get(pid, Data))
                        end, Acc)
                end},
                {<<"Must respect requests_allowed_by_api/requests_allowed_in_period for high priority requests">>,
                    fun() ->
                        QueryParam = erlang:unique_integer([monotonic,positive]),
                        MQParam = integer_to_binary(QueryParam),
                        WaitAt = tutils:spawn_wait_loop_max(10,?SpawnWaitLoop),
                        Server = mlibs:random_atom(),
                        Requests_allowed_by_api = 1,
                        Requests_allowed_in_period = 10000,
                        SendReq = 10,
                        ETSTable = woodpecker:generate_ets_name(Server),
                        ?TESTMODULE:start_link(#woodpecker_state{server = Server, connect_to = ?TESTHOST, connect_to_port = ?TESTPORT, report_to = WaitAt, heartbeat_freq = 10000, requests_allowed_in_period = Requests_allowed_in_period, requests_allowed_by_api = Requests_allowed_by_api}),
                        [?TESTMODULE:async_get(Server,lists:append(["/?query=",integer_to_list(QueryParam)]),'high') || _A <- lists:seq(1,SendReq)],
                        timer:sleep(20),
                        Tasks = ets:tab2list(ETSTable),
                        ?assertEqual(SendReq, length(Tasks)),
                        Tst = ets:select(ETSTable,[{#wp_api_tasks{priority = 'high',max_retry = '$2',retry_count = '$1', _ = '_'},[{'<','$1',10},{'<','$1','$2'}],['$_']}]),
                        ?assertEqual(SendReq, length(Tst)),
                         Server ! 'heartbeat',
                        [Acc] = tutils:recieve_loop([], ?RecieveLoop, WaitAt),
                        ?TESTMODULE:stop(Server),
                        ?assertEqual(Requests_allowed_by_api, length(Acc)),
                        FF = hd(Acc),
                        FirstPid = maps:get(pid, binary_to_term(FF#wp_api_tasks.data)),
                        lists:map(fun(#wp_api_tasks{data = DataFrame}) ->
                            Data = binary_to_term(DataFrame),
                            ?assertEqual(#{'query' => MQParam}, cowboy_req:match_qs([{'query', [], 'undefined'}], Data)),
                            ?assertEqual(FirstPid, maps:get(pid, Data))
                        end, Acc)
                end},
                {<<"If we overquoted during 'urgent' tasks, wp must do not process requests with 'high' priority until will have quota">>,
                    fun() ->
                        QueryParam = erlang:unique_integer([monotonic,positive]),
                        MQParam = integer_to_binary(QueryParam),
                        WaitAt = tutils:spawn_wait_loop_max(21,?SpawnWaitLoop),
                        Server = mlibs:random_atom(),
                        Requests_allowed_by_api = 11,
                        Requests_allowed_in_period = 1000,
                        SendReq = 10,
                        ETSTable = woodpecker:generate_ets_name(Server),
                        ?TESTMODULE:start_link(#woodpecker_state{server = Server, connect_to = ?TESTHOST, connect_to_port = ?TESTPORT, report_to = WaitAt, heartbeat_freq = 10000, requests_allowed_in_period = Requests_allowed_in_period, requests_allowed_by_api = Requests_allowed_by_api}),
                        [?TESTMODULE:async_get(Server,lists:append(["/?query=",integer_to_list(QueryParam)]),'urgent') || _A <- lists:seq(1,SendReq)],
                        [?TESTMODULE:async_get(Server,lists:append(["/?query=",integer_to_list(QueryParam)]),'high') || _A <- lists:seq(1,SendReq)],
                        timer:sleep(20),
                        Tasks = ets:tab2list(ETSTable),
                        ?assertEqual(SendReq*2, length(Tasks)),
                        Tst1 = ets:select(ETSTable,[{#wp_api_tasks{priority = 'urgent',max_retry = '$2',retry_count = '$1', _ = '_'},[{'<','$1',10},{'<','$1','$2'}],['$_']}]),
                        ?assertEqual(SendReq, length(Tst1)),
                        Tst2 = ets:select(ETSTable,[{#wp_api_tasks{status = 'new', priority = 'high',max_retry = '$2',retry_count = '$1', _ = '_'},[{'<','$1',10},{'<','$1','$2'}],['$_']}]),
                        Tst3 = ets:select(ETSTable,[{#wp_api_tasks{priority = 'high',max_retry = '$2',retry_count = '$1', _ = '_'},[{'<','$1',10},{'<','$1','$2'}],['$_']}]),
 
                        Server ! 'heartbeat',
                        ?assertEqual(SendReq, length(Tst2)+1),
                        ?assertEqual(SendReq, length(Tst3)),
                        [Acc] = tutils:recieve_loop([], ?RecieveLoop, WaitAt),
                        ?TESTMODULE:stop(Server),
                        ?assertEqual(Requests_allowed_by_api, length(Acc)),
                        FF = hd(Acc),
                        FirstPid = maps:get(pid, binary_to_term(FF#wp_api_tasks.data)),
                        lists:map(fun(#wp_api_tasks{data = DataFrame}) ->
                            Data = binary_to_term(DataFrame),
                            ?assertEqual(#{'query' => MQParam}, cowboy_req:match_qs([{'query', [], 'undefined'}], Data)),
                            ?assertEqual(FirstPid, maps:get(pid, Data))
                        end, Acc)
                end},
                {<<"Must respect requests_allowed_by_api/requests_allowed_in_period for normal priority requests">>,
                    fun() ->
                        QueryParam = erlang:unique_integer([monotonic,positive]),
                        MQParam = integer_to_binary(QueryParam),
                        WaitAt = tutils:spawn_wait_loop_max(10,?SpawnWaitLoop),
                        Server = mlibs:random_atom(),
                        Requests_allowed_by_api = 5,
                        Requests_allowed_in_period = 10000,
                        SendReq = 10,
                        ETSTable = woodpecker:generate_ets_name(Server),
                        ?TESTMODULE:start_link(#woodpecker_state{server = Server, connect_to = ?TESTHOST, connect_to_port = ?TESTPORT, report_to = WaitAt, heartbeat_freq = 10000, requests_allowed_in_period = Requests_allowed_in_period, requests_allowed_by_api = Requests_allowed_by_api}),
                        [?TESTMODULE:async_get(Server,lists:append(["/?query=",integer_to_list(QueryParam)]),'normal') || _A <- lists:seq(1,SendReq)],
                        timer:sleep(20),
                        Tasks = ets:tab2list(ETSTable),
                        ?assertEqual(SendReq, length(Tasks)),
                        Tst = ets:select(ETSTable,[{#wp_api_tasks{status = 'new', priority = 'normal',max_retry = '$2',retry_count = '$1', _ = '_'},[{'<','$1',10},{'<','$1','$2'}],['$_']}]),
                        ?assertEqual(SendReq, length(Tst)),
                         Server ! 'heartbeat',
                        timer:sleep(5),
                        Tst2 = ets:select(ETSTable,[{#wp_api_tasks{status = 'new', priority = 'normal',max_retry = '$2',retry_count = '$1', _ = '_'},[{'<','$1',10},{'<','$1','$2'}],['$_']}]),
                        ?assertEqual(SendReq, length(Tst2)+Requests_allowed_by_api),
 
                        [Acc] = tutils:recieve_loop([], ?RecieveLoop, WaitAt),
                        ?TESTMODULE:stop(Server),
                        ?assertEqual(Requests_allowed_by_api, length(Acc)),
                        FF = hd(Acc),
                        FirstPid = maps:get(pid, binary_to_term(FF#wp_api_tasks.data)),
                        lists:map(fun(#wp_api_tasks{data = DataFrame}) ->
                            Data = binary_to_term(DataFrame),
                            ?assertEqual(#{'query' => MQParam}, cowboy_req:match_qs([{'query', [], 'undefined'}], Data)),
                            ?assertEqual(FirstPid, maps:get(pid, Data))
                        end, Acc)
                end},
                {<<"Must respect requests_allowed_by_api/requests_allowed_in_period for low priority requests">>,
                    fun() ->
                        QueryParam = erlang:unique_integer([monotonic,positive]),
                        MQParam = integer_to_binary(QueryParam),
                        WaitAt = tutils:spawn_wait_loop_max(10,?SpawnWaitLoop),
                        Server = mlibs:random_atom(),
                        Requests_allowed_by_api = 5,
                        Requests_allowed_in_period = 10000,
                        SendReq = 10,
                        ETSTable = woodpecker:generate_ets_name(Server),
                        ?TESTMODULE:start_link(#woodpecker_state{server = Server, connect_to = ?TESTHOST, connect_to_port = ?TESTPORT, report_to = WaitAt, heartbeat_freq = 10000, requests_allowed_in_period = Requests_allowed_in_period, requests_allowed_by_api = Requests_allowed_by_api}),
                        [?TESTMODULE:async_get(Server,lists:append(["/?query=",integer_to_list(QueryParam)]),'low') || _A <- lists:seq(1,SendReq)],
                        timer:sleep(20),
                        Tasks = ets:tab2list(ETSTable),
                        ?assertEqual(SendReq, length(Tasks)),
                        Tst = ets:select(ETSTable,[{#wp_api_tasks{status = 'new', priority = 'low',max_retry = '$2',retry_count = '$1', _ = '_'},[{'<','$1',10},{'<','$1','$2'}],['$_']}]),
                        ?assertEqual(SendReq, length(Tst)),
                         Server ! 'heartbeat',
                        timer:sleep(5),
                        Tst2 = ets:select(ETSTable,[{#wp_api_tasks{status = 'new', priority = 'low',max_retry = '$2',retry_count = '$1', _ = '_'},[{'<','$1',10},{'<','$1','$2'}],['$_']}]),
                        ?assertEqual(SendReq, length(Tst2)+Requests_allowed_by_api),
 
                        [Acc] = tutils:recieve_loop([], ?RecieveLoop, WaitAt),
                        ?TESTMODULE:stop(Server),
                        ?assertEqual(Requests_allowed_by_api, length(Acc)),
                        FF = hd(Acc),
                        FirstPid = maps:get(pid, binary_to_term(FF#wp_api_tasks.data)),
                        lists:map(fun(#wp_api_tasks{data = DataFrame}) ->
                            Data = binary_to_term(DataFrame),
                            ?assertEqual(#{'query' => MQParam}, cowboy_req:match_qs([{'query', [], 'undefined'}], Data)),
                            ?assertEqual(FirstPid, maps:get(pid, Data))
                        end, Acc)
                end},
                {<<"Request order test">>,
                    fun() ->
                        ok
                    end
                }
            ]
        }
    }.

tests_with_gun_and_slowcowboy_test_() ->
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
                {<<"Must respect max_paralell_requests_per_conn for normal priority requests (with multiple hearbeat)">>,
                    fun() ->
                        QueryParam = erlang:unique_integer([monotonic,positive]),
                        MQParam = integer_to_binary(QueryParam),
                        WaitAt = tutils:spawn_wait_loop_max(10,?SpawnWaitLoop),
                        Server = mlibs:random_atom(),
                        Max_paralell_requests_per_conn = 2,
                        TimerForCowboy = 20,
                        ETSTable = woodpecker:generate_ets_name(Server),
                        ?TESTMODULE:start_link(#woodpecker_state{server = Server, connect_to = ?TESTHOST, connect_to_port = ?TESTPORT, report_to = WaitAt, heartbeat_freq = 10000, max_paralell_requests_per_conn = Max_paralell_requests_per_conn}),
                        [?TESTMODULE:async_get(Server,lists:append(["/?query=",integer_to_list(QueryParam),"&wait=",integer_to_list(TimerForCowboy)]),'normal') || _A <- lists:seq(1,20)],
                        timer:sleep(10),
                        Tasks = ets:tab2list(ETSTable),
                        ?assertEqual(20, length(Tasks)),
                        Tst = ets:select(ETSTable,[{#wp_api_tasks{status = 'new', priority = normal,max_retry = '$2',retry_count = '$1', _ = '_'},[{'<','$1',10},{'<','$1','$2'}],['$_']}]),
                        ?assertEqual(20, length(Tst)),
                        Server ! 'heartbeat',
                        Server ! 'heartbeat',
                        [Acc] = tutils:recieve_loop([], ?RecieveLoop, WaitAt),
                        ?TESTMODULE:stop(Server),
                        ?assertEqual(Max_paralell_requests_per_conn, length(Acc)),
                        FF = hd(Acc),
                        FirstPid = maps:get(pid, binary_to_term(FF#wp_api_tasks.data)),
                        lists:map(fun(#wp_api_tasks{data = DataFrame}) ->
                            Data = binary_to_term(DataFrame),
                            ?assertEqual(#{'query' => MQParam}, cowboy_req:match_qs([{'query', [], 'undefined'}], Data)),
                            ?assertEqual(FirstPid, maps:get(pid, Data))
                        end, Acc)
                end}
            ]
        }
    }.


% simple test
simple(get, Priority, NumberOfRequests) ->
    QueryParam = erlang:unique_integer([monotonic,positive]),
    MQParam = integer_to_binary(QueryParam),
    WaitAt = tutils:spawn_wait_loop_max(3,100),
    Server = mlibs:random_atom(),
    ?TESTMODULE:start_link(#woodpecker_state{server = Server, connect_to = ?TESTHOST, connect_to_port = ?TESTPORT, report_to = WaitAt, heartbeat_freq = 10}),
    [?TESTMODULE:async_get(Server,lists:append(["/?query=",integer_to_list(QueryParam)]),Priority) || _A <- lists:seq(1,NumberOfRequests)],
    [Acc] = tutils:recieve_loop([], 220, WaitAt),
    ?assertEqual(NumberOfRequests, length(Acc)),
    FF = hd(Acc),
    FirstPid = maps:get(pid, binary_to_term(FF#wp_api_tasks.data)),
    lists:map(fun(#wp_api_tasks{data = DataFrame}) ->
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
    #{wait := Wait} = cowboy_req:match_qs([{'wait', [], 'undefined'}], Req0),
    case Wait of
        'undefined' -> ok;
        Time -> timer:sleep(binary_to_integer(Time))
    end,
    Req = process_req(Method, Req0),
    {ok, Req, Opts}.

process_req(_Method, Req) ->
    cowboy_req:reply(200, #{<<"content-type">> => <<"text/plain; charset=utf-8">>}, term_to_binary(Req), Req).
