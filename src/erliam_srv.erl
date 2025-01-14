%%% @copyright (C) 2017, AdRoll
%%% @doc
%%%
%%%    Server which creates and maintains an ets table containing aws credentials for use
%%%    by other processes.  Refreshes the credentials several seconds before
%%%    expiration (according to what's specified as credential_min_lifetime in the configuration).
%%%
%%% @end
%%% Created :  2 Jun 2017 by Mike Watters <mike.watters@adroll.com>
-module(erliam_srv).

-behaviour(gen_server).

-format #{inline_items => {when_over, 19}}.

%% API
-export([start_link/0, current/0, invalidate/0]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).
-define(TAB, ?MODULE).
-define(MIN_LIFETIME, erliam_config:g(credential_min_lifetime, 120)).

-include("erliam.hrl").

-record(state, {}).

-type state() :: #state{}.

%%%% API

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, noargs, []).

current() ->
    [Credentials] = ets:lookup(?TAB, credentials),
    Credentials.

invalidate() ->
    gen_server:call(?SERVER, invalidate).

%%%% CALLBACKS
-spec init(noargs) -> {ok, state()} | {stop, term()}.
init(noargs) ->
    ets:new(?TAB, [named_table, public, {read_concurrency, true}]),
    case update_credentials() of
        {error, Error} ->
            {stop, Error};
        ok ->
            timer:send_interval(1000, refresh),
            {ok, #state{}}
    end.

-spec handle_call(term(), _, state()) -> {reply, ok | {error, not_implemented}, state()}.
handle_call(invalidate, _From, State) ->
    update_credentials(),
    {reply, ok, State};
handle_call(_Request, _From, State) ->
    {reply, {error, not_implemented}, State}.

-spec handle_cast(_, state()) -> {noreply, state()}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(refresh | _, state()) -> {noreply, state()}.
handle_info(refresh, State) ->
    maybe_update_credentials(),
    {noreply, State};
handle_info(_, State) ->
    {noreply, State}.

-spec terminate(_, state()) -> ok.
terminate(_Reason, _State) ->
    ets:delete(?TAB),
    ok.

%%%% INTERNAL FUNCTIONS

maybe_update_credentials() ->
    case ets:lookup(?TAB, credentials) of
        [Credentials] ->
            MinLifetime = ?MIN_LIFETIME,
            case remaining_lifetime(Credentials) of
                N when N =< MinLifetime ->
                    update_credentials();
                _ ->
                    ok
            end;
        [] ->
            update_credentials()
    end.

update_credentials() ->
    case erliam:get_session_token() of
        #credentials{} = Credentials ->
            ets:insert(?TAB, Credentials),
            ok;
        Error ->
            error_logger:error_msg("failed to obtain session token: ~p", [Error]),
            Error
    end.

remaining_lifetime(#credentials{expiration = ExpTime}) ->
    Now = calendar:universal_time(),
    max(0,
        calendar:datetime_to_gregorian_seconds(parse_exptime(ExpTime))
        - calendar:datetime_to_gregorian_seconds(Now)).

parse_exptime([Y1, Y2, Y3, Y4, $-, Mon1, Mon2, $-, D1, D2, $T, H1, H2, $:, Min1, Min2, $:,
               S1, S2, $Z]) ->
    {{list_to_integer([Y1, Y2, Y3, Y4]),
      list_to_integer([Mon1, Mon2]),
      list_to_integer([D1, D2])},
     {list_to_integer([H1, H2]), list_to_integer([Min1, Min2]), list_to_integer([S1, S2])}};
parse_exptime([Y1, Y2, Y3, Y4, $-, Mon1, Mon2, $-, D1, D2, $T, H1, H2, $:, Min1, Min2, $:,
               S1, S2, $., _, _, _, $Z]) ->
    parse_exptime([Y1, Y2, Y3, Y4, $-, Mon1, Mon2, $-, D1, D2, $T, H1, H2, $:, Min1, Min2, $:,
                   S1, S2, $Z]).

%%%% TESTS
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

exptime_test() ->
    ?assertEqual({{2017, 6, 2}, {1, 2, 3}}, parse_exptime("2017-06-02T01:02:03Z")).

-endif.
