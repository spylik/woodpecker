% this record for keep api-request task
-record(wp_api_tasks, {
		ref,
		status,
		priority,
		method,
		url,
		headers,
		body,
		insert_date,
		request_date,
		last_response_date,
		chunked_data,
		max_retry = 9999,
		retry_count = 0
	}).

-record(woodpecker_state, {
        % user specification section
        server,                                      % moderate: servername
        connect_to,                                  % moderate: server to connect
        connect_to_port,                             % moderate: server to connect (port)
        report_nofin_to,                             % send non-fin output frames to pid or erlroute (for realtime parsing)
        report_nofin_topic,                          % generated or predefined output non-fin topic
        report_to,                                   % send output frames to pid or erlroute
        report_topic,                                % generated or predefined output topic
        requests_allowed_by_api = 600,               % count of requests allowed by api per period
        requests_allowed_in_period = 600000,         % period (milli-seconds)
        timeout_for_processing_requests = 60000,     % timeout for requests with status "processing" (milli-seconds)
        timeout_for_nofin_requests = 180000,         % timeout for requests with status "nofin" (milli-seconds)
        degr_for_incomplete_requests = 1000,         % Degradation for incomplete requests (retry_count * this variable, milli-seconds)
        max_degr_for_incomplete_requests = 3600000,  % Max degradation for incomplete requests
        heartbeat_freq = 1000,                       % heartbeat frequency (in milliseconds)
        % woodpecker operations section
        ets,                                         % generated ets_name saved in state
        gun_pid,                                     % current gun connection Pid
        gun_ref,                                     % current gun monitor refference
        api_requests_quota,                          % current api requests quota
        heartbeat_tref                               % last heartbeat time refference
    }).

