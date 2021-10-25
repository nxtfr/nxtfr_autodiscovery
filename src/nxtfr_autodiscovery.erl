-module(nxtfr_autodiscovery).
-author("christian@flodihn.se").
-behaviour(gen_server).
            
-define(UDP_OPTIONS, [binary, {broadcast, true}, {active, true}]).
-define(AUTODISCOVER_PORT, 65535).
-define(AUTODISCOVER_TICK_TIME, 10000).

%% External exports
-export([
    start_link/0
    ]).

%% gen_server callbacks
-export([
    init/1, handle_call/3, handle_cast/2, handle_info/2, code_change/3, terminate/2
    ]).

%% Internal exports
-export([
    create_server_socket/0,
    broadcast/1,
    send_tick/0,
    get_interface/0
    ]).

%% server state
-record(state, {socket, is_server, timer, interface, node_groups}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    Interface = ?MODULE:get_interface(),
    Timer = ?MODULE:send_tick(),
    case ?MODULE:create_server_socket() of
        {ok, Socket} ->
            State = #state{
                socket = Socket,
                is_server = true,
                timer = Timer,
                interface = Interface,
                node_groups = #{}},
            ?MODULE:broadcast(State),
            {ok, State};
        {error, eaddrinuse} ->
            {ok, Socket} = gen_udp:open(0, ?UDP_OPTIONS),
            State = #state{
                socket = Socket,
                is_server = false,
                timer = Timer,
                interface = Interface,
                node_groups = #{}},
            ?MODULE:broadcast(State),
            {ok, State}
    end.

handle_call(Call, _From, State) ->
    error_logger:error_report([{undefined_call, Call}]),
    {reply, ok, State}.

handle_cast(Cast, State) ->
    error_logger:error_report([{undefined_cast, Cast}]),
    {noreply, State}.

handle_info(autodiscovery_tick, #state{is_server = true} = State) ->
    Timer = ?MODULE:send_tick(),
    ?MODULE:broadcast(State),
    {noreply, State#state{timer = Timer}};

handle_info(autodiscovery_tick, #state{is_server = false} = State) ->
    Timer = ?MODULE:send_tick(),
    case create_server_socket() of
        {ok, Socket} ->
            NewState = State#state{socket = Socket, is_server = true, timer = Timer},
            ?MODULE:broadcast(NewState),
            {noreply, NewState};
        {error, eaddrinuse} ->
            ?MODULE:broadcast(State),
            {noreply, State#state{timer = Timer}}
    end;

handle_info({udp, Socket, FromIp, FromPort, Binary}, #state{socket = Socket} = State) ->
    try binary_to_term(Binary) of
        broadcast ->
            gen_udp:send(Socket, FromIp, FromPort, <<"ok">>);
        _ ->
            error_logger:error_report([{unknown_udp, Binary}])
    catch
        error:badarg ->
            error_logger:error_report([{bad_udp, Binary}])
    end,
    {noreply, State};

handle_info(Info, State) ->
    error_logger:error_report([{undefined_info, Info}]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

send_tick() ->
    erlang:send_after(?AUTODISCOVER_TICK_TIME, self(), autodiscovery_tick).

create_server_socket() ->
    gen_udp:open(?AUTODISCOVER_PORT, ?UDP_OPTIONS).

broadcast(#state{socket = Socket, interface = Interface}) ->
    case application:get_env(nxtfr_autodiscovery, broadcast_ip) of
        {ok, Ip} ->
            error_logger:info_report([{broadcasting, Ip}]),
            gen_udp:send(Socket, Ip, ?AUTODISCOVER_PORT, term_to_binary(broadcast));
        undefined ->
            Interface = get_interface(),
            HeuristicIp = get_broadcast_ip(Interface),
            error_logger:info_report([{broadcasting, HeuristicIp}]),
            gen_udp:send(Socket, HeuristicIp, ?AUTODISCOVER_PORT, term_to_binary(broadcast))
    end.

get_broadcast_ip(Interface) ->
    {ok, IfList} = inet:getifaddrs(),
    {_, LoOpts} = proplists:lookup(Interface, IfList),
    proplists:lookup(broadaddr, LoOpts).

get_interface() ->
    case application:get_env(nxtfr_autodiscovery, interface) of
        undefined -> "eth0";
        {ok, Interface} -> Interface
    end.