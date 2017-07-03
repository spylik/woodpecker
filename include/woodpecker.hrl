% Start options

-type start_opt() :: #{
        'register'
            => register_as(),
        'connect_to'
            => nonempty_list(),
        'connect_to_port'
            => pos_integer(),
        'report_nofin_to'                       % send nofin result to
            => 'undefined' | report(),
        'report_to'                             % send complete result to
            => 'undefined' | report(),
        'requests_allowed_by_api'               % count of requests allowed by api per period
            => 600 | pos_integer(),
        'requests_allowed_in_period'            % period (milli-seconds)
            => 600000 | pos_integer(),
        'max_connection_per_host'               % maximum connection per host (for every conneciton it will spawn new gun)
            => 1 | pos_integer(),
        'max_paralell_requests_per_conn'        % maximim paralell requests per connection
            => 8 | pos_integer(),
        'max_total_req_per_conn'                % max requests before we do gun:close
            => 'infinity' :: req_per_gun_quota(),
        'timeout_for_processing_requests'       % timeout for requests with status "processing" (milli-seconds)
            => 20000 | pos_integer(),
        'timeout_for_got_gun_response_requests' % timeout for requests with status "got_gun_response" (milli-seconds)
            => 20000 | pos_integer(),
        'timeout_for_nofin_requests'            % timeout for requests with status "nofin" (milli-seconds)
            => 20000 | pos_integer(),
        'freeze_for_incomplete_requests'        % Freezing for incomplete requests (retry_count * this variable, milli-seconds)
            => 1000 | pos_integer(),
        'max_freeze_for_incomplete_requests'    % Max freeze timeout for incomplete requests
            => 3600000 | pos_integer(),
        'heartbeat_freq'                        % heartbeat frequency (in milliseconds)
            => 1000 | pos_integer(),
        'flush_completed_req'                   % flush data for completed requests?
            => true | boolean(),
        'allow_dupes'                           % do we allow dupes for incompleted requests? (same URL, same headers, same data)
            => true | boolean()
    }.

% this record for keep api-request task
-type status()      :: 'new' | 'processing' |'got_gun_response' | 'got_nofin_data' | 'got_fin_data' | 'need_retry'.
-type priority()    :: 'urgent' | 'high' | 'normal' | 'low'.
-type method()      :: binary(). % <<"POST">> | <<"GET">>
-type mspec()       :: '_' | '$1' | '$2' | '$3' | '$4' | '$5'.
-type server()      :: pid() | atom().
-type url()         :: nonempty_list().
-type tags()        :: term().
-type body()        :: 'undefined' | binary().
-type isFin()       :: 'fin' | 'nofin'.
-type stage()       :: 'order_stage' | 'cast_stage'.
-type newtaskmsg()  :: {'create_task', method(), priority(), url(), headers(), iodata()}.
-type headers()     :: [] | [{binary(), iodata()}].
-type httpstatus()  :: 100..999.
-type stream_ref()  :: reference().
-type gun_pid()     :: pid().
-type mon_ref()     :: reference().

-type gun_response()    :: {'gun_response', gun_pid(), stream_ref(), isFin(), httpstatus(), headers()}.
-type gun_data()        :: {'gun_data', gun_pid(), stream_ref(), isFin(), binary()}.
-type gun_push()        :: {'gun_push', gun_pid(), stream_ref(), stream_ref(), method(), nonempty_list(), nonempty_list(), headers()}.
-type gun_error()       :: {'gun_error', gun_pid(), stream_ref(), term()} | {'gun_error', gun_pid(), term()}.
-type down()            :: {'DOWN', mon_ref(), 'process', stream_ref(), term()}.

-type report()          :: {'erlroute', binary()} | pid() | atom().

-type report_to_opt     :: 'default' |
    #{
        report_nofin_to     => report(),       % send non-fin output frames to pid or erlroute (for realtime parsing)
        report_to           => report()        % send output frames to pid or erlroute
    }.

-record(wp_api_tasks, {
        ref                     :: reference() | {'temp',reference()} | mspec(),
        status = 'new'          :: status() | mspec(),
        priority = 'low'        :: priority() | mspec(),
        method                  :: method() | mspec(),            % moderate
        url                     :: url() | mspec(),     % moderate
        headers = []            :: headers() | mspec(),
        body                    :: body() | mspec(),
        tags                    :: tags(),
        insert_date             :: pos_integer() | mspec(),
        request_date            :: 'undefined' | pos_integer() | mspec(),
        last_response_date      :: 'undefined' | pos_integer() | mspec(),
        response_headers        :: 'undefined' | headers() | mspec(),
        data                    :: 'undefined' | binary() | mspec(),
        max_retry = 9999        :: non_neg_integer() | mspec(),
        retry_count = 0         :: non_neg_integer() | mspec(),
        report_nofin_to         :: 'undefined' | report(),
        report_to               :: 'undefined' | report()
    }).
-type wp_api_tasks() :: #wp_api_tasks{}.
-type req_per_gun_quota() :: 'infinity' | non_neg_integer().

-record(gun_pid_prop, {
        gun_mon :: 'undefined' | reference(),
        req_per_gun_quota = 'infinity' :: req_per_gun_quota()
    }).
-type gun_pid_prop() :: #gun_pid_prop{}.


-record(woodpecker_state, {
        % user specification section
        server                                  :: atom(),
        connect_to                              :: nonempty_list(),
        connect_to_port                         :: pos_integer(),
        report_nofin_to                         :: report_nofin_to(),
        report_to                               :: report_to(),
        requests_allowed_by_api                 :: pos_integer(),
        requests_allowed_in_period              :: pos_integer(),
        max_connection_per_host                 :: pos_integer(),
        max_paralell_requests_per_conn          :: pos_integer(),
        max_total_req_per_conn                  :: req_per_gun_quota(),
        timeout_for_processing_requests         :: pos_integer(),
        timeout_for_got_gun_response_requests   :: pos_integer(),
        timeout_for_nofin_requests              :: pos_integer(),
        freeze_for_incomplete_requests          :: pos_integer(),
        max_freeze_for_incomplete_requests      :: pos_integer(),
        heartbeat_freq                          :: pos_integer(),
        flush_completed_req                     :: boolean(),
        allow_dupes                             :: boolean(),
        % woodpecker operations section
        ets                                     :: atom() | 'undefined',
        current_gun_pid                         :: pid() | 'undefined',
        gun_pids                                :: #{} | #{pid() => gun_pid_prop()},
        api_requests_quota                      :: integer() | 'undefined',
        paralell_requests_quota                 :: integer() | 'undefined',
        heartbeat_tref                          :: reference() | 'undefined'
    }).
-type woodpecker_state() :: #woodpecker_state{}.
