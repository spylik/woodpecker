% this record for keep api-request task

-type status() :: 'new' | 'processing' |'got_gun_response' | 'got_nofin_data' | 'got_fin_data' | 'need_retry' | 'complete'.
-type priority() :: 'urgent' | 'high' | 'normal' | 'low'.
-type method() :: 'get' | 'post'.
-type mspec() :: '_' | '$1' | '$2' | '$3' | '$4' | '$5'.

-record(wp_api_tasks, {
		ref :: mspec() | reference(),
		status :: mspec() | status(),
		priority :: mspec() | priority(),
		method :: mspec() | method(),					% moderate
		url :: mspec() | nonempty_list(),               % moderate
		headers :: mspec(),
		body :: mspec(),
		insert_date :: mspec() | pos_integer(),
		request_date :: mspec() | pos_integer(),
		last_response_date :: mspec() | pos_integer(),
		chunked_data :: mspec() | binary(),
		max_retry = 9999 :: mspec() | non_neg_integer(),
		retry_count = 0 :: mspec() | non_neg_integer(),
		require_receipt :: mspec()
	}).

-record(woodpecker_frame, {
        data,
        recipe_pid,
        task = #wp_api_tasks{}
    }).

-record(woodpecker_state, {
        % user specification section
		server	:: atom(),                           					% moderate: servername
		connect_to	:: nonempty_list(),              					% moderate: server to connect
		connect_to_port :: pos_integer(),            					% moderate: server to connect (port)
		report_nofin_to :: 'undefined' | 'erlroute' | atom() | pid(),	% send non-fin output frames to pid or erlroute (for realtime parsing)
		report_nofin_topic :: binary(),             					% generated or predefined output non-fin topic
		report_to :: 'undefined' | 'erlroute' | atom() | pid(),         % send output frames to pid or erlroute
		report_topic :: binary(),                               		% generated or predefined output topic
		requests_allowed_by_api = 600 :: pos_integer(),					% count of requests allowed by api per period
		requests_allowed_in_period = 600000 :: pos_integer(),       	% period (milli-seconds)
		timeout_for_processing_requests = 60000 :: pos_integer(),    	% timeout for requests with status "processing" (milli-seconds)
		timeout_for_nofin_requests = 180000 :: pos_integer(),       	% timeout for requests with status "nofin" (milli-seconds)
		degr_for_incomplete_requests = 1000 :: pos_integer(),			% Degradation for incomplete requests (retry_count * this variable, milli-seconds)
		max_degr_for_incomplete_requests = 3600000 :: pos_integer(),	% Max degradation for incomplete requests
		heartbeat_freq = 1000 :: pos_integer(),                      	% heartbeat frequency (in milliseconds)
        % woodpecker operations section
		ets :: atom(),                                        			% generated ets_name saved in state
		gun_pid :: pid(),                       						% current gun connection Pid
		gun_ref :: reference(),											% current gun monitor refference
		api_requests_quota :: integer(),								% current api requests quota
		heartbeat_tref :: reference()									% last heartbeat time refference
    }).


