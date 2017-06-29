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
        retry_count = 0         :: non_neg_integer() | mspec()
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
        server  :: atom(),                                                  % moderate: servername
        connect_to  :: nonempty_list(),                                     % moderate: server to connect
        connect_to_port :: pos_integer(),                                   % moderate: server to connect (port)
        report_nofin_to :: 'undefined' | 'erlroute' | atom() | pid(),       % send non-fin output frames to pid or erlroute (for realtime parsing)
        report_nofin_topic :: 'undefined' | binary(),                       % generated or predefined output non-fin topic
        report_to :: 'undefined' | 'erlroute' | atom() | pid(),             % send output frames to pid or erlroute
        report_topic :: 'undefined' | binary(),                             % generated or predefined output topic
        requests_allowed_by_api = 600 :: pos_integer(),                     % count of requests allowed by api per period
        requests_allowed_in_period = 600000 :: pos_integer(),               % period (milli-seconds)
        max_connection_per_host = 1 :: pos_integer(),                       % maximum connection per host (for every conneciton it will spawn new gun)
        max_paralell_requests_per_conn = 8 :: pos_integer(),                % maximim paralell requests per connection
        max_total_req_per_conn = 'infinity' :: req_per_gun_quota(),         % max requests before we do gun:close.
        timeout_for_processing_requests = 20000 :: pos_integer(),           % timeout for requests with status "processing" (milli-seconds)
        timeout_for_got_gun_response_requests = 20000 :: pos_integer(),     % timeout for requests with status "got_gun_response" (milli-seconds)
        timeout_for_nofin_requests = 20000 :: pos_integer(),                % timeout for requests with status "nofin" (milli-seconds)
        freeze_for_incomplete_requests = 1000 :: pos_integer(),             % Freezing for incomplete requests (retry_count * this variable, milli-seconds)
        max_freeze_for_incomplete_requests = 3600000 :: pos_integer(),      % Max freeze timeout for incomplete requests
        heartbeat_freq = 1000 :: pos_integer(),                             % heartbeat frequency (in milliseconds)
        flush_completed_req = true :: boolean(),                            % flush data for completed requests?
        allow_dupes = true :: boolean(),                                    % do we allow dupes for incompleted requests? (same URL and same data)
        % woodpecker operations section
        ets :: atom() | 'undefined',                                        % generated ets_name saved in state
        current_gun_pid :: pid() | 'undefined',                             % current gun connection Pid
        gun_pids = #{} :: #{} | #{pid() => gun_pid_prop()},                 % gun_connection_pids and properties
        api_requests_quota :: integer() | 'undefined',                      % current api requests quota
        paralell_requests_quota :: integer() | 'undefined',                 % current max_paralell_requests
        heartbeat_tref :: reference() | 'undefined'                         % last heartbeat time refference

    }).
-type woodpecker_state() :: #woodpecker_state{}.
