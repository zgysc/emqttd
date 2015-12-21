%%%-----------------------------------------------------------------------------
%%% Copyright (c) 2012-2015 eMQTT.IO, All Rights Reserved.
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to deal
%%% in the Software without restriction, including without limitation the rights
%%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%%% copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in all
%%% copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
%%% SOFTWARE.
%%%-----------------------------------------------------------------------------
%%% @doc emqttd http publish API and websocket client.
%%%
%%% @author Feng Lee <feng@emqtt.io>
%%%-----------------------------------------------------------------------------
-module(emqttd_http).

-include("emqttd.hrl").

-include("emqttd_protocol.hrl").

-import(proplists, [get_value/2, get_value/3]).

-export([handle_request/1]).
-define(ROUTER, emqttd_router).

handle_request(Req) ->
    handle_request(Req:get(method), Req:get(path), Req).

handle_request('GET', "/status", Req) ->
    {InternalStatus, _ProvidedStatus} = init:get_status(),
    AppStatus =
    case lists:keysearch(emqttd, 1, application:which_applications()) of
        false         -> not_running;
        {value, _Val} -> running
    end,
    Status = io_lib:format("Node ~s is ~s~nemqttd is ~s",
                            [node(), InternalStatus, AppStatus]),
    Req:ok({"text/plain", iolist_to_binary(Status)});
    
%%new push. You can push to a single clientId with any topic you want 
%% param:
%%        target  ::   clientId1,clientId2,clientId3...... | all
handle_request('POST', "/mqtt/newpush", Req) ->
    Params = mochiweb_request:parse_post(Req),
    lager:info("HTTP new Publish: ~p", [Params]),
    ClientId = get_value("client", Params, http),
    Qos      = int(get_value("qos", Params, "1")),
    Retain   = bool(get_value("retain", Params,  "0")),
    Topic    = list_to_binary(get_value("topic", Params)),
    Target   = list_to_binary(get_value("target", Params, "all")),
    Payload  = list_to_binary(get_value("message", Params)),
    case {validate(qos, Qos), validate(topic, Topic)} of
        {true, true} ->
            Msg = emqttd_message:make(ClientId, Qos, Topic, Payload),
            if
                Target =:= <<"all">> -> emqttd_pubsub:publish_all(Topic, Msg);
                Target /= <<"all">> -> emqttd_pubsub:publish_batch(Target, Msg#mqtt_message{retain = Retain})
            end,
            Req:ok({"text/plain", <<"ok">>});
        {false, _} ->
            Req:respond({400, [], <<"Bad QoS">>});
        {_, false} ->
            Req:respond({400, [], <<"Bad Topic">>})
    end;

%%------------------------------------------
%%check client is online or not, not support cluster
%%------------------------------------------
handle_request('GET', "/mqtt/online", Req) ->
    Params = mochiweb_request:parse_qs(Req),
    Cid = get_value("clientId", Params, http),
    Nodes= lists:umerge(ets:match(topic, {'_', '_', '$1'})),
    Result= lists:foldl(Fun(Node, Sum) -> rpc:call(Node, ?ROUTER, checkonline, [Cid]) + Sum end, 0, Nodes),
    if
        Result > 0 -> Req:ok({"text/plain", <<"1">>}); 
        Result =:= 0 -> Req:ok({"text/plain", <<"0">>})
    end;

handle_request('GET', "/mqtt/mysub", Req) ->
  Params = mochiweb_request:parse_qs(Req),
  Cid = get_value("clientId", Params, http),
  Lists = ets:lookup(subscription, ClientId),
  Status = io_lib:format("~p", [Lists]),
  Req:ok({"text/plain", iolist_to_binary(Status)});
%%--------------------------------------------
%%subscriber topic for client at server side 
%%--------------------------------------------
handle_request('GET',"/mqtt/subtopic", Req) ->
    Params=mochiweb_request:parse_qs(Req),
    ClientId = list_to_binary(get_value("clientId", Params, http)),
    Topic = list_to_binary(get_value("topic", Params, http)),
    Flag = int(get_value("flag", Params, "1")),
    Qos = int(get_value("qos", Params, "1")),
    Topics = binary:split(Topic, <<",">>, [global]),
    case emqttd_sm:lookup_session(ClientId) of
        undefined -> Req:ok({"text/plain", <<"BAD_CLIENT">>});
        Session -> #mqtt_session{sess_pid = Sess_pid} = Session,
        case Flag of
            1 -> emqttd_session:subscribe(Sess_pid, [{T, Qos} || T <- Topics]);
            0 -> emqttd_session:unsubscribe(Sess_pid, [{T} || T <- Topic])
        end,
    Req:ok({"text/plain",<<"ok">>})
    end;


%%------------------------------------------------------------------------------
%% HTTP Publish API
%%------------------------------------------------------------------------------
handle_request('POST', "/mqtt/publish", Req) ->
    Params = mochiweb_request:parse_post(Req),
    lager:info("HTTP Publish: ~p", [Params]),
    case authorized(Req) of
    true ->
        ClientId = get_value("client", Params, http),
        Qos      = int(get_value("qos", Params, "0")),
        Retain   = bool(get_value("retain", Params,  "0")),
        Topic    = list_to_binary(get_value("topic", Params)),
        Payload  = list_to_binary(get_value("message", Params)),
        case {validate(qos, Qos), validate(topic, Topic)} of
            {true, true} ->
                Msg = emqttd_message:make(ClientId, Qos, Topic, Payload),
                emqttd_pubsub:publish(Msg#mqtt_message{retain  = Retain}),
                Req:ok({"text/plain", <<"ok">>});
           {false, _} ->
                Req:respond({400, [], <<"Bad QoS">>});
            {_, false} ->
                Req:respond({400, [], <<"Bad Topic">>})
        end;
    false ->
        Req:respond({401, [], <<"Fobbiden">>})
    end;

%%------------------------------------------------------------------------------
%% MQTT Over WebSocket
%%------------------------------------------------------------------------------
handle_request('GET', "/mqtt", Req) ->
    lager:info("WebSocket Connection from: ~s", [Req:get(peer)]),
    Upgrade = Req:get_header_value("Upgrade"),
    Proto   = Req:get_header_value("Sec-WebSocket-Protocol"),
    case {is_websocket(Upgrade), Proto} of
        {true, "mqtt" ++ _Vsn} ->
            emqttd_ws_client:start_link(Req);
        {false, _} ->
            lager:error("Not WebSocket: Upgrade = ~s", [Upgrade]),
            Req:respond({400, [], <<"Bad Request">>});
        {_, Proto} ->
            lager:error("WebSocket with error Protocol: ~s", [Proto]),
            Req:respond({400, [], <<"Bad WebSocket Protocol">>})
    end;

%%------------------------------------------------------------------------------
%% Get static files
%%------------------------------------------------------------------------------
handle_request('GET', "/" ++ File, Req) ->
    lager:info("HTTP GET File: ~s", [File]),
    mochiweb_request:serve_file(File, docroot(), Req);

handle_request(Method, Path, Req) ->
    lager:error("Unexpected HTTP Request: ~s ~s", [Method, Path]),
    Req:not_found().

%%------------------------------------------------------------------------------
%% basic authorization
%%------------------------------------------------------------------------------
authorized(Req) ->
    case Req:get_header_value("Authorization") of
    undefined ->
        false;
    "Basic " ++ BasicAuth ->
        {Username, Password} = user_passwd(BasicAuth),
        case emqttd_access_control:auth(#mqtt_client{username = Username}, Password) of
            ok ->
                true;
            {error, Reason} ->
                lager:error("HTTP Auth failure: username=~s, reason=~p", [Username, Reason]),
                false
        end
    end.

user_passwd(BasicAuth) ->
    list_to_tuple(binary:split(base64:decode(BasicAuth), <<":">>)). 

validate(qos, Qos) ->
    (Qos >= ?QOS_0) and (Qos =< ?QOS_2); 

validate(topic, Topic) ->
    emqttd_topic:validate({name, Topic}).

int(S) -> list_to_integer(S).

bool("0") -> false;
bool("1") -> true.

is_websocket(Upgrade) -> 
    Upgrade =/= undefined andalso string:to_lower(Upgrade) =:= "websocket".

docroot() ->
    {file, Here} = code:is_loaded(?MODULE),
    Dir = filename:dirname(filename:dirname(Here)),
    filename:join([Dir, "priv", "www"]).

