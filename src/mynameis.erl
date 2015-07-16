-module(mynameis).

-behaviour(application).

-export([start/2 ,stop/1, connect/5]).

start(_, _) ->
    mynameis_sup:start_link().

stop(_) ->
    ok.

connect(Nickname, Server, Port, Channels, Options) ->
    mynameis_sup:connect(Nickname, Server, Port, Channels, Options).
