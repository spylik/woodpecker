-module(woodpecker_tests).

-include_lib("eunit/include/eunit.hrl").
-include("woodpecker.hrl").

-define(TESTMODULE, woodpecker).
-define(TESTSERVER, test_wp_server).
-define(TESTHOST, "127.0.0.1").
-define(TESTPORT, 8080).

% --------------------------------- fixtures ----------------------------------

% tests for cover standart otp behaviour
otp_test_() ->
    {setup,
        fun simple_setup/0    % setup
        {inorder,
            [
                {<<"gen_server able to start via ?TESTSERVER:start_link(#woodpecker_state{})">>,
                    fun() ->
                        ?TESTSERVER:start_link(woodpecker#{server = test_wp_server}),
                        ?assertEqual(
                            true,
                            is_pid(whereis(?TESTSERVER))
                        )
                end},
                {<<"gen_server able to stop via ?TESTSERVER:stop()">>,
                    fun() ->
                        ?assertEqual(ok, ?TESTSERVER:stop(sync)),
                        ?assertEqual(
                            false,
                            is_pid(whereis(?TESTSERVER))
                        )
                end},
                {<<"gen_server able to start and stop via ?TESTSERVER:start_link() / ?TESTSERVER:stop(sync)">>,
                    fun() ->
                        ?TESTSERVER:start_link(),
                        ?assertEqual(ok, ?TESTSERVER:stop(sync)),
                        ?assertEqual(
                            false,
                            is_pid(whereis(?TESTSERVER))
                        )
                end},
                {<<"gen_server able to start and stop via ?TESTSERVER:start_link() / ?TESTSERVER:stop()">>,
                    fun() ->
                        ?TESTSERVER:start_link(),
                        ?assertEqual(ok, ?TESTSERVER:stop()),
                        ?assertEqual(
                            false,
                            is_pid(whereis(?TESTSERVER))
                        )
                end},
                {<<"gen_server able to start and stop via ?TESTSERVER:start_link() ?TESTSERVER:stop(async)">>,
                    fun() ->
                        ?TESTSERVER:start_link(),
                        ?TESTSERVER:stop(async),
                        timer:sleep(1), % for async cast
                        ?assertEqual(
                            false,
                            is_pid(whereis(?TESTSERVER))
                        )
                end}

            ]
        }
    }.


simple_setup() ->
    error_logger:tty(false),
%    {ok, Listen} = gen_tcp:listen(0, [Options]),
%    Port = inet:port(Listen),
%%    put(socket, Listen),
%    put(port, Port),
    ok

cleanup(_Data) -> ok.

start_server() -> application:ensure_started(?TESTSERVER).
