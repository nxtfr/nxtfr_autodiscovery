-module(nxtfr_autodiscovery_event_handler).
-author("christian@flodihn.se").
-behaviour(gen_event).

-export([init/1, handle_event/2, handle_call/2, handle_info/2, code_change/3, terminate/2]).
 
init([]) ->
    {ok, []}.

handle_event({join_autodiscovery_group, Group}, State) ->
    nxtfr_autodiscovery:join_group(Group),
    {ok, State};

handle_event({leave_autodiscovery_group, Group}, State) ->
    nxtfr_autodiscovery:join_group(Group),
    {ok, State};

handle_event({sync_autodiscovery_group, Group, Node, Operation}, State) ->
    nxtfr_autodiscovery:sync_group(Group, Node, Operation),
    {ok, State};

handle_event(Event, State) ->
    error_logger:info_report({?MODULE, unknown_event, Event}),
    {ok, State}.
 
handle_call(_, State) ->
    {ok, ok, State}.
 
handle_info(_, State) ->
    {ok, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
 
terminate(_Reason, _State) ->
    ok.

