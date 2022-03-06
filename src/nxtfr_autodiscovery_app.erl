%%%-------------------------------------------------------------------
%% @doc nxtfr_autodiscovery public API
%% @end
%%%-------------------------------------------------------------------

-module(nxtfr_autodiscovery_app).
-author("christian@flodihn.se").
-behaviour(application).

-export([start/0, start/2, stop/1]).

start() ->
    application:start(sasl),
    application:start(nxtfr_event),
    application:start(nxtfr_autodiscovery).

start(_StartType, _StartArgs) ->
    nxtfr_autodiscovery_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
