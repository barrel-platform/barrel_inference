%%% Owns the Cowboy listener and restarts it on death.
%%%
%%% cowboy:start_clear/3 (or start_tls/3) returns the pid of the
%%% ranch_listener_sup that Cowboy itself supervises. We monitor it
%%% so that if Cowboy crashes the listener under us, we trigger a
%%% restart from inside our own supervisor, rather than relying on
%%% Cowboy's internal restart strategy alone.
%%%
%%% The HTTP routes (dispatch table) live in routes/0 below.

-module(barrel_inference_server_listener_mon).
-behaviour(gen_server).

-export([start_link/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(LISTENER, barrel_inference_server_http).
-define(APP, barrel_inference_server).

-record(state, {
    listener_pid :: pid() | undefined,
    monitor :: reference() | undefined
}).

-opaque state() :: #state{}.
-export_type([state/0]).

%%====================================================================
%% Public API
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    process_flag(trap_exit, true),
    {ok, start_listener(#state{})}.

handle_call(_, _, S) -> {reply, {error, unknown_call}, S}.
handle_cast(_, S) -> {noreply, S}.

handle_info(
    {'DOWN', Mon, process, Pid, shutdown},
    S = #state{listener_pid = Pid, monitor = Mon}
) ->
    %% Normal shutdown path. The app is going down; do not restart.
    {noreply, S#state{listener_pid = undefined, monitor = undefined}};
handle_info(
    {'DOWN', Mon, process, Pid, Reason},
    S = #state{listener_pid = Pid, monitor = Mon}
) ->
    logger:warning("barrel_inference_server: cowboy listener died: ~p; restarting", [Reason]),
    catch cowboy:stop_listener(?LISTENER),
    {noreply, start_listener(S#state{listener_pid = undefined, monitor = undefined})};
handle_info(_, S) ->
    {noreply, S}.

terminate(_, _) ->
    catch cowboy:stop_listener(?LISTENER),
    ok.

%%====================================================================
%% Internal
%%====================================================================

start_listener(S) ->
    Port = app_env(port, 8080),
    Ip = app_env(ip, {0, 0, 0, 0}),
    Acceptors = app_env(num_acceptors, 100),
    BaseSocketOpts = [{port, Port}, {ip, Ip}],
    ProtocolOpts = #{
        env => #{dispatch => cowboy_router:compile(barrel_inference_server_routes:cowboy_routes())},
        middlewares => [
            barrel_inference_server_middleware,
            cowboy_router,
            cowboy_handler
        ],
        stream_handlers => [barrel_inference_server_access_log, cowboy_stream_h],
        %% Cowboy's default 60 s closes long fetches mid-resolve.
        idle_timeout => app_env(idle_timeout_ms, 1800000)
    },
    {ok, Pid} =
        case app_env(tls, undefined) of
            undefined ->
                cowboy:start_clear(
                    ?LISTENER,
                    #{
                        socket_opts => BaseSocketOpts,
                        num_acceptors => Acceptors
                    },
                    ProtocolOpts
                );
            TlsOpts when is_map(TlsOpts) ->
                cowboy:start_tls(
                    ?LISTENER,
                    #{
                        socket_opts => BaseSocketOpts ++ maps:to_list(TlsOpts),
                        num_acceptors => Acceptors
                    },
                    ProtocolOpts
                )
        end,
    Mon = monitor(process, Pid),
    S#state{listener_pid = Pid, monitor = Mon}.

app_env(Key, Default) ->
    application:get_env(?APP, Key, Default).
