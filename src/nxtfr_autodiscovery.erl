-module(nxtfr_autodiscovery).
-author("christian@flodihn.se").
-behaviour(gen_server).
            
-define(UDP_OPTIONS, [
    binary,
    {reuseaddr, false}, 
    {broadcast, true},
    {active, true},
    {multicast_loop, false}
    ]).

-define(AUTODISCOVER_PORT, 65501).
-define(AUTODISCOVER_TICK_TIME, 10000).

%% Tmp exports during development
-export([
    dev1/0, dev2/0
    ]).

%% External exports
-export([
    start_link/0,
    info/0,
    add_group/1,
    remove_group/1,
    sync_group/3
    ]).

%% gen_server callbacks
-export([
    init/1, handle_call/3, handle_cast/2, handle_info/2, code_change/3, terminate/2
    ]).

%% Internal exports
-export([
    create_server_socket/1,
    multicast/2,
    send_tick/0,
    get_interface/0
    ]).

%% server state
-record(state, {
    socket, 
    is_server,
    timer,
    interface,
    ip,
    multicast_ip,
    my_groups = [],
    local_nodes = [],
    node_groups = {}}).

dev1() ->
    application:start(nxtfr_autodiscovery),
    nxtfr_event:notify({add_autodiscovery_group, client1}).

dev2() ->
    application:start(nxtfr_autodiscovery),
    nxtfr_event:notify({add_autodiscovery_group, client2}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

info() ->
    gen_server:call(?MODULE, info).

add_group(Group) ->
    gen_server:call(?MODULE, {add_group, Group}).

remove_group(Group) ->
    gen_server:call(?MODULE, {remove_group, Group}).

%% Operation [add | remove]
sync_group(Group, Node, Operation) ->
    gen_server:call(?MODULE, {sync_group, Group, Node, Operation}).

init([]) ->
    application:start(nxtfr_event),
    nxtfr_event:add_handler(nxtfr_autodiscovery_event_handler),
    Interface = ?MODULE:get_interface(),
    Timer = ?MODULE:send_tick(),
    {Ip, MulticastIp} = get_ip_and_multicast(Interface),
    case ?MODULE:create_server_socket(Ip) of
        {ok, Socket} ->
            error_logger:info_msg({created_server, Socket}),
            State = #state{
                socket = Socket,
                is_server = true,
                timer = Timer,
                interface = Interface,
                ip = Ip,
                multicast_ip = MulticastIp,
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
                ip = Ip,
                multicast_ip = MulticastIp,
                node_groups = #{}},
            %?MODULE:multicast(State),
            {ok, State}
    end.

handle_call(info, _From, State) ->
    {reply, {ok, State}, State};

handle_call({add_group, Group}, _From, #state{my_groups = MyGroups} = State) ->
    case lists:member(Group, MyGroups) of
        true ->
            {reply, ok, State};
        false ->
            UpdatedMyGroups = lists:append([Group], MyGroups),
            multicast_add_group(Group, State), TODO - what to do here, make server rpc call local nodes and send multicast?
            {reply, ok, State#state{my_groups = UpdatedMyGroups}}
    end;

handle_call({remove_group, Group}, _From, #state{my_groups = MyGroups} = State) ->
    UpdatedMyGroups = lists:delete(Group, MyGroups),
    {reply, ok, State#state{my_groups = UpdatedMyGroups}};

handle_call({sync_group, Group, Node, Operation},
        _From,
        #state{node_groups = NodeGroups} = State) ->
    Nodes = maps:get(Group, NodeGroups, []),
    case {Operation, lists:member(Node, Nodes)} of
        {add, true} ->
            {reply, ok, State};
        {add, false} ->
            UpdatedNodeGroups = maps:put(Group, lists:append([Node], Nodes), NodeGroups),
            {reply, ok, State#state{node_groups = UpdatedNodeGroups}};
        {remove, true} ->
            UpdatedNodeGroups = maps:put(Group, lists:delete(Node, Nodes), NodeGroups),
            {reply, ok, State#state{node_groups = UpdatedNodeGroups}};
        {remove, false} ->
            {reply, ok, State}
    end;

handle_call(Call, _From, State) ->
    error_logger:error_report([{undefined_call, Call}]),
    {reply, ok, State}.

handle_cast(Cast, State) ->
    error_logger:error_report([{undefined_cast, Cast}]),
    {noreply, State}.

handle_info(autodiscovery_tick, #state{is_server = true} = State) ->
    Timer = ?MODULE:send_tick(),
    %?MODULE:multicast(State),
    {noreply, State#state{timer = Timer}};

handle_info(autodiscovery_tick, #state{is_server = false, ip = Ip} = State) ->
    %error_logger:info_msg({client, autodiscovery_tick}),
    Timer = ?MODULE:send_tick(),
    case create_server_socket(Ip) of
        {ok, Socket} ->
            NewState = State#state{socket = Socket, is_server = true, timer = Timer},
            %?MODULE:multicast(NewState),
            {noreply, NewState#state{timer = Timer}};
        {error, eaddrinuse} ->
            %?MODULE:multicast(State, <<"tick">>),
            {noreply, State#state{timer = Timer}}
    end;

handle_info({udp, Socket, FromIp, FromPort, Binary}, #state{is_server = false} = State) ->
    error_logger:info_msg({udp_received_on_client, Socket, FromIp, FromPort, Binary}),
    {noreply, State};

handle_info(
        {udp, _Socket, FromIp, _FromPort, <<MessageSize:16/integer, BinaryTerm:MessageSize/binary>>},
        #state{is_server = true, node_groups = NodeGroups} = State) ->
    error_logger:info_msg({udp_received_on_server, FromIp, BinaryTerm}),
    try binary_to_term(BinaryTerm) of
        {add_group, Group, Node} ->
            Nodes = maps:get(Group, NodeGroups, []),
            UpdatedNodeGroups = maps:put(Group, lists:append([Node], Nodes), NodeGroups),
            error_logger:info_report({from_client, add_group, Group, Node}),
            {ok, UpdatedState} = update_local_nodes(Node, State),
            sync_local_nodes(Group, Node, add, UpdatedState),
            {noreply, UpdatedState#state{node_groups = UpdatedNodeGroups}};
        _ ->
            error_logger:error_report([{unknown_udp, BinaryTerm}]),
            {noreply, State}
    catch
        error:badarg ->
            error_logger:error_report([{bad_udp, BinaryTerm}]),
            {noreply, State}
    end;

handle_info({udp, _Socket, FromIp, _FromPort, <<MessageSize:16/integer, Binary/binary>>}, #state{is_server = true} = State) ->
    error_logger:warning_report({udp_received_on_server, FromIp, size_mismatch, {size, MessageSize}, {binary, Binary}}),
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

create_server_socket(Ip) ->
    Options = lists:append([{ip, Ip}], ?UDP_OPTIONS),
    gen_udp:open(?AUTODISCOVER_PORT, Options).

multicast_add_group(Group, State) ->
    Term = {add_group, Group, node()},
    multicast(Term, State).

multicast(Term, #state{socket = Socket, ip = Ip, is_server = false}) ->
    error_logger:info_report({sending_client_udp, Term, Ip, ?AUTODISCOVER_PORT}),
    send_term(Socket, Ip, ?AUTODISCOVER_PORT, Term);

multicast(Term, #state{socket = Socket, multicast_ip = MulticastIp, is_server = true}) ->
    send_term(Socket, MulticastIp, ?AUTODISCOVER_PORT, Term).

send_term(Socket, Ip, Port, Term) ->
    BinaryTerm = term_to_binary(Term),
    MessageSize = byte_size(BinaryTerm),
    Message = <<MessageSize:16/integer, BinaryTerm/binary>>,
    gen_udp:send(Socket, Ip, Port, Message).

get_ip_and_multicast(Interface) ->
    {ok, IfList} = inet:getifaddrs(),
    {_, LoOpts} = proplists:lookup(Interface, IfList),
    {_, Ip} = proplists:lookup(addr, LoOpts),
    {_, MulticastIp} = proplists:lookup(broadaddr, LoOpts),
    {Ip, MulticastIp}.

get_interface() ->
    case application:get_env(nxtfr_autodiscovery, multicast_interface) of
        undefined -> "eth0";
        {ok, Interface} -> Interface
    end.

update_local_nodes(Node, #state{local_nodes = LocalNodes} = State) ->
    case {is_node_local(Node), lists:member(Node, LocalNodes)} of 
        {false, _} ->
            {ok, State};
        {true, true} -> 
            {ok, State};
        {true, false} ->
            {ok, State#state{local_nodes = lists:append([Node], LocalNodes)}}
    end.

is_node_local(OtherNode) ->
    OtherHost = lists:nth(2, string:split(atom_to_binary(OtherNode), <<"@">>)),
    MyHost = lists:nth(2, string:split(atom_to_binary(node()), <<"@">>)),
    OtherHost == MyHost.

sync_local_nodes(Group, Node, Operation, #state{local_nodes = LocalNodes}) ->
    [rpc:call(LocalNode, nxtfr_event, notify, [{sync_group, Group, Node, Operation}]) || LocalNode <- LocalNodes].