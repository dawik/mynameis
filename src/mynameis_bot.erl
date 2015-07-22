-include_lib("eunit/include/eunit.hrl").

-module(mynameis_bot).

-author("dave@douchedata.com").

-behaviour(gen_server).

-export([start_link/5]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {nickname :: binary(), server :: binary(), socket :: port(), port :: number(), 
                transport = tcp, autoop = false, pandora = false, logging = false, url = true, eval = false}).

start_link(Nickname, Server, Port, Channels, Options) ->
    gen_server:start_link({global, Server}, ?MODULE, [Nickname, Server, Port, Channels, Options], []).

init([Nickname, Server, Port, Channels, Options]) ->
    State = lists:foldl(fun set_option/2, #state{server = Server, nickname = list_to_binary(Nickname), port = Port}, Options),

    {ok, Socket} = connect(Server, Port, [binary, {packet, 0}, {keepalive, true}, {active,true}], State#state.transport),

    spawn(fun() ->
                send(Socket, [<<"NICK ">>, Nickname, <<"\r\n">>], State#state.transport),
                timer:sleep(1000),
                send(Socket, [<<"USER ">>, Nickname, <<" 0 * :">>, Nickname, <<"\r\n">>], State#state.transport),
                timer:sleep(5000),
                send(Socket,[ [<<"JOIN ">>, Channel, <<"\r\n">>] || Channel <- Channels], State#state.transport)
        end),

    {ok, State#state{socket = Socket}}.

handle_call(_, _, State) ->
    {noreply, State}.

handle_cast(_, State) ->
    {noreply, State}.

handle_info({Transport, _Socket, Message}, State) ->
    case generate_reply(Message, State) of
        ok -> ok;
        Response -> send(State#state.socket, [Response, <<"\r\n">>], Transport)
    end,
    {noreply, State};

handle_info({http, {_ReqId, _, _Bin}}, State) -> 
    {noreply, State};

handle_info({tcp_closed, _}, _) ->
    timer:sleep(10000),
    throw(disconnected);

handle_info(Message, State) ->
    io:format("Unhandled message ~p~n",[Message]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

send(Socket, Message, tcp) ->
    gen_tcp:send(Socket, Message);

send(Socket, Message, ssl) ->
    ssl:send(Socket, Message).

connect(Server, Port, Options, ssl) ->
    ssl:connect(Server, Port, Options);

connect(Server, Port, Options, tcp) ->
    gen_tcp:connect(Server, Port, Options).

evaluate_expression(S) ->
    case erl_scan:string(S) of
        {error, _ } -> ok;
        {ok, Scanned, _} -> case erl_parse:parse_exprs(Scanned) of
                {ok, Parsed} -> 
                    try 
                        case erl_eval:exprs(Parsed, []) of
                            {value, Value, _} -> lists:flatten(io_lib:format("~p",[Value]));
                            _ -> "Bad expression"
                        end
                    catch Exception:Details ->
                            lists:flatten(io_lib:format("~p:~p", [Exception,Details]))
                    end;
                Error ->
                    lists:flatten(io_lib:format("~p", [Error]))
            end
    end.

set_option(ssl, State) ->
    State#state{transport = ssl};

set_option(autoop, State) ->
    State#state{autoop = true};

set_option(url, State) ->
    State#state{url = true};

set_option(pandora, State) ->
    State#state{pandora = true};

set_option(logging, State) ->
    State#state{logging = true};

set_option({eval, User}, State) when is_list(User) ->
    State#state{eval = list_to_binary(User)};

set_option({eval, User}, State) when is_binary(User) ->
    State#state{eval = User}.

generate_reply(<<"JOIN">>, T, Nick, State) when Nick /= State#state.nickname ->
    Channel = binary:part(T, {0, byte_size(T) - 2}),
    Op = ["MODE ", Channel, " +o ", Nick, "\r\n"],
    Notice = ["NOTICE ", Channel, " :Welcome ", Nick, " to ", Channel, "\r\n"],
    case State#state.autoop of
        true -> [Op, Notice];
        false -> [Notice]
    end;

generate_reply(<<"PART">>, _T, _Nick, _State) ->
    ok;

generate_reply(<<"MODE">>, _T, _Nick, _State) ->
    ok;

generate_reply(_, T, Nick, State) ->
    {ChannelOffset, _} = binary:match(T, <<" ">>),
    <<Channel:ChannelOffset/binary, " :", MessageWithCRNL/binary>> = T,
    case binary:part(MessageWithCRNL, {0, byte_size(MessageWithCRNL) - 2}) of
        <<"\1VERSION\1">> ->
            application:ensure_all_started(mynameis),
            {mynameis, Desc, Vsn } = lists:keyfind(mynameis, 1, application:which_applications()),
            [":", State#state.nickname, " NOTICE ", Nick, " :\1VERSION ", Desc, " ", Vsn,
             " running on Erlang ", erlang:system_info(otp_release), " https://github.com/dawik/mynameis/\1" "\r\n"];
        <<"> ", ToEval/binary>> when State#state.eval == Nick andalso Channel /= State#state.nickname ->
            ["PRIVMSG ", Channel, " :", evaluate_expression(binary_to_list(ToEval))];
        <<"> ", ToEval/binary>> when State#state.eval == Nick ->
            ["PRIVMSG ", Nick, " :", evaluate_expression(binary_to_list(ToEval))];
        Message -> 
            try 
                case binary:match(Message, State#state.nickname) of
                    {NickAddressOffset, NickAddressLen} -> 
                        _Offset = NickAddressOffset + NickAddressLen,
                        <<_:_Offset/binary, ": ", Something/binary>> = Message,
                        ["PRIVMSG ", Channel, " :", pandora:say(binary_to_list(Something), binary_to_list(State#state.nickname))]
                end
            catch
                _:_ -> 
                    ok
            end
    end.

generate_reply(<<"PING", T/binary>>, _State) ->
    [<<"PONG">>, T];

generate_reply(<<":", T/binary>>, State) ->
    {SenderOffset, _ } = binary:match(T, <<" ">>),
    <<Sender:SenderOffset/binary, " ", _Message/binary>> = T,
    case binary:match(Sender,<<"!">>) of
        nomatch -> 
            ok;
        {NickOffset, _} -> 
            <<Nick:NickOffset/binary, "!", _T2/binary>> = Sender,
            {IdOffset, _} = binary:match(_T2, <<"@">>),
            <<_Ident:IdOffset/binary, "@", _Host/binary>> = _T2,
            {MsgTypeOffset, _} = binary:match(_Message, <<" ">>),
            <<MsgType:MsgTypeOffset/binary, " ", _T3/binary>> = _Message,
            generate_reply(MsgType, _T3, Nick, State)
    end;

generate_reply(Bin, _State) ->
    io:format("Overflow from last message?~n ***~s***~n", [Bin]),
    ok.

eunit_test_() ->
    [{"freenode integration test", 
      {foreach, 
       fun()-> application:start(mynameis), start_link("testrun123", "irc.freenode.net", 6667, ["#mynameistest"], [pandora, url, autoop, {eval, "dawik"}, logging]) end, 
       [ {"giving time to connect", {timeout, 180, ?_assertMatch(true, begin timer:sleep(60000), true end)}} ]}}]. 
