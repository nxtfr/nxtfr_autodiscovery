%%%-------------------------------------------------------------------
%% @doc nxtfr_autodiscovery public API
%% @end
%%%-------------------------------------------------------------------

-module(nxtfr_autodiscovery_app).
-author("christian@flodihn.se").
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    application:start(sasl),
    nxtfr_autodiscovery_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
