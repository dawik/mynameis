-include_lib("eunit/include/eunit.hrl").

-module(mynameis_bot).

-author("dave@douchedata.com").

-behaviour(gen_server).

-export([start_link/5]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {nickname :: binary(), server :: binary(), socket :: port(), options :: list()}).

start_link(Nickname, Server, Port, Channels, Options) ->
    gen_server:start_link({global, Server}, ?MODULE, [Nickname, Server, Port, Channels, Options], []).

init([Nickname, Server, Port, Channels, Options]) ->
    Transport = case lists:member(ssl, Options) of
        true -> ssl;
        false -> tcp
    end,
    {ok, Socket} = connect(Server, Port, [binary, {packet, 0}, {keepalive, true}, {active,true}], Transport),
    spawn(fun() ->
                send(Socket, [<<"NICK ">>, Nickname, <<"\r\n">>], Transport),
                timer:sleep(1000),
                send(Socket, [<<"USER ">>, Nickname, <<" 0 * :">>, Nickname, <<"\r\n">>], Transport),
                timer:sleep(5000),
                send(Socket,[ [<<"JOIN ">>, Channel, <<"\r\n">>] || Channel <- Channels], Transport)
        end),
    {ok, #state{socket = Socket, server = Server, nickname = Nickname, options = Options}}.

handle_call(_, _, State) ->
    {noreply, State}.

handle_cast(_, State) ->
    {noreply, State}.

handle_info({Transport, Socket, Message}, State) ->
    case match(Message, "PING :") of
        {match,_} when is_list(Message) -> "PING" ++ ServerAddress = Message,
            send(Socket, "PONG" ++ ServerAddress, Transport);
        {match,_} when is_binary(Message) -> 
            <<_Ping:32, ServerAddress/binary>> = Message,
            send(Socket, [<<"PONG">>, ServerAddress], Transport);
        nomatch ->
            process_message(Message, State, Transport)
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

extract_user([], Acc) ->
    lists:reverse(Acc);

extract_user([H|T], Acc) -> 
    case H of
        33 -> lists:reverse(Acc); 
        _ -> extract_user(T, [H|Acc])
    end.

extract_user(Data) ->
    extract_user(tl(lists:nth(1,Data)),[]).


option_get(Option, State) ->
    lists:member(Option, State#state.options).

is_match(Subject, Match) when hd(Subject) == hd(Match) ->
    is_match(tl(Subject), tl(Match));
is_match(_, []) ->
    true;
is_match(_, _) ->
    false.

match(Subject, Match, Pos) when hd(Subject) == hd(Match) ->
    case is_match(Subject, Match) of
        true -> {match, Pos};
        false -> match(tl(Subject), Match, Pos + 1)
    end;

match([], _Match, _Pos)-> nomatch;

match(_Subject, _Match, _Pos) ->
    match(tl(_Subject), _Match, _Pos + 1). 

match(Subject, Match) when is_binary(Subject) ->
    match(binary_to_list(Subject), Match, 0);

match(Subject, Match) ->
    match(Subject, Match, 0). 

generate_response(State, From, To, "\1VERSION\1") when To == State#state.nickname->
    {mynameis, Desc, Vsn } = lists:keyfind(mynameis, 1, application:which_applications()),
    [":", State#state.nickname, " NOTICE ", From, " :\1VERSION ", Desc, " ", Vsn," running on Erlang ", erlang:system_info(otp_release), " https://github.com/dawik/mynameis/\1" "\r\n"];

generate_response(State, From, To, Message) when To == State#state.nickname->
    case option_get(pandora, State) of
        true ->[":", State#state.nickname, " PRIVMSG ", From, " :", pandora:say(Message, State#state.nickname), "\r\n"];
        false -> [":", State#state.nickname, " PRIVMSG ", From, " :", Message, "\r\n"]
    end;

generate_response(State, From, To, Message) ->
    AddressedToBot = State#state.nickname ++ ":",
    case hd(string:tokens(Message, " ")) of
        AddressedToBot ->
            case option_get(pandora, State) of
                true ->[":", State#state.nickname, " PRIVMSG ", To, " :", From, ": ", pandora:say(Message, State#state.nickname), "\r\n"];
                false -> [":", State#state.nickname, " PRIVMSG ", To, " :", From, ": ", Message, "\r\n"]
            end;
                ">"  ->
            case lists:keyfind(eval, 1, State#state.options) of
                {eval, From} -> ["PRIVMSG ", To, " :", 3, "4", "1", evaluate_expression(tl(Message)), "\r\n"];
                _ -> no_response
            end;
        _ -> 
            case lists:foldl(fun(El, Acc) -> case match(El, "http://") /= nomatch orelse match(El, "https://") /= nomatch of true -> [El | Acc]; _ -> Acc end end, [], string:tokens(Message, " ")) of 
                [] -> 
                    no_response;
                URLS -> 
                    [ case utg:grab(URL, nomatch) of nomatch -> no_response; {Title, RTT} -> ["PRIVMSG ", To, " :", Title , " · ", RTT, "s\r\n"] end || URL <- URLS ]
            end
    end.

process_message(Message, State, Transport) when is_binary(Message) ->
    process_message(binary:bin_to_list(Message), State, Transport);

process_message(Message, State, Transport) ->
    TokenizedMessage = string:tokens(Message, " "),
    From = extract_user(TokenizedMessage),

    case lists:nth(2,TokenizedMessage) of
        "PRIVMSG" when length(TokenizedMessage) > 3 ->
            To = lists:nth(3,TokenizedMessage),
            Trailing = lists:reverse(lists:nthtail(2, lists:reverse(tl(string:join(lists:nthtail(3,TokenizedMessage), " "))))),
            case generate_response(State, From, To, Trailing) of
                no_response -> ok;
                Response -> send(State#state.socket, Response, Transport)
            end,
            case option_get(logging, State) of
                true -> 
                    {Date, Time} = erlang:universaltime(),
                    file:write_file(State#state.server ++ "_log", io_lib:fwrite("[~p ~p] ~p <~p> ~p~n", [Date, Time, To, From, Trailing]), [append]);
                false -> ok
            end;

        "JOIN" ->
            To = lists:sublist(lists:nth(3,TokenizedMessage),2,length(lists:nth(3,TokenizedMessage))-3),
            Op = ["MODE ", To, " +o ", From, "\r\n"],
            Notice = ["NOTICE ", From, " :Welcome to ", To, " BE nice.\r\n"],
            Response = case option_get(autoop, State) of
                true -> [Op, Notice];
                false -> [Notice]
            end,
            send(State#state.socket, Response, Transport);
        _ ->
            ok
    end.

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

eunit_test_() ->
    Integrate = [ {"giving time to connect", {timeout, 180, ?_assertMatch(true, begin timer:sleep(180000), true end)}} ],
    [{"Connecting to EFnet for integration test", {foreach, fun () -> application:start(mynameis), start_link("testrun", "efnet.port80.se", 6667, ["#mynameistest"], [pandora, url, autoop, {eval, "davve"}, logging]) end, Integrate}}]. 
