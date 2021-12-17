-module(nxtfr_autodiscovery).
-author("christian@flodihn.se").
-behaviour(gen_server).
            
-define(UDP_OPTIONS, [
    binary,
    %{header, 2},
    {reuseaddr, false}, 
    {broadcast, true},
    {active, true},
    {multicast_loop, false}
    ]).

-define(AUTODISCOVER_PORT, 65501).
-define(AUTODISCOVER_TICK_TIME, 10000).

%% External exports
-export([
    start_link/0,
    info/0,
    add_group/1,
    remove_group/1
    ]).

%% gen_server callbacks
-export([
    init/1, handle_call/3, handle_cast/2, handle_info/2, code_change/3, terminate/2
    ]).

%% Internal exports
-export([
    create_server_socket/0,
    broadcast/2,
    send_tick/0,
    get_interface/0
    ]).

%% server state
-record(state, {
    socket, 
    is_server,
    timer,
    interface,
    my_groups = [],
    node_groups = {}}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

info() ->
    gen_server:call(?MODULE, info).

add_group(Group) ->
    gen_server:call(?MODULE, {set_group, Group}).

remove_group(Group) ->
    gen_server:call(?MODULE, {remove_group, Group}).

init([]) ->
    application:start(nxtfr_event),
    nxtfr_event:add_handler(nxtfr_autodiscovery_event_handler),
    Interface = ?MODULE:get_interface(),
    Timer = ?MODULE:send_tick(),
    case ?MODULE:create_server_socket() of
        {ok, Socket} ->
            error_logger:info_msg({created_server, Socket}),
            State = #state{
                socket = Socket,
                is_server = true,
                timer = Timer,
                interface = Interface,
                node_groups = #{}},
            %?MODULE:broadcast(State),
            {ok, State};
        {error, eaddrinuse} ->
            {ok, Socket} = gen_udp:open(0, ?UDP_OPTIONS),
            error_logger:info_msg({created_client, Socket}),
            State = #state{
                socket = Socket,
                is_server = false,
                timer = Timer,
                interface = Interface,
                node_groups = #{}},
            %?MODULE:broadcast(State),
            {ok, State}
    end.

handle_call(info, _From, State) ->
    {reply, {ok, State}, State};

handle_call({set_group, Group}, _From, #state{my_groups = MyGroups} = State) ->
    case lists:member(Group, MyGroups) of
        true ->
            {reply, ok, State};
        false ->
            UpdatedMyGroups = lists:append([Group], MyGroups),
            {reply, ok, State#state{my_groups = UpdatedMyGroups}}
    end;

handle_call(Call, _From, State) ->
    error_logger:error_report([{undefined_call, Call}]),
    {reply, ok, State}.

handle_cast(Cast, State) ->
    error_logger:error_report([{undefined_cast, Cast}]),
    {noreply, State}.

handle_info(autodiscovery_tick, #state{is_server = true} = State) ->
    Timer = ?MODULE:send_tick(),
    %?MODULE:broadcast(State),
    {noreply, State#state{timer = Timer}};

handle_info(autodiscovery_tick, #state{is_server = false} = State) ->
    error_logger:info_msg({client, autodiscovery_tick}),
    Timer = ?MODULE:send_tick(),
    case create_server_socket() of
        {ok, Socket} ->
            NewState = State#state{socket = Socket, is_server = true, timer = Timer},
            %?MODULE:broadcast(NewState),
            {noreply, NewState#state{timer = Timer}};
        {error, eaddrinuse} ->
            %?MODULE:broadcast(State, <<"tick">>),
            {noreply, State#state{timer = Timer}}
    end;

handle_info({udp, Socket, FromIp, FromPort, Binary}, #state{is_server = false} = State) ->
    error_logger:info_msg({udp_received_on_client, Socket, FromIp, FromPort, Binary}),
    {noreply, State};

handle_info({udp, Socket, FromIp, FromPort, Binary}, #state{is_server = true} = State) ->
    error_logger:info_msg({udp_received_on_server, FromIp, Binary}),
    try binary_to_term(Binary) of
        broadcast ->
            send_term(Socket, FromIp, FromPort, ok);
        _ ->
            error_logger:error_report([{unknown_udp, Binary}])
    catch
        error:badarg ->
            error_logger:error_report([{bad_udp, Binary}]),
            send_term(Socket, FromIp, FromPort, <<"HelloFromServer">>)
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

broadcast(#state{socket = Socket, interface = Interface}, Term) ->
    case application:get_env(nxtfr_autodiscovery, broadcast_ip) of
        {ok, Ip} ->
            error_logger:info_report([{broadcasting, Ip}]),
            send_term(Socket, Ip, ?AUTODISCOVER_PORT, Term);
        undefined ->
            Interface = get_interface(),
            HeuristicIp = get_broadcast_ip(Interface),
            error_logger:info_report([{broadcasting, HeuristicIp}]),
            send_term(Socket, HeuristicIp, ?AUTODISCOVER_PORT, Term)
    end.

send_term(Socket, Ip, Port, Term) ->
    BinaryTerm = term_to_binary(Term),
    MessageSize = byte_size(BinaryTerm),
    Message = <<MessageSize:16/integer, BinaryTerm/binary>>,
    gen_udp:send(Socket, Ip, Port, Message).

get_broadcast_ip(Interface) ->
    {ok, IfList} = inet:getifaddrs(),
    {_, LoOpts} = proplists:lookup(Interface, IfList),
    proplists:lookup(broadaddr, LoOpts).

get_ip() ->
    case application:get_env(nxtfr_autodiscovery, ip) of
        undefined -> {0, 0, 0, 0};
        {ok, Ip} -> Ip
    end.

get_interface() ->
    case application:get_env(nxtfr_autodiscovery, interface) of
        undefined -> "eth0";
        {ok, Interface} -> Interface
    end.