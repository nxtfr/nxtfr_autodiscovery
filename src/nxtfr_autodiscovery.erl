-module(nxtfr_autodiscovery).
-author("christian@flodihn.se").
-behaviour(gen_server).

-type(ip() :: {integer(), integer(), integer(), integer()}).
            
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
    join_group/1,
    leave_group/1,
    sync_group/3,
    push_groups/1,
    query_group/1,
    query_shard/2,
    query_random/1,
    call_shard/5,
    call_random/4
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
    socket :: port(), 
    is_server :: boolean(),
    timer :: reference(),
    interface :: string(),
    ip :: ip(),
    multicast_ip :: ip(),
    my_groups = [] :: list(),
    local_nodes = [] :: list(),
    node_groups = {} :: map()
}).

-type state() :: #state{}.

dev1() ->
    application:start(nxtfr_autodiscovery),
    nxtfr_event:notify({join_autodiscovery_group, group1}).

dev2() ->
    application:start(nxtfr_autodiscovery),
    nxtfr_event:notify({join_autodiscovery_group, group2}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec info() -> {ok, state()}.
info() ->
    gen_server:call(?MODULE, info).

-spec join_group(Group :: atom()) -> ok.
join_group(Group) ->
    gen_server:call(?MODULE, {join_group, Group}).

-spec leave_group(Group :: atom()) -> ok.
leave_group(Group) ->
    gen_server:call(?MODULE, {leave_group, Group}).

-spec sync_group(Group :: atom(), Node :: atom(), Operation :: add | remove) -> ok.
sync_group(Group, Node, Operation) ->
    gen_server:call(?MODULE, {sync_group, Group, Node, Operation}).

-spec push_groups(NodeGroups :: map()) -> ok.
push_groups(NodeGroups) ->
    gen_server:call(?MODULE, {push_groups, NodeGroups}).

-spec query_group(Group :: atom()) -> {ok, Nodes :: list()}.
query_group(Group) ->
    gen_server:call(?MODULE, {query_group, Group}).

-spec query_shard(Uid :: binary(), Group :: atom()) -> {ok, Node :: atom()} | {error, group_not_found}.
query_shard(Uid, Group) ->
    gen_server:call(?MODULE, {query_shard, Uid, Group}).

-spec query_random(Group :: atom()) -> {ok, Node :: atom}.
query_random(Group) ->
    gen_server:call(?MODULE, {query_random, Group}).

-spec call_shard(Uid :: binary(), Group :: atom(), Module :: atom(), Function :: atom(), Args :: list()) -> Result :: any().
call_shard(Uid, Group, Module, Function, Args) ->
    {ok, Node} = query_shard(Uid, Group),
    rpc:call(Node, Module, Function, Args).

-spec call_random(Group :: atom(), Module :: atom(), Function :: atom(), Args :: list()) -> Result :: any().
call_random(Group, Module, Function, Args) ->
    {ok, Node} = query_random(Group),
    rpc:call(Node, Module, Function, Args).

-spec init([]) -> {ok, state()}.
init([]) ->
    application:start(nxtfr_event),
    nxtfr_event:add_handler(nxtfr_autodiscovery_event_handler),
    Interface = ?MODULE:get_interface(),
    Timer = ?MODULE:send_tick(),
    {Ip, MulticastIp} = get_ip_and_multicast(Interface),
    case ?MODULE:create_server_socket(Ip) of
        {ok, Socket} ->
            State = #state{
                socket = Socket,
                is_server = true,
                timer = Timer,
                interface = Interface,
                ip = Ip,
                multicast_ip = MulticastIp,
                node_groups = #{}},
            {ok, State};
        {error, eaddrinuse} ->
            {ok, Socket} = gen_udp:open(0, ?UDP_OPTIONS),
            State = #state{
                socket = Socket,
                is_server = false,
                timer = Timer,
                interface = Interface,
                ip = Ip,
                multicast_ip = MulticastIp,
                node_groups = #{}},
            {ok, State}
    end.

handle_call(info, _From, State) ->
    {reply, {ok, State}, State};

handle_call({join_group, Group}, _From, #state{my_groups = MyGroups, is_server = true} = State) ->
    case lists:member(Group, MyGroups) of
        true ->
            {reply, ok, State};
        false ->
            UpdatedMyGroups = lists:append([Group], MyGroups),
            UpdatedState = update_node_groups(Group, node(), add, State),
            {reply, ok, UpdatedState#state{my_groups = UpdatedMyGroups}}
    end;

handle_call({join_group, Group}, _From, #state{my_groups = MyGroups, is_server = false} = State) ->
    case lists:member(Group, MyGroups) of
        true ->
            {reply, ok, State};
        false ->
            UpdatedMyGroups = lists:append([Group], MyGroups),
            multicast_join_group(Group, State),
            {reply, ok, State#state{my_groups = UpdatedMyGroups}}
    end;

handle_call({leave_group, Group}, _From, #state{my_groups = MyGroups} = State) ->
    UpdatedMyGroups = lists:delete(Group, MyGroups),
    {reply, ok, State#state{my_groups = UpdatedMyGroups}};

handle_call({sync_group, Group, Node, Operation}, _From, State) ->
    UpdatedState = update_node_groups(Group, Node, Operation, State),
    {reply, ok, UpdatedState};

handle_call({push_groups, NodeGroups}, _From, #state{is_server = false} = State) ->
    io:format("handle_call({push_groups, NodeGroups} ~p~n", [NodeGroups]),
    {reply, ok, State#state{node_groups = NodeGroups}};

handle_call({query_group, Group}, _From, #state{node_groups = NodeGroups} = State) ->
    case maps:find(Group, NodeGroups) of
        {ok, Nodes} ->
            {reply, {ok, Nodes}, State};
        error ->
            {reply, {ok, []}, State}
    end;

handle_call({query_shard, Uid, Group}, _From, #state{node_groups = NodeGroups} = State) ->
    case maps:find(Group, NodeGroups) of
        {ok, Nodes} ->
            Node = map_uid_to_shard(Uid, Nodes),
            {reply, {ok, Node}, State};
        error ->
            {reply, {error, group_not_found}, State}
    end;

handle_call({query_random, Group}, _From, #state{node_groups = NodeGroups} = State) ->
    case maps:find(Group, NodeGroups) of
        {ok, Nodes} ->
            Node = lists:nth(rand:uniform(length(Nodes)), Nodes),
            {reply, {ok, Node}, State};
        error ->
            {reply, {ok, []}, State}
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

handle_info({udp, _Socket, _FromIp, _FromPort, Binary}, #state{is_server = false} = State) ->
    error_logger:warning_report({?MODULE, handle_info, unknown_binary, Binary}),
    {noreply, State};

handle_info(
        {udp, _Socket, _FromIp, _FromPort, <<MessageSize:16/integer, BinaryTerm:MessageSize/binary>>},
        #state{is_server = true, node_groups = NodeGroups} = State) ->
    try binary_to_term(BinaryTerm) of
        {join_group, Group, Node} ->
            Nodes = maps:get(Group, NodeGroups, []),
            UpdatedNodeGroups = maps:put(Group, lists:append([Node], Nodes), NodeGroups),
            {ok, UpdatedState} = update_local_nodes(Node, State),
            io:format("Service pushing nodegroups: ~p.~n", [UpdatedNodeGroups]),
            push_node_groups(Node, UpdatedNodeGroups),
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

-spec send_tick() -> reference().
send_tick() ->
    erlang:send_after(?AUTODISCOVER_TICK_TIME, self(), autodiscovery_tick).

-spec create_server_socket(Ip :: ip()) -> port().
create_server_socket(Ip) ->
    Options = lists:append([{ip, Ip}], ?UDP_OPTIONS),
    gen_udp:open(?AUTODISCOVER_PORT, Options).

-spec multicast_join_group(Group :: atom(), State :: state()) -> ok.
multicast_join_group(Group, State) ->
    Term = {join_group, Group, node()},
    multicast(Term, State).

-spec multicast(Term :: any(), State :: state()) -> ok.
multicast(Term, #state{socket = Socket, ip = Ip, is_server = false}) ->
    error_logger:info_report({sending_client_udp, Term, Ip, ?AUTODISCOVER_PORT}),
    send_term(Socket, Ip, ?AUTODISCOVER_PORT, Term);

multicast(Term, #state{socket = Socket, multicast_ip = MulticastIp, is_server = true}) ->
    send_term(Socket, MulticastIp, ?AUTODISCOVER_PORT, Term).

-spec send_term(Socket :: port(), Ip :: ip(), Port :: integer(), Term :: any()) -> ok.
send_term(Socket, Ip, Port, Term) ->
    BinaryTerm = term_to_binary(Term),
    MessageSize = byte_size(BinaryTerm),
    Message = <<MessageSize:16/integer, BinaryTerm/binary>>,
    gen_udp:send(Socket, Ip, Port, Message).

-spec get_ip_and_multicast(Interface :: string()) -> {Ip :: ip(), MulticaetIp :: ip()}.
get_ip_and_multicast(Interface) ->
    {ok, IfList} = inet:getifaddrs(),
    {_, LoOpts} = proplists:lookup(Interface, IfList),
    case proplists:lookup(Interface, IfList) of
        none -> {{0, 0, 0, 0}, {0, 0, 0, 0}};
        {_, LoOpts}
            case proplists:lookup(addr, LoOpts) of
                {_, Ip} ->
                    case proplists:lookup(broadaddr, LoOpts) of
                    {_, MulticastIp} -> {Ip, MulticastIp};
                    none -> {{0, 0, 0, 0}, {0, 0, 0, 0}}
                end;
            none ->
                {{0, 0, 0, 0}, {0, 0, 0, 0}}
        end
    end.

-spec get_interface() -> Interface :: string().
get_interface() ->
    case application:get_env(nxtfr_autodiscovery, multicast_interface) of
        undefined -> "eth0";
        {ok, Interface} -> Interface
    end.

-spec update_node_groups(Group :: atom(), Node :: atom(), Operation :: add | remove, State :: state()) -> state().
update_node_groups(Group, Node, Operation, #state{node_groups = NodeGroups} = State) ->
    Nodes = maps:get(Group, NodeGroups, []),
    case {Operation, lists:member(Node, Nodes)} of
        {add, true} ->
            State;
        {add, false} ->
            UpdatedNodeGroups = maps:put(Group, lists:append([Node], Nodes), NodeGroups),
            State#state{node_groups = UpdatedNodeGroups};
        {remove, true} ->
            UpdatedNodeGroups = maps:put(Group, lists:delete(Node, Nodes), NodeGroups),
            State#state{node_groups = UpdatedNodeGroups};
        {remove, false} ->
            State
    end.

-spec update_local_nodes(Node :: atom(), State :: state()) -> {ok, state()}.
update_local_nodes(Node, #state{local_nodes = LocalNodes} = State) ->
    case {is_node_local(Node), lists:member(Node, LocalNodes)} of 
        {false, _} ->
            {ok, State};
        {true, true} -> 
            {ok, State};
        {true, false} ->
            {ok, State#state{local_nodes = lists:append([Node], LocalNodes)}}
    end.

-spec is_node_local(OtherNode :: atom) -> boolean().
is_node_local(OtherNode) ->
    OtherHost = lists:nth(2, string:split(erlang:atom_to_binary(OtherNode), <<"@">>)),
    MyHost = lists:nth(2, string:split(erlang:atom_to_binary(node()), <<"@">>)),
    OtherHost == MyHost.

-spec sync_local_nodes(Group :: atom(), Node :: atom(), Operation :: add | remove, state()) -> any().
sync_local_nodes(Group, Node, Operation, #state{local_nodes = LocalNodes}) ->
    %% We do not need to to send a sync message to the node that joined the group.
    LocalNodesToSync = lists:delete(Node, LocalNodes),
    [rpc:call(LocalNode, nxtfr_autodiscovery, sync_group, [Group, Node, Operation]) || LocalNode <- LocalNodesToSync].

-spec push_node_groups(Node::atom(), NodeGroups :: list()) -> ok.
push_node_groups(Node, NodeGroups) ->
    rpc:call(Node, nxtfr_autodiscovery, push_groups, [NodeGroups]).

map_uid_to_shard(Uid, NodeGroups) ->
    ShardKey = uid_to_integer(Uid) rem length(NodeGroups),
    %% +1 because first element in list is at position 1 not 0.
    lists:nth(ShardKey + 1, NodeGroups).

uid_to_integer(<<A:8/binary, "-", B:4/binary, "-", C:4/binary, "-", D:4/binary, "-", E:12/binary>>) ->
    list_to_integer(binary_to_list(<<A/binary, B/binary, C/binary, D/binary, E/binary>>), 16).
