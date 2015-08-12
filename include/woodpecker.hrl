% this record for keep api-request task
-record(api_tasks, {
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
		max_retry,
		retry_count
	}).
