-module(mynameis_sup).

-author("dave@douchedata.com").

-behaviour(supervisor).

-export([start_link/0, connect/5]).

-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

connect(Nickname, Server, Port, Channels, Options) ->
    ChildSpec = {Server, {mynameis_bot, start_link, [Nickname, Server, Port, Channels, Options]},
             permanent, brutal_kill, worker, [mynameis_bot]},
    supervisor:start_child(?MODULE, ChildSpec).

init([]) ->
    RestartStrategy = {one_for_one, 60, 1},
    {ok, {RestartStrategy, []}}.
