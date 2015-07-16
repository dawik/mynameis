mynameis
=====

Walking talking Erlang IRC bot.

### Features

  - Speaks when addressed
  - Ops and greets people as they join
  - Announces website titles from URI's
  - Evaluates erlang expressions. ** Warning, inherently unsafe ** 

Build
-----

    $ rebar3 compile

API
-----

### mynameis:connect(Name, Server, Port, Channels, Options) -> BotInstance()
    Starts a child bot instance
    Name = string()
    Server = string()
    Port = number()
    Channels = [Channel, ...] 
    Channel = string()
    Options = [option(), ...]
    option() = logging | autoop | ssl | pandora | {eval, Admin}
    Admin = string()
    BotInstance = pid()
    
    Starts a bot instance with nickname Name on Server that will join Channels with Options
    Registers the instance by server name.
    
    Integrate the bot in another supervision tree by starting a bot directly using
    mynameis_bot:start_link/5 with the same arguments

Demo
-----

    % rebar3 shell
    ===> Verifying dependencies...
    ===> Compiling mynameis
    Erlang R16B03-1 (erts-5.10.4) [source] [64-bit] [smp:4:4] [async-threads:0] [hipe] [kernel-poll:false]

    Eshell V5.10.4  (abort with ^G)
    1> application:start(mynameis).
    ok
    2> mynameis:connect("mynameis", "irc.freenode.net", 6667, ["#erlounge"], [{eval, "dawik"}, pandora, logging, autoop]). 
    {ok,<0.112.0>}
    3> global:registered_names().
    ["irc.freenode.net"]
    4> q().
    ok

    Meanwhile, on freenode..

    mynameis [~mynameis@h-148-208.a328.priv.bahnhof.se] has joined #erlounge
    < dawik> > math:pi().
    < mynameis> 3.141592653589793
    < dawik> http://www.erlang.org
    < mynameis> Erlang Programming Language 0.038s
    < dawik> mynameis: bye
    < mynameis> dawik: Bye.
    mynameis [~mynameis@h-148-208.a328.priv.bahnhof.se] has quit [Remote host closed the connection]
