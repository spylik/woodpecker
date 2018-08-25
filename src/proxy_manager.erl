-module(proxy_manager).

% export public API
-export([start/0]).
-export([stop/0]).
-export([set_proxies/1]).
-export([list_proxies/0]).
-export([get_proxy/1]).
-export([ban_proxy/2]).
-export([unban_proxy/2]).
-export([banned_proxies/0]).
-export([banned_proxies/1]).

% gen_server is here
-behaviour(gen_server).

% gen_server standart api
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(REGNAME, ?MODULE).
-define(PROXIES_ETS, proxy_namager_proxies_ets).
-define(BANS_ETS, proxy_namager_bans_ets).

% =============================== specs and records =============================

-type proxy()               :: term().
-type netloc()              :: term().
-type get_proxy_result()    :: {'ok', proxy()} | {'error', 'no_proxies'}.
-type matchspec()           :: '_'.

-record(proxies, {
        proxy       :: proxy()
    }).

% we going to use tuple as a key because ets:lookup by key in set-type tables is much cheaper than ets:select by fields
-record(bans,   {
        ban_key     :: {netloc(), proxy()} | matchspec()
    }).

% keeping ets:tid()s in state instead of using macroses in calls because lookup by table id is a little-bit
% cheaper than by named table
-record(state,  {
        proxies_ets :: ets:tid(),
        bans_ets    :: ets:tid(),
        last_use    :: #{netloc() => proxy()} | #{}
    }).
-type state()       :: #state{}.

% format of messages accepting by gen_server
-type accepting_messages() ::   {'set_proxies', [proxy()]}
                            |   {'get_proxy', netloc()}
                            |   {'ban_proxy', proxy(), netloc()}
                            |   {'unban_proxy', proxy(), netloc()}.


% ------------------------- end of specs and records ----------------------------

% =============================== public api part ===============================

%% @doc
%% API for start the proxy_manager server
%% @end

-spec start() -> Result when
    Result  :: {'ok', Pid} | 'ignore' | {'error', Error},
    Pid     :: pid(),
    Error   :: {'already_started', Pid} | term().

start() ->
    gen_server:start_link({'local', ?REGNAME}, ?MODULE, [], []).

%% @doc
%% API for shutdown server gracefully
-spec stop() -> 'ok'.

stop() -> gen_server:stop(?REGNAME).

%% @doc
%% Initialize subsystem state with given proxies (sync operation both for caller and proxy_manager)
%% @end
-spec set_proxies([proxy()]) -> ok.

set_proxies(Proxies) ->
    gen_server:call(?REGNAME, {?FUNCTION_NAME, Proxies}).

%% @doc
%% List proxies or return a error in case if server down (sync for caller, but async for proxy_manager)
%%
%% @end
-spec list_proxies() -> [proxy()] | [].

list_proxies() ->
    [Proxy || #proxies{proxy = Proxy} <- ets:tab2list(?PROXIES_ETS)].

%% @doc
%% Return clean proxy for given netloc or error (sync operation both for caller and proxy_manager).
%% Due we need kind of round-robin for proxies per netloc, we need sync call here because we should
%% update state with the latest allocated proxy
%% @end
-spec get_proxy(netloc()) -> get_proxy_result().

get_proxy(Netloc) ->
    gen_server:call(?REGNAME, {?FUNCTION_NAME, Netloc}).

%% @doc
%% Ban proxy for netloc (sync operation both for caller and proxy_manager)
%% @end
-spec ban_proxy(proxy(), netloc()) -> ok.

ban_proxy(Proxy, Netloc) ->
    gen_server:call(?REGNAME, {?FUNCTION_NAME, Proxy, Netloc}).

%% @doc
%% Unban proxy for netloc (sync operation both for caller and proxy_manager)
%% @end
-spec unban_proxy(proxy(), netloc()) -> ok.

unban_proxy(Proxy, Netloc) ->
    gen_server:call(?REGNAME, {?FUNCTION_NAME, Proxy, Netloc}).

%% @doc
%% List banned proxies per netloc (sync for caller, but async for proxy_manager)
%% Perform direct lookup to the ets table without additional call to the gen_server
%% @end
-spec banned_proxies() -> [{netloc(), [proxy()]}] | [].

banned_proxies() ->
    maps:to_list(
        lists:foldl(
            fun(#bans{ban_key = {NetLoc, Proxy}}, Acc) ->
                maps:put(NetLoc, [Proxy | maps:get(NetLoc, Acc, [])], Acc)
            end,
            maps:new(),
            ets:tab2list(?BANS_ETS)
        )
    ).

%% @doc
%% List banned proxies for netloc (sync for caller, but async for proxy_manager)
%% @end
-spec banned_proxies(netloc()) -> [proxy()] | [].

banned_proxies(NetLoc) ->
    MS = [{#bans{ban_key = {NetLoc, '_'}}, [], ['$_']}],
    [Proxy || #bans{ban_key = {_NetLoc, Proxy}} <- ets:select(?BANS_ETS, MS)].

% ------------------------- end of public api part ------------------------------

% =============================== gen_server part ===============================

% @doc gen_server init. We going to create ETS tables here which we using for the

-spec init([]) -> Result when
    Result  :: {'ok', state()}.

init([]) ->
    {ok, #state{
        proxies_ets = ets:new(?PROXIES_ETS, ['ordered_set', 'protected', {keypos, #proxies.proxy}, named_table]),
        bans_ets = ets:new(?BANS_ETS, ['set', 'protected', {keypos, #bans.ban_key}, named_table]),
        last_use = maps:new()
    }}.

%============ handle_call ================

% @doc callbacks for gen_server handle_call.
-spec handle_call(Message, From, State) -> Result when
    Message :: accepting_messages(),
    From    :: {pid(), Tag},
    Tag     :: term(),
    State   :: state(),
    Result  :: {'reply', Result, state()}.

handle_call({'set_proxies', Proxies}, _From, #state{proxies_ets = Ets} = State) ->
    ets:insert(Ets, [#proxies{proxy = Proxy} || Proxy <- Proxies]),
    {'reply', 'ok', State};

handle_call({'get_proxy', NetLoc}, _From, #state{proxies_ets = ProxiesEts, bans_ets = BansEts, last_use = LastUseMap} = State) ->
    Proxy = get_proxy(NetLoc, maps:get(NetLoc, LastUseMap, 'undefined'), 'undefined', false, ProxiesEts, BansEts),
    {'reply', Proxy, may_update_last_used_in_state(Proxy, NetLoc, State)};

handle_call({'ban_proxy', Proxy, NetLoc}, _From, #state{proxies_ets = ProxiesEts, bans_ets = BansEts} = State) ->
    case ets:lookup(ProxiesEts, Proxy) of
        [] ->
            'no_proxies';
        ([#proxies{proxy = Proxy}]) ->
            ets:insert(BansEts, #bans{ban_key = ban_key(NetLoc, Proxy)})
    end,
    {'reply', 'ok', State};

handle_call({'unban_proxy', Proxy, NetLoc}, _From, #state{bans_ets = BansEts} = State) ->
    ets:delete(BansEts, ban_key(NetLoc, Proxy)),
    {'reply', 'ok', State};

handle_call(_Anoter, _From, State) ->
    {'reply', 'ok', State}.

%---------- end of handle_call------------

%% @doc Ingrore all casts now
handle_cast(_Msg, State) -> {'noreply', State}.

%% @doc Ignore all infos now
handle_info(_Msg, State) -> {'noreply', State}.

%% @doc Do nothing on terminate event
terminate(Reason, State) -> {'noreply', Reason, State}.

%% @doc Do nothing on code_change event
code_change(_OldVsn, State, _Extra) -> {'ok', State}.


% ------------------------- end of gen_server part ------------------------------

% ================================== internals ==================================

%% @doc Generate ban_key for ets table
-spec ban_key(netloc(), proxy()) -> {netloc(), proxy()}.

ban_key(NetLoc, Proxy) -> {NetLoc, Proxy}.

%% @doc get_proxy internal loop
%% In the state of gen_server we keeping the latest proxy which succesfully allocated to the certain netloc.
%% When we asking for the new proxy for certain netloc we traversing ordered_set ets table with list of proxies,
%% starting from the latest allocated proxy. We perform traverse till we find the next proxy which not yet banned,
%% then updating the state with new-one which allocated.

%% If we reach end_of_table we performing traverse only till the latest succesfully allocated proxy.
%% @end
-spec get_proxy(NetLoc, StartLookupFrom, CurrentProxyForCheck, EndOfTableFlag, ProxiesEts, BansEts) -> Result when
    NetLoc                  :: netloc(),
    StartLookupFrom         :: proxy() | 'undefined' | '$end_of_table',
    CurrentProxyForCheck    :: proxy() | 'undefined' | '$end_of_table',
    EndOfTableFlag          :: boolean(),
    ProxiesEts              :: ets:tid(),
    BansEts                 :: ets:tid(),
    Result                  :: get_proxy_result().

% case when we don't yet have previously allocated proxy
get_proxy(NetLoc, 'undefined', 'undefined', EndOfTableFlag, ProxiesEts, BansEts) ->
    FirstProxy = ets:first(ProxiesEts),
    get_proxy(NetLoc, FirstProxy, FirstProxy, EndOfTableFlag, ProxiesEts, BansEts);

% case when we have empty table with proxies
get_proxy(_NetLoc, '$end_of_table', _CurrentProxyForCheck, _EndOfTableFlag, _ProxiesEts, _BansEts) -> {'error', 'no_proxies'};

% when we reach end of table, we setting EndOfTableFlag to true and performing search from the beggining of table
get_proxy(NetLoc, StartLookupFrom, '$end_of_table', false, ProxiesEts, BansEts) ->
    get_proxy(NetLoc, StartLookupFrom, ets:first(ProxiesEts), true, ProxiesEts, BansEts);

% when we some initial proxy (not undefined) we going to look into the next proxy
get_proxy(NetLoc, StartLookupFrom, 'undefined', EndOfTableFlag, ProxiesEts, BansEts) ->
    get_proxy(NetLoc, StartLookupFrom, ets:next(ProxiesEts, StartLookupFrom), EndOfTableFlag, ProxiesEts, BansEts);

% when we have proxy for check, we going to check does it banned or not and if banned, looking into the next-one.
% When we reach last_allocated_proxy and in same time we already performed search from the begginning, we returning
% error
get_proxy(NetLoc, StartLookupFrom, CurrentProxyForCheck, EndOfTableFlag, ProxiesEts, BansEts) ->
    case ets:lookup(BansEts, ban_key(NetLoc, CurrentProxyForCheck)) of
        [] ->
            {'ok', CurrentProxyForCheck};
        _Banned when EndOfTableFlag == false orelse StartLookupFrom =/= CurrentProxyForCheck ->
            get_proxy(NetLoc, StartLookupFrom, ets:next(ProxiesEts, CurrentProxyForCheck), EndOfTableFlag, ProxiesEts, BansEts);
        _Banned ->
            {'error', 'no_proxies'}
    end.

%% @doc Update last_used in state only if we have proxy allocated
-spec may_update_last_used_in_state(get_proxy_result(), netloc(), state()) -> state().

may_update_last_used_in_state({'error', 'no_proxies'}, _NetLoc, State) -> State;
may_update_last_used_in_state({'ok', Proxy}, NetLoc, #state{last_use = LastUseMap} = State) ->
    State#state{last_use = maps:put(NetLoc, Proxy, LastUseMap)}.

% ---------------------------- end of internals ---------------------------------

