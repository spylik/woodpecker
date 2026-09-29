% ATTENTION: do not run this tests on production nodes
% we using tutils:random_atom for creating random names for servers,
% but atoms will not garbage collected

-module(woodpecker_tests).

-include_lib("eunit/include/eunit.hrl").
-include("woodpecker.hrl").
-compile(export_all).

-export([init/2,start_cowboy/1]).

-define(TESTMODULE, woodpecker).
-define(TESTSERVER, test_wp_server).
-define(REGISTERAS, {'local', ?TESTSERVER}).
-define(REGISTERAS(ServName), {'local', ServName}).
-define(TESTHOST, "127.0.0.1").
-define(TESTPORT, 8082).
-define(SpawnWaitLoop, 200).
-define(RecieveLoop, 250).
-define(RanchOpts,
        #{
            socket_opts => [{port, ?TESTPORT}],
            num_acceptors => 10
        }
    ).

% --------------------------------- fixtures ----------------------------------

match_spec_test() ->
    Ets = ?TESTMODULE:init_ets(tutils:random_atom()),
    NonceGroupTask = #wp_api_tasks{ref = make_ref(), status = new, nonce_group = {1,1}},
    ets:insert(Ets, #wp_api_tasks{ref = make_ref(), status = processing, nonce_group = {2,2}}),
    ?assertNot(?TESTMODULE:is_another_task_with_same_nonce_group_running(Ets, NonceGroupTask)),
    ets:insert(Ets, #wp_api_tasks{ref = make_ref(), status = new, nonce_group = {1,1}}),
    ?assertNot(?TESTMODULE:is_another_task_with_same_nonce_group_running(Ets, NonceGroupTask)),
    ets:insert(Ets, #wp_api_tasks{ref = make_ref(), status = got_fin, nonce_group = {1,1}}),
    ?assertNot(?TESTMODULE:is_another_task_with_same_nonce_group_running(Ets, NonceGroupTask)),
    ets:insert(Ets, #wp_api_tasks{ref = make_ref(), status = processing, nonce_group = {1,1}}),
    ?assert(?TESTMODULE:is_another_task_with_same_nonce_group_running(Ets, NonceGroupTask)).

% tests for cover standart otp behaviour
otp_test_() ->
    {setup,
        fun() -> error_logger:tty(false) end,
        {inorder,
            [
                {<<"gen_server able to start via ?TESTSERVER:start_link(?TESTHOST, ?TESTPORT)">>,
                    fun() ->
                        ?TESTMODULE:start_link(?TESTHOST, ?TESTPORT, #{register => ?REGISTERAS}),
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
                        ?TESTMODULE:start_link(?TESTHOST, ?TESTPORT, #{register => ?REGISTERAS}),
                        ?assertEqual(ok, ?TESTMODULE:stop('sync',?TESTSERVER)),
                        ?assertEqual(
                            false,
                            is_pid(whereis(?TESTSERVER))
                        )
                end},
                {<<"gen_server able to start and stop via ?TESTSERVER:start_link() / ?TESTSERVER:stop()">>,
                    fun() ->
                        ?TESTMODULE:start_link(?TESTHOST, ?TESTPORT, #{register => ?REGISTERAS}),
                        ?assertEqual(ok, ?TESTMODULE:stop(?TESTSERVER)),
                        ?assertEqual(
                            false,
                            is_pid(whereis(?TESTSERVER))
                        )
                end},
                {<<"gen_server able to start and stop via ?TESTSERVER:start_link() ?TESTSERVER:stop(async)">>,
                    fun() ->
                        ?TESTMODULE:start_link(?TESTHOST, ?TESTPORT, #{register => ?REGISTERAS}),
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
            CowboyRanchRef = start_cowboy(?RanchOpts),
            ok = warm_up(),
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
                        Server = tutils:random_atom(),
                        Max_paralell_requests_per_conn = 2,
                        ETSTable = woodpecker:generate_ets_name(?TESTHOST, ?REGISTERAS(Server)),
                        ?TESTMODULE:start_link(
                            ?TESTHOST,
                            ?TESTPORT,
                            #{
                                register                        => ?REGISTERAS(Server),
                                report_to                       => {'message', WaitAt},
                                heartbeat_freq                  => 10000,
                                max_paralell_requests_per_conn  => Max_paralell_requests_per_conn
                            }
                        ),
                        [?TESTMODULE:get_async(Server,lists:append(["/?query=",integer_to_list(QueryParam)]),[], #{priority => 'urgent'}) || _A <- lists:seq(1,15)],
                        timer:sleep(100),
                        Tasks = ets:tab2list(ETSTable),
                        ?assertEqual(15, length(Tasks)),
                        Tst = ets:select(ETSTable,[{#wp_api_tasks{priority = urgent,max_retry = '$2',retry_count = '$1', _ = '_'},[{'<','$1',10},{'<','$1','$2'}],['$_']}]),
                        ?assertEqual(15, length(Tst)),
                        Server ! 'heartbeat',
                        [Acc] = tutils:recieve_loop([], ?RecieveLoop, WaitAt),
                        ?assertEqual(15, length(Acc)),
                        FF = hd(Acc),
                        FirstPid = maps:get(pid, binary_to_term(maps:get(resp_body, FF))),
                        lists:map(fun(#{resp_body := DataFrame}) ->
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
                        Server = tutils:random_atom(),
                        Max_paralell_requests_per_conn = 2,
                        ETSTable = woodpecker:generate_ets_name(?TESTHOST, ?REGISTERAS(Server)),
                        ?TESTMODULE:start_link(
                            ?TESTHOST,
                            ?TESTPORT,
                            #{
                                register                        => ?REGISTERAS(Server),
                                report_to                       => {'message', WaitAt},
                                heartbeat_freq                  => 10000,
                                max_paralell_requests_per_conn  => Max_paralell_requests_per_conn
                            }
                        ),
                        [?TESTMODULE:get_async(Server,lists:append(["/?query=",integer_to_list(QueryParam)]), [], #{priority => 'high'}) || _A <- lists:seq(1,15)],
                        timer:sleep(100),
                        Tasks = ets:tab2list(ETSTable),
                        ?assertEqual(15, length(Tasks)),
                        Tst = ets:select(ETSTable,[{#wp_api_tasks{priority = high,max_retry = '$2',retry_count = '$1', _ = '_'},[{'<','$1',10},{'<','$1','$2'}],['$_']}]),

                        ?assertEqual(15, length(Tst)),
                        Server ! 'heartbeat',
                        [Acc] = tutils:recieve_loop([], ?RecieveLoop, WaitAt),
                        ?assertEqual(15, length(Acc)),
                        FF = hd(Acc),
                        FirstPid = maps:get(pid, binary_to_term(maps:get(resp_body, FF))),
                        lists:map(fun(#{resp_body := DataFrame}) ->
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
                        Server = tutils:random_atom(),
                        Max_paralell_requests_per_conn = 2,
                        ETSTable = woodpecker:generate_ets_name(?TESTHOST, ?REGISTERAS(Server)),
                        ?TESTMODULE:start_link(
                            ?TESTHOST,
                            ?TESTPORT,
                            #{
                                register                        => ?REGISTERAS(Server),
                                report_to                       => {'message', WaitAt},
                                heartbeat_freq                  => 10000,
                                max_paralell_requests_per_conn  => Max_paralell_requests_per_conn
                            }
                        ),
                        [?TESTMODULE:get_async(Server,lists:append(["/?query=",integer_to_list(QueryParam)]), [], #{priority => 'normal'}) || _A <- lists:seq(1,20)],
                        timer:sleep(100),
                        Tasks = ets:tab2list(ETSTable),
                        ?assertEqual(20, length(Tasks)),
                        Tst = ets:select(ETSTable,[{#wp_api_tasks{status = 'new', priority = normal,max_retry = '$2',retry_count = '$1', _ = '_'},[{'<','$1',10},{'<','$1','$2'}],['$_']}]),
                        ?assertEqual(20, length(Tst)),
                        Server ! 'heartbeat',
                        [Acc] = tutils:recieve_loop([], ?RecieveLoop, WaitAt),
                        ?TESTMODULE:stop(Server),
                        ?assertEqual(Max_paralell_requests_per_conn, length(Acc)),
                        FF = hd(Acc),
                        FirstPid = maps:get(pid, binary_to_term(maps:get(resp_body, FF))),
                        lists:map(fun(#{resp_body := DataFrame}) ->
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
                        Server = tutils:random_atom(),
                        Max_paralell_requests_per_conn = 2,
                        ETSTable = woodpecker:generate_ets_name(?TESTHOST, ?REGISTERAS(Server)),
                        ?TESTMODULE:start_link(
                            ?TESTHOST,
                            ?TESTPORT,
                            #{
                                register                        => ?REGISTERAS(Server),
                                report_to                       => {'message', WaitAt},
                                heartbeat_freq                  => 10000,
                                max_paralell_requests_per_conn  => Max_paralell_requests_per_conn
                            }
                        ),
                        [?TESTMODULE:get_async(Server,lists:append(["/?query=",integer_to_list(QueryParam)]), [], #{priority => 'low'}) || _A <- lists:seq(1,20)],
                        timer:sleep(100),
                        Tasks = ets:tab2list(ETSTable),
                        ?assertEqual(20, length(Tasks)),
                        Tst = ets:select(ETSTable,[{#wp_api_tasks{status = 'new', priority = low,max_retry = '$2',retry_count = '$1', _ = '_'},[{'<','$1',10},{'<','$1','$2'}],['$_']}]),
                        ?assertEqual(20, length(Tst)),
                        Server ! 'heartbeat',
                        [Acc] = tutils:recieve_loop([], ?RecieveLoop, WaitAt),
                        ?TESTMODULE:stop(Server),
                        ?assertEqual(Max_paralell_requests_per_conn, length(Acc)),
                        FF = hd(Acc),
                        FirstPid = maps:get(pid, binary_to_term(maps:get(resp_body, FF))),
                        lists:map(fun(#{resp_body := DataFrame}) ->
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
                        Server = tutils:random_atom(),
                        Requests_allowed_by_api = 1,
                        Requests_allowed_in_period = 10000,
                        SendReq = 10,
                        ETSTable = woodpecker:generate_ets_name(?TESTHOST, ?REGISTERAS(Server)),
                        ?TESTMODULE:start_link(
                            ?TESTHOST,
                            ?TESTPORT,
                            #{
                                register                        => ?REGISTERAS(Server),
                                report_to                       => {'message', WaitAt},
                                heartbeat_freq                  => 10000,
                                requests_allowed_in_period      => Requests_allowed_in_period,
                                requests_allowed_by_api         => Requests_allowed_by_api
                            }
                        ),
                        [?TESTMODULE:get_async(Server,lists:append(["/?query=",integer_to_list(QueryParam)]), [], #{priority => 'urgent'}) || _A <- lists:seq(1,SendReq)],
                        timer:sleep(100),
                        Tasks = ets:tab2list(ETSTable),
                        ?assertEqual(SendReq, length(Tasks)),
                        Tst = ets:select(ETSTable,[{#wp_api_tasks{priority = urgent,max_retry = '$2',retry_count = '$1', _ = '_'},[{'<','$1',10},{'<','$1','$2'}],['$_']}]),
                        ?assertEqual(SendReq, length(Tst)),
                        [Acc] = tutils:recieve_loop([], ?RecieveLoop, WaitAt),
                        ?TESTMODULE:stop(Server),
                        ?assertEqual(SendReq, length(Acc)),
                        FF = hd(Acc),
                        FirstPid = maps:get(pid, binary_to_term(maps:get(resp_body, FF))),
                        lists:map(fun(#{resp_body := DataFrame}) ->
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
                        Server = tutils:random_atom(),
                        Requests_allowed_by_api = 1,
                        Requests_allowed_in_period = 10000,
                        SendReq = 10,
                        ETSTable = woodpecker:generate_ets_name(?TESTHOST, ?REGISTERAS(Server)),
                        ?TESTMODULE:start_link(
                            ?TESTHOST,
                            ?TESTPORT,
                            #{
                                register                        => ?REGISTERAS(Server),
                                report_to                       => {'message', WaitAt},
                                heartbeat_freq                  => 10000,
                                requests_allowed_in_period      => Requests_allowed_in_period,
                                requests_allowed_by_api         => Requests_allowed_by_api
                            }
                        ),
                        [?TESTMODULE:get_async(Server,lists:append(["/?query=",integer_to_list(QueryParam)]), [], #{priority => 'high'}) || _A <- lists:seq(1,SendReq)],
                        timer:sleep(100),
                        Tasks = ets:tab2list(ETSTable),
                        ?assertEqual(SendReq, length(Tasks)),
                        Tst = ets:select(ETSTable,[{#wp_api_tasks{priority = 'high',max_retry = '$2',retry_count = '$1', _ = '_'},[{'<','$1',10},{'<','$1','$2'}],['$_']}]),
                        ?assertEqual(SendReq, length(Tst)),
                         Server ! 'heartbeat',
                        [Acc] = tutils:recieve_loop([], ?RecieveLoop, WaitAt),
                        ?TESTMODULE:stop(Server),
                        ?assertEqual(Requests_allowed_by_api, length(Acc)),
                        FF = hd(Acc),
                        FirstPid = maps:get(pid, binary_to_term(maps:get(resp_body, FF))),
                        lists:map(fun(#{resp_body := DataFrame}) ->
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
                        Server = tutils:random_atom(),
                        Requests_allowed_by_api = 11,
                        Requests_allowed_in_period = 1000,
                        SendReq = 10,
                        ETSTable = woodpecker:generate_ets_name(?TESTHOST, ?REGISTERAS(Server)),
                        ?TESTMODULE:start_link(
                            ?TESTHOST,
                            ?TESTPORT,
                            #{
                                register                        => ?REGISTERAS(Server),
                                report_to                       => {'message', WaitAt},
                                heartbeat_freq                  => 10000,
                                requests_allowed_in_period      => Requests_allowed_in_period,
                                requests_allowed_by_api         => Requests_allowed_by_api
                            }
                        ),
                        [?TESTMODULE:get_async(Server,lists:append(["/?query=",integer_to_list(QueryParam)]), [], #{priority => 'urgent'}) || _A <- lists:seq(1,SendReq)],
                        [?TESTMODULE:get_async(Server,lists:append(["/?query=",integer_to_list(QueryParam)]), [], #{priority => 'high'}) || _A <- lists:seq(1,SendReq)],
                        timer:sleep(100),
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
                        FirstPid = maps:get(pid, binary_to_term(maps:get(resp_body, FF))),
                        lists:map(fun(#{resp_body := DataFrame}) ->
                            Data = binary_to_term(DataFrame),
                            ?assertEqual(#{'query' => MQParam}, cowboy_req:match_qs([{'query', [], 'undefined'}], Data)),
                            ?assertEqual(FirstPid, maps:get(pid, Data))
                        end, Acc)
                end},
                {<<"Must respect requests_allowed_by_api/requests_allowed_in_period for normal priority requests">>,
                    fun() ->
                        application:ensure_all_started(gun),
                        QueryParam = erlang:unique_integer([monotonic,positive]),
                        MQParam = integer_to_binary(QueryParam),
                        WaitAt = tutils:spawn_wait_loop_max(10,?SpawnWaitLoop),
                        Server = tutils:random_atom(),
                        Requests_allowed_by_api = 5,
                        Requests_allowed_in_period = 10000,
                        SendReq = 10,
                        ETSTable = woodpecker:generate_ets_name(?TESTHOST, ?REGISTERAS(Server)),
                        ?TESTMODULE:start_link(
                            ?TESTHOST,
                            ?TESTPORT,
                            #{
                                register                        => ?REGISTERAS(Server),
                                report_to                       => {'message', WaitAt},
                                heartbeat_freq                  => 10000,
                                requests_allowed_in_period      => Requests_allowed_in_period,
                                requests_allowed_by_api         => Requests_allowed_by_api
                            }
                        ),
                        [?TESTMODULE:get_async(Server,lists:append(["/?query=",integer_to_list(QueryParam)]), [], #{priority => 'normal'}) || _A <- lists:seq(1,SendReq)],
                        timer:sleep(20),
                        Tasks = ets:tab2list(ETSTable),
                        ?assertEqual(SendReq, length(Tasks)),
                        Tst1 = ets:select(ETSTable,[{#wp_api_tasks{status = 'new', priority = 'normal',max_retry = '$2',retry_count = '$1', _ = '_'},[{'<','$1',10},{'<','$1','$2'}],['$_']}]),
                        ?assertEqual(SendReq, length(Tst1)),
                        Server ! 'heartbeat',
                        timer:sleep(20),
                        Tst2 = ets:select(ETSTable,[{#wp_api_tasks{status = '$3', priority = 'normal',max_retry = '$2',retry_count = '$1', _ = '_'},[{'=/=', '$3', 'new'},{'<','$1',10},{'<','$1','$2'}],['$_']}]),
                        ?assertEqual(Requests_allowed_by_api, length(Tst2)),
                        Tst3 = ets:select(ETSTable,[{#wp_api_tasks{status = 'new', priority = 'normal',max_retry = '$2',retry_count = '$1', _ = '_'},[{'<','$1',10},{'<','$1','$2'}],['$_']}]),
                        ?assertEqual(SendReq, length(Tst3)+Requests_allowed_by_api),

                        [Acc] = tutils:recieve_loop([], ?RecieveLoop, WaitAt),
                        ?TESTMODULE:stop(Server),
                        ?assertEqual(Requests_allowed_by_api, length(Acc)),
                        FF = hd(Acc),
                        FirstPid = maps:get(pid, binary_to_term(maps:get(resp_body, FF))),
                        lists:map(fun(#{resp_body := DataFrame}) ->
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
                        Server = tutils:random_atom(),
                        Requests_allowed_by_api = 5,
                        Requests_allowed_in_period = 10000,
                        SendReq = 10,
                        ETSTable = woodpecker:generate_ets_name(?TESTHOST, ?REGISTERAS(Server)),
                        ?TESTMODULE:start_link(
                            ?TESTHOST,
                            ?TESTPORT,
                            #{
                                register                        => ?REGISTERAS(Server),
                                report_to                       => {'message', WaitAt},
                                heartbeat_freq                  => 10000,
                                requests_allowed_in_period      => Requests_allowed_in_period,
                                requests_allowed_by_api         => Requests_allowed_by_api
                            }
                        ),
                        [?TESTMODULE:get_async(Server,lists:append(["/?query=",integer_to_list(QueryParam)]), [], #{priority => 'low'}) || _A <- lists:seq(1,SendReq)],
                        timer:sleep(20),
                        Tasks = ets:tab2list(ETSTable),
                        ?assertEqual(SendReq, length(Tasks)),
                        Tst = ets:select(ETSTable,[{#wp_api_tasks{status = 'new', priority = 'low',max_retry = '$2',retry_count = '$1', _ = '_'},[{'<','$1',10},{'<','$1','$2'}],['$_']}]),
                        ?assertEqual(SendReq, length(Tst)),
                         Server ! 'heartbeat',
                        timer:sleep(50),
                        Tst2 = ets:select(ETSTable,[{#wp_api_tasks{status = 'new', priority = 'low',max_retry = '$2',retry_count = '$1', _ = '_'},[{'<','$1',10},{'<','$1','$2'}],['$_']}]),
                        ?assertEqual(SendReq, length(Tst2)+Requests_allowed_by_api),

                        [Acc] = tutils:recieve_loop([], ?RecieveLoop, WaitAt),
                        ?TESTMODULE:stop(Server),
                        ?assertEqual(Requests_allowed_by_api, length(Acc)),
                        FF = hd(Acc),
                        FirstPid = maps:get(pid, binary_to_term(maps:get(resp_body, FF))),
                        lists:map(fun(#{resp_body := DataFrame}) ->
                            Data = binary_to_term(DataFrame),
                            ?assertEqual(#{'query' => MQParam}, cowboy_req:match_qs([{'query', [], 'undefined'}], Data)),
                            ?assertEqual(FirstPid, maps:get(pid, Data))
                        end, Acc)
                end}
            ]
        }
    }.

tests_with_gun_and_slowcowboy_test_() ->
    {setup,
        % setup
        fun() ->
            ToStop = tutils:setup_start([{'apps',[ranch,cowboy,crypto,asn1,public_key,ssl,cowlib,gun]}]),
            CowboyRanchRef = start_cowboy(?RanchOpts),
            ok = warm_up(),
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
                        Server = tutils:random_atom(),
                        Max_paralell_requests_per_conn = 2,
                        TimerForCowboy = 20,
                        ETSTable = woodpecker:generate_ets_name(?TESTHOST, ?REGISTERAS(Server)),
                        ?TESTMODULE:start_link(
                            ?TESTHOST,
                            ?TESTPORT,
                            #{
                                register                        => ?REGISTERAS(Server),
                                report_to                       => {'message', WaitAt},
                                heartbeat_freq                  => 10000,
                                max_paralell_requests_per_conn  => Max_paralell_requests_per_conn
                            }
                        ),
                        [?TESTMODULE:get_async(Server,lists:append(["/?query=",integer_to_list(QueryParam),"&wait=",integer_to_list(TimerForCowboy)])) || _A <- lists:seq(1,20)],
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
                        FirstPid = maps:get(pid, binary_to_term(maps:get(resp_body, FF))),
                        lists:map(fun(#{resp_body := DataFrame}) ->
                            Data = binary_to_term(DataFrame),
                            ?assertEqual(#{'query' => MQParam}, cowboy_req:match_qs([{'query', [], 'undefined'}], Data)),
                            ?assertEqual(FirstPid, maps:get(pid, Data))
                        end, Acc)
                end}
            ]
        }
    }.


nodupes_priority_test_() ->
    {setup,
        fun() ->
            ToStop = tutils:setup_start([{'apps',[ranch,cowboy,crypto,asn1,public_key,ssl,cowlib,gun]}]),
            CowboyRanchRef = start_cowboy(?RanchOpts),
            ok = warm_up(),
            [{'tostop', ToStop}, {'ranch_ref', CowboyRanchRef}]
        end,
        fun([{'tostop', ToStop},{'ranch_ref', CowboyRanchRef}]) ->
            cowboy:stop_listener(CowboyRanchRef),
            tutils:cleanup_stop(ToStop)
        end,
        {foreach, fun start_quiet_server/0, fun stop_quiet_server/1, [
            fun({Server, Ets, Inbox}) ->
                {<<"a higher-priority duplicate raises a queued task and sends it at once">>, fun() ->
                    Group = make_ref(),
                    ?TESTMODULE:get_async(Server, "/?query=q", [], #{priority => 'low', nodupes_group => Group}),
                    ?assertMatch([#wp_api_tasks{priority = 'low', status = 'new'}], settled_tasks(Server, Ets)),
                    ?TESTMODULE:get_async(Server, "/?query=q", [], #{priority => 'high', nodupes_group => Group}),
                    ?assertEqual(1, length(responses(Inbox, 1, 2000))),
                    ?assertMatch([#wp_api_tasks{priority = 'high', status = 'got_fin_data'}], settled_tasks(Server, Ets))
                end}
            end,
            fun({Server, Ets, Inbox}) ->
                {<<"a duplicate of lower or equal priority leaves a queued task as it was">>, fun() ->
                    Group = make_ref(),
                    ?TESTMODULE:get_async(Server, "/?query=q", [], #{priority => 'normal', nodupes_group => Group}),
                    ?TESTMODULE:get_async(Server, "/?query=q", [], #{priority => 'low', nodupes_group => Group}),
                    ?TESTMODULE:get_async(Server, "/?query=q", [], #{priority => 'normal', nodupes_group => Group}),
                    ?assertMatch([#wp_api_tasks{priority = 'normal', status = 'new'}], settled_tasks(Server, Ets))
                end}
            end,
            fun({Server, Ets, Inbox}) ->
                {<<"a higher-priority duplicate of a task already sent is queued behind it">>, fun() ->
                    Group = make_ref(),
                    ?TESTMODULE:get_async(Server, "/?query=slow&wait=400", [], #{priority => 'normal', nodupes_group => Group}),
                    Server ! 'heartbeat',
                    ?assertMatch([#wp_api_tasks{status = 'processing'}], settled_tasks(Server, Ets)),
                    ?TESTMODULE:get_async(Server, "/?query=fresh", [], #{priority => 'high', nodupes_group => Group}),
                    ?assertEqual(2, length(settled_tasks(Server, Ets))),
                    ?assertEqual([<<"fresh">>, <<"slow">>], lists:sort([query_of(R) || R <- responses(Inbox, 2, 3000)]))
                end}
            end,
            fun({Server, Ets, Inbox}) ->
                {<<"a duplicate of no higher priority than the task already sent is dropped">>, fun() ->
                    Group = make_ref(),
                    ?TESTMODULE:get_async(Server, "/?query=slow&wait=400", [], #{priority => 'high', nodupes_group => Group}),
                    ?assertMatch([#wp_api_tasks{status = 'processing'}], settled_tasks(Server, Ets)),
                    ?TESTMODULE:get_async(Server, "/?query=again", [], #{priority => 'high', nodupes_group => Group}),
                    ?TESTMODULE:get_async(Server, "/?query=again", [], #{priority => 'low', nodupes_group => Group}),
                    ?assertEqual(1, length(settled_tasks(Server, Ets))),
                    ?assertEqual([<<"slow">>], [query_of(R) || R <- responses(Inbox, 2, 1500)])
                end}
            end
        ]}
    }.

budget_test_() ->
    {setup,
        fun() ->
            ToStop = tutils:setup_start([{'apps',[ranch,cowboy,crypto,asn1,public_key,ssl,cowlib,gun]}]),
            CowboyRanchRef = start_cowboy(?RanchOpts),
            ok = warm_up(),
            [{'tostop', ToStop}, {'ranch_ref', CowboyRanchRef}]
        end,
        fun([{'tostop', ToStop},{'ranch_ref', CowboyRanchRef}]) ->
            cowboy:stop_listener(CowboyRanchRef),
            tutils:cleanup_stop(ToStop)
        end,
        [
            {foreach, fun() -> start_quiet_server(#{budget_allowed_by_api => 500, budget_allowed_in_period => 60000}) end,
                fun stop_quiet_server/1, [
                fun({Server, Ets, _Inbox}) ->
                    {<<"high requests go at once while they fit the budget; the rest wait queued">>, fun() ->
                        [ask(Server, N, 'high', 250) || N <- lists:seq(1, 3)],
                        ?assertEqual([sent, sent, queued], states(Server, Ets))
                    end}
                end,
                fun({Server, Ets, _Inbox}) ->
                    {<<"the heartbeat sends a request of any priority only if it fits the budget">>, fun() ->
                        ask(Server, 1, 'normal', 250),
                        ask(Server, 2, 'low', 250),
                        ask(Server, 3, 'low', 250),
                        Server ! 'heartbeat',
                        ?assertEqual([sent, sent, queued], states(Server, Ets))
                    end}
                end,
                fun({Server, Ets, _Inbox}) ->
                    {<<"a request that does not fit holds back cheaper ones queued behind it">>, fun() ->
                        ask(Server, 1, 'high', 300),
                        ask(Server, 2, 'normal', 250),
                        ask(Server, 3, 'low', 1),
                        Server ! 'heartbeat',
                        ?assertEqual([sent, queued, queued], states(Server, Ets))
                    end}
                end,
                fun({Server, Ets, _Inbox}) ->
                    {<<"urgent requests do not wait for the budget, as they do not wait for the request quota">>, fun() ->
                        ask(Server, 1, 'high', 500),
                        ask(Server, 2, 'urgent', 250),
                        ?assertEqual([sent, sent], states(Server, Ets))
                    end}
                end
            ]},
            {foreach, fun() -> start_quiet_server(#{budget_allowed_by_api => 3}) end,
                fun stop_quiet_server/1, [
                fun({Server, Ets, _Inbox}) ->
                    {<<"a request that supplies no budget spends 1">>, fun() ->
                        [?TESTMODULE:get_async(Server, "/?query=q" ++ integer_to_list(N), [], #{priority => 'high'}) || N <- lists:seq(1, 4)],
                        ?assertEqual([sent, sent, sent, queued], states(Server, Ets))
                    end}
                end
            ]},
            {foreach, fun() -> start_quiet_server(#{budget_allowed_by_api => 250, budget_allowed_in_period => 300}) end,
                fun stop_quiet_server/1, [
                fun({Server, Ets, _Inbox}) ->
                    {<<"the budget comes back once its period has passed">>, fun() ->
                        ask(Server, 1, 'high', 250),
                        ask(Server, 2, 'high', 250),
                        ?assertEqual([sent, queued], states(Server, Ets)),
                        timer:sleep(350),
                        Server ! 'heartbeat',
                        ?assertEqual([sent, sent], states(Server, Ets))
                    end}
                end
            ]},
            {foreach, fun() -> start_quiet_server(#{}) end,
                fun stop_quiet_server/1, [
                fun({Server, Ets, _Inbox}) ->
                    {<<"without budget_allowed_by_api the budget is unlimited">>, fun() ->
                        [ask(Server, N, 'high', 100000) || N <- lists:seq(1, 3)],
                        ?assertEqual([sent, sent, sent], states(Server, Ets))
                    end}
                end
            ]}
        ]
    }.

ask(Server, N, Priority, Budget) ->
    ?TESTMODULE:get_async(Server, "/?query=q" ++ integer_to_list(N), [], #{priority => Priority, budget => Budget}).

states(Server, Ets) ->
    [case Status of 'new' -> queued; _ -> sent end
     || {_, Status} <- lists:sort([{U, St} || #wp_api_tasks{url = U, status = St} <- settled_tasks(Server, Ets)])].

start_quiet_server() -> start_quiet_server(#{}).

start_quiet_server(Options) ->
    Inbox = spawn(fun() -> inbox([]) end),
    Server = tutils:random_atom(),
    {ok, _} = ?TESTMODULE:start_link(?TESTHOST, ?TESTPORT, maps:merge(#{
        register => ?REGISTERAS(Server),
        report_to => {'message', Inbox},
        heartbeat_freq => 3600000
    }, Options)),
    {Server, woodpecker:generate_ets_name(?TESTHOST, ?REGISTERAS(Server)), Inbox}.

stop_quiet_server({Server, _Ets, Inbox}) ->
    ?TESTMODULE:stop(Server),
    exit(Inbox, kill),
    ok.

inbox(Acc) ->
    receive
        {read, Pid} -> Pid ! {inbox, lists:reverse(Acc)}, inbox(Acc);
        #{resp_body := _} = Resp -> inbox([Resp | Acc])
    end.

settled_tasks(Server, Ets) ->
    _ = sys:get_state(Server),
    ets:tab2list(Ets).

responses(Inbox, Max, Timeout) ->
    Inbox ! {read, self()},
    L = receive {inbox, Got} -> Got end,
    case length(L) >= Max orelse Timeout =< 0 of
        true -> L;
        false -> receive after 20 -> responses(Inbox, Max, Timeout - 20) end
    end.

query_of(#{resp_body := Body}) ->
    #{'query' := Query} = cowboy_req:match_qs([{'query', [], 'undefined'}], binary_to_term(Body)),
    Query.

% simple test
simple(get, Priority, NumberOfRequests) ->
    QueryParam = erlang:unique_integer([monotonic,positive]),
    MQParam = integer_to_binary(QueryParam),
    WaitAt = tutils:spawn_wait_loop_max(3,100),
    Server = tutils:random_atom(),
    ?TESTMODULE:start_link(
        ?TESTHOST,
        ?TESTPORT,
        #{
            register                        => ?REGISTERAS(Server),
            report_to                       => {'message', WaitAt},
            heartbeat_freq                  => 10
        }
    ),

    [?TESTMODULE:get_async(Server,lists:append(["/?query=",integer_to_list(QueryParam)]), [], #{priority => Priority}) || _A <- lists:seq(1,NumberOfRequests)],
    [Acc] = tutils:recieve_loop([], 220, WaitAt),
    ?assertEqual(NumberOfRequests, length(Acc)),
    FF = hd(Acc),
    FirstPid = maps:get(pid, binary_to_term(maps:get(resp_body, FF))),
    lists:map(fun(#{resp_body := DataFrame}) ->
        Data = binary_to_term(DataFrame),
        ?assertEqual(#{'query' => MQParam}, cowboy_req:match_qs([{'query', [], 'undefined'}], Data)),
        ?assertEqual(FirstPid, maps:get(pid, Data))
    end, Acc),
    ?TESTMODULE:stop(Server).


warm_up() ->
    _ = public_key:cacerts_get(),
    {ok, Pid} = gun:open(?TESTHOST, ?TESTPORT),
    {ok, _Protocol} = gun:await_up(Pid, 5000),
    StreamRef = gun:get(Pid, "/?query=warm_up"),
    {response, nofin, 200, _Headers} = gun:await(Pid, StreamRef, 5000),
    {ok, _Body} = gun:await_body(Pid, StreamRef, 5000),
    ok = gun:close(Pid).

start_cowboy(RanchOpts) ->
    Dispatch = cowboy_router:compile([
            {'_', [
                {"/", ?MODULE, []}
            ]}
        ]
    ),
    {ok, CowboyPid} = cowboy:start_clear(
        'http',
        RanchOpts,
        #{
            'env' => #{dispatch => Dispatch}
        }
    ), CowboyPid.

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
