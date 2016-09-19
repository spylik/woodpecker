-module(woodpecker_tests).

-include_lib("eunit/include/eunit.hrl").
-include("woodpecker.hrl").

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
        {inorder,
            [
                {<<"able to send single request with high priority">>,
                    fun() ->
                        WaitAt = tutils:spawn_wait_loop_max(20),
                        ?TESTMODULE:start_link(#woodpecker_state{server = ?TESTSERVER, connect_to = ?TESTHOST, connect_to_port = ?TESTPORT}),
                        ?TESTMODULE:get(?TESTSERVER,"/",'high'),
                        Acc = tutils:recieve_loop([], 100, WaitAt),
                        ?debugVal(Acc),
                        ?TESTMODULE:stop(?TESTSERVER)

                end}
            ]
        }
    }.

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
    cowboy_req:reply(200, #{<<"content-type">> => <<"text/plain; charset=utf-8">>}, <<"ok">>, Req).
