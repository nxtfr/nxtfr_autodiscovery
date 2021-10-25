%%%-------------------------------------------------------------------
%% @doc nxtfr_autodiscovery top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(nxtfr_autodiscovery_sup).
-author("christian@flodihn.se").
-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy => one_for_all,
        intensity => 3,
        period => 1},

    NxtfrAutodiscovery = #{
        id => nxtfr_autodiscovery,
        start => {nxtfr_autodiscovery, start_link, []},
        type => worker},

    ChildSpecs = [NxtfrAutodiscovery],
    {ok, {SupFlags, ChildSpecs}}.

%% internal functions
