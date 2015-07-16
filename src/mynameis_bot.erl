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
    case misc:string_match(Message, "PING :") of
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

option_set(Option, State) ->
    lists:member(Option, State#state.options).

generate_response(State, User, Channel, Message) ->
    AddressedToBot = State#state.nickname ++ ":",
    Pandora = option_set(pandora, State),
    case hd(Message) of
        AddressedToBot when Pandora == true ->
            ["PRIVMSG ", Channel, " :", User, ": ", pandora:say(string:join(tl(Message), " ")), "\r\n"];
        ">"  ->
            case lists:keyfind(eval, 1, State#state.options) of
                {eval, User} -> ["PRIVMSG ", Channel, " :", 3, "4", "1", evaluate_expression(string:join(tl(Message), " ")), "\r\n"];
                _ -> no_response
            end;
        _ -> 
            _URLFun = fun(El, Acc) -> 
                    case misc:string_match(El, "http://") /= nomatch orelse misc:string_match(El, "https://") /= nomatch of
                    true -> El; 
                    _ -> Acc 
                    end 
            end,
            case lists:foldl(_URLFun, no_url, Message) of 
                no_url -> no_response;
                URL -> 
                    case utg:get_title(string:strip(URL), nomatch) of
                        nomatch -> no_response;
                        Title -> ["PRIVMSG ", Channel, " :", Title , "\r\n"]
                    end
            end
    end.

process_message(Message, State, Transport) when is_binary(Message) ->
    process_message(binary:bin_to_list(Message), State, Transport);

process_message(Message, State, Transport) ->
    TokenizedMessage = string:tokens(Message, " "),
    User = extract_user(TokenizedMessage),

    case lists:nth(2,TokenizedMessage) of
        "PRIVMSG" when length(TokenizedMessage) > 3 ->
            Channel = lists:nth(3,TokenizedMessage),
            Trailing = string:tokens(lists:reverse(lists:nthtail(2, lists:reverse(tl(string:join(lists:nthtail(3,TokenizedMessage), " "))))), " "),
            case generate_response(State, User, Channel, Trailing) of
                no_response -> ok;
                Response -> send(State#state.socket, Response, Transport)
            end,
            case option_set(logging, State) of
                true -> 
                    {Date, Time} = erlang:universaltime(),
                    file:write_file(State#state.server ++ "_log", io_lib:fwrite("[~p ~p] ~s <~s> ~s", [Date, Time, Channel, User, tl(string:join(Trailing, " "))]), [append]);
                false -> ok
            end;

        "JOIN" ->
            Channel = lists:sublist(lists:nth(3,TokenizedMessage),2,length(lists:nth(3,TokenizedMessage))-3),
            Op = ["MODE ", Channel, " +o ", User, "\r\n"],
            Notice = ["NOTICE ", User, " :Welcome to ", Channel, " BE nice.\r\n"],
            Response = case option_set(autoop, State) of
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
