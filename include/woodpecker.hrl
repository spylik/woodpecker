% Start options

-type start_opt() :: #{
        'register'
            => register_as(),
        'report_nofin_to'                       % send nofin result to
            => 'undefined' | report(),
        'report_to'                             % send complete result to
            => 'undefined' | report(),
        'requests_allowed_by_api'               % count of requests allowed by api per period
            => 600 | pos_integer(),
        'requests_allowed_in_period'            % period (milli-seconds)
            => 600000 | pos_integer(),
        'max_connections_per_host'              % TODO: maximum connection per host (for every conneciton it will spawn new gun)
            => 1 | pos_integer(),
        'max_paralell_requests_per_conn'        % maximim paralell requests per connection
            => 8 | pos_integer(),
        'max_total_req_per_conn'                % max requests before we do gun:close for connection
            => 'infinity' | req_per_gun_quota(),
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
        'cleanup_completed_requests'            % flush data for completed requests?
            => true | boolean()
    }.

-type request_opt() :: #{
    'priority'          => priority(),
    'tags'              => 'undefined' | tags(),
    'nodupes_group'     => 'undefined' | term()
}.

-type output()      :: #{
    'req_method'        => method(),
    'req_url'           => url(),
    'req_headers'       => headers(),
    'req_body'          => body(),
    'resp_headers'      => headers(),
    'resp_body'         => body(),
    'tags'              => tags()
}.

% TODO: report via spawning process.
-type report()          :: {'erlroute', binary()}
                         | {'message', pid() | atom()}.

-type def_arguments()   :: [].

-record(woodpecker_state, {
        % user specification section
        server                                  :: 'undefined' | atom() | {'via', module(), term()},
        remote_host                             :: remote_host(),
        remote_port                             :: remote_port(),
        report_nofin_to                         :: 'undefined' | report(),
        report_to                               :: 'undefined' | report(),
        requests_allowed_by_api                 :: 600 | pos_integer(),
        requests_allowed_in_period              :: 600000 | pos_integer(),
        max_connections_per_host                :: 1 | pos_integer(), % TODO (currently doesn't support)
        max_paralell_requests_per_conn          :: 8 | pos_integer(),  % this one mostly for http2 which allowing multiple requests in same connection
        max_total_req_per_conn                  :: 'infinity' | req_per_gun_quota(),
        timeout_for_processing_requests         :: 20000 | pos_integer(),
        timeout_for_got_gun_response_requests   :: 20000 | pos_integer(),
        timeout_for_nofin_requests              :: 20000 | pos_integer(),
        freeze_for_incomplete_requests          :: 1000 | pos_integer(),
        max_freeze_for_incomplete_requests      :: 3600000 | pos_integer(), % 3600000 is 1 hour
        heartbeat_freq                          :: 1000 | pos_integer(),
        cleanup_completed_requests              :: 'true' | boolean(),
        % woodpecker operations section
        ets                                     :: atom(),
        api_requests_current_quota              :: integer(),
        paralell_requests_current_quota         :: integer(),
        heartbeat_tref                          :: reference(),
        current_gun_pid                         :: pid() | 'undefined',
        gun_pids = #{}                          :: #{} | #{pid() => gun_pid_prop()}
    }).
-type woodpecker_state() :: #woodpecker_state{}.

% this record for keep api-request task
-type register_as() :: {'local', atom()} | {'global', term()}.
-type status()      :: 'new' | 'processing' |'got_gun_response' | 'got_nofin_data' | 'got_fin_data' | 'need_retry'.
-type priority()    :: 'urgent' | 'high' | 'normal' | 'low'.
-type method()      :: binary(). % <<"POST">> | <<"GET">>
-type mspec()       :: '_' | '$1' | '$2' | '$3' | '$4' | '$5'.
-type remote_host() :: nonempty_list().
-type remote_port() :: pos_integer().
-type server()      :: pid() | atom().
-type url()         :: nonempty_list().
-type tags()        :: term().
-type body()        :: 'undefined' | binary().
-type isFin()       :: 'fin' | 'nofin'.
-type stage()       :: 'order_stage' | 'cast_stage'.
-type newtaskmsg()  :: {'create_task', method(), priority(), url(), headers(), iodata()}.
-type headers()     :: [] | cow_http:headers().
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
        max_retry = 9999        :: non_neg_integer() | mspec(),
        retry_count = 0         :: non_neg_integer() | mspec(),
        nodupes_group           :: 'undefined' | term(),
        insert_date             :: pos_integer() | mspec(),
        report_nofin_to         :: 'undefined' | report() | mspec(),
        report_to               :: 'undefined' | report() | mspec(),
        method                  :: method() | mspec(),
        url                     :: url() | mspec(),
        headers = []            :: headers() | mspec(),
        body                    :: body() | mspec(),
        tags                    :: tags(),
        request_date            :: 'undefined' | pos_integer() | mspec(),
        last_response_date      :: 'undefined' | pos_integer() | mspec(),
        response_headers        :: 'undefined' | headers() | mspec(),
        data                    :: 'undefined' | binary() | mspec()
    }).
-type wp_api_tasks() :: #wp_api_tasks{}.
-type req_per_gun_quota() :: 'infinity' | non_neg_integer().

-record(gun_pid_prop, {
        gun_mon :: 'undefined' | reference(),
        req_per_gun_quota = 'infinity' :: req_per_gun_quota()
    }).
-type gun_pid_prop() :: #gun_pid_prop{}.



