% this record for keep api-request task

-type status() :: 'new' | 'processing' |'got_gun_response' | 'got_nofin_data' | 'got_fin_data' | 'need_retry' | 'complete'.
-type priority() :: 'urgent' | 'high' | 'normal' | 'low'.
-type method() :: 'get' | 'post'.
-type mspec() :: '_' | '$1' | '$2' | '$3' | '$4' | '$5'.

-record(wp_api_tasks, {
        ref                 :: reference() | mspec(),
        status              :: status() | mspec(),
        priority            :: priority() | mspec(),
        method              :: method() | mspec(),            % moderate
        url                 :: nonempty_list() | mspec(),     % moderate
        headers             :: mspec(),
        body                :: mspec(),
        insert_date         :: pos_integer() | mspec(),
        request_date        :: pos_integer() | mspec(),
        last_response_date  :: pos_integer() | mspec(),
        chunked_data        :: binary() | mspec(),
        max_retry = 9999    :: non_neg_integer() | mspec(),
        retry_count = 0     :: non_neg_integer() | mspec(),
        require_receipt     :: mspec()
    }).

-record(woodpecker_frame, {
        data,
        recipe_pid,
        task = #wp_api_tasks{}
    }).
-type woodpecker_frame() :: #woodpecker_frame{}.

-record(woodpecker_state, {
        % user specification section
        server  :: atom(),                                              % moderate: servername
        connect_to  :: nonempty_list(),                                 % moderate: server to connect
        connect_to_port :: pos_integer(),                               % moderate: server to connect (port)
        report_nofin_to :: 'undefined' | 'erlroute' | atom() | pid(),   % send non-fin output frames to pid or erlroute (for realtime parsing)
        report_nofin_topic :: 'undefined' | binary(),                   % generated or predefined output non-fin topic
        report_to :: 'undefined' | 'erlroute' | atom() | pid(),         % send output frames to pid or erlroute
        report_topic :: 'undefined' | binary(),                         % generated or predefined output topic
        requests_allowed_by_api = 600 :: pos_integer(),                 % count of requests allowed by api per period
        requests_allowed_in_period = 600000 :: pos_integer(),           % period (milli-seconds)
        timeout_for_processing_requests = 60000 :: pos_integer(),       % timeout for requests with status "processing" (milli-seconds)
        timeout_for_nofin_requests = 180000 :: pos_integer(),           % timeout for requests with status "nofin" (milli-seconds)
        degr_for_incomplete_requests = 1000 :: pos_integer(),           % Degradation for incomplete requests (retry_count * this variable, milli-seconds)
        max_degr_for_incomplete_requests = 3600000 :: pos_integer(),    % Max degradation for incomplete requests
        heartbeat_freq = 1000 :: pos_integer(),                         % heartbeat frequency (in milliseconds)
        % woodpecker operations section
        ets :: atom() | 'undefined',                                    % generated ets_name saved in state
        gun_pid :: pid() | 'undefined',                                 % current gun connection Pid
        gun_ref :: reference() | 'undefined',                                         % current gun monitor refference
        api_requests_quota :: integer() | 'undefined',                  % current api requests quota
        heartbeat_tref :: reference() | 'undefined'                     % last heartbeat time refference
    }).


