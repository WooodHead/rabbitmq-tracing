%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ Federation.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2014 GoPivotal, Inc.  All rights reserved.
%%

-module(rabbit_tracing_consumer).

-behaviour(gen_server).

-include_lib("amqp_client/include/amqp_client.hrl").

-import(rabbit_misc, [pget/2, pget/3, table_lookup/2]).

-record(state, {conn, ch, vhost, queue, file, filename, format}).
-record(log_record, {timestamp, type, exchange, queue, node, connection,
                     vhost, username, channel, routing_keys, routed_queues,
                     properties, payload}).

-define(X, <<"amq.rabbitmq.trace">>).

-export([start_link/1, info_all/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

info_all(Pid) ->
    gen_server:call(Pid, info_all, infinity).

%%----------------------------------------------------------------------------

init(Args) ->
    process_flag(trap_exit, true),
    Name = pget(name, Args),
    VHost = pget(vhost, Args),
    {ok, Conn} = amqp_connection:start(
                   #amqp_params_direct{virtual_host = VHost}),
    link(Conn),
    {ok, Ch} = amqp_connection:open_channel(Conn),
    link(Ch),
    #'queue.declare_ok'{queue = Q} =
        amqp_channel:call(Ch, #'queue.declare'{durable   = false,
                                               exclusive = true}),
    #'queue.bind_ok'{} =
    amqp_channel:call(
      Ch, #'queue.bind'{exchange = ?X, queue = Q,
                        routing_key = pget(pattern, Args)}),
    #'basic.qos_ok'{} =
        amqp_channel:call(Ch, #'basic.qos'{prefetch_count = 10}),
    #'basic.consume_ok'{} =
        amqp_channel:subscribe(Ch, #'basic.consume'{queue  = Q,
                                                    no_ack = false}, self()),
    {ok, Dir} = application:get_env(directory),
    Filename = Dir ++ "/" ++ binary_to_list(Name) ++ ".log",
    case filelib:ensure_dir(Filename) of
        ok ->
            case file:open(Filename, [append]) of
                {ok, F} ->
                    rabbit_tracing_traces:announce(VHost, Name, self()),
                    Format = list_to_atom(binary_to_list(pget(format, Args))),
                    rabbit_log:info("Tracer opened log file ~p with "
                                    "format ~p~n", [Filename, Format]),
                    {ok, #state{conn = Conn, ch = Ch, vhost = VHost, queue = Q,
                                file = F, filename = Filename,
                                format = Format}};
                {error, E} ->
                    {stop, {could_not_open, Filename, E}}
            end;
        {error, E} ->
            {stop, {could_not_create_dir, Dir, E}}
    end.

handle_call(info_all, _From, State = #state{vhost = V, queue = Q}) ->
    [QInfo] = rabbit_mgmt_db:augment_queues(
                [rabbit_mgmt_wm_queue:queue(V, Q)],
                rabbit_mgmt_util:no_range(), basic),
    {reply, [{queue, rabbit_mgmt_format:strip_pids(QInfo)}], State};

handle_call(_Req, _From, State) ->
    {reply, unknown_request, State}.

handle_cast(_C, State) ->
    {noreply, State}.

handle_info(Delivery = {#'basic.deliver'{delivery_tag = Seq}, #amqp_msg{}},
            State    = #state{ch = Ch, file = F, format = Format}) ->
    Print = fun(Fmt, Args) -> io:format(F, Fmt, Args) end,
    log(Format, Print, delivery_to_log_record(Delivery)),
    amqp_channel:cast(Ch, #'basic.ack'{delivery_tag = Seq}),
    {noreply, State};

handle_info(_I, State) ->
    {noreply, State}.

terminate(shutdown, #state{conn = Conn, ch = Ch,
                           file = F, filename = Filename}) ->
    catch amqp_channel:close(Ch),
    catch amqp_connection:close(Conn),
    catch file:close(F),
    rabbit_log:info("Tracer closed log file ~p~n", [Filename]),
    ok;

terminate(_Reason, _State) ->
    ok.

code_change(_, State, _) -> {ok, State}.

%%----------------------------------------------------------------------------

delivery_to_log_record({#'basic.deliver'{routing_key = Key},
                        #amqp_msg{props   = #'P_basic'{headers = H},
                                  payload = Payload}}) ->
    {Type, Q, RQs} = case Key of
                         <<"publish.", _Rest/binary>> ->
                             {array, Qs} = table_lookup(H, <<"routed_queues">>),
                             {published, none, [Q || {_, Q} <- Qs]};
                         <<"deliver.", Rest/binary>> ->
                             {received,  Rest, none}
                     end,
    {longstr, Node}   = table_lookup(H, <<"node">>),
    {longstr, X}      = table_lookup(H, <<"exchange_name">>),
    {array, Keys}     = table_lookup(H, <<"routing_keys">>),
    {table, Props}    = table_lookup(H, <<"properties">>),
    {longstr, Conn}   = table_lookup(H, <<"connection">>),
    {longstr, VHost}  = table_lookup(H, <<"vhost">>),
    {longstr, User}   = table_lookup(H, <<"user">>),
    {signedint, Chan} = table_lookup(H, <<"channel">>),
    #log_record{timestamp    = rabbit_mgmt_format:now_to_str_ms(os:timestamp()),
                type         = Type,
                exchange     = X,
                queue        = Q,
                node         = Node,
                connection   = Conn,
                vhost        = VHost,
                username     = User,
                channel      = Chan,
                routing_keys = [K || {_, K} <- Keys],
                routed_queues= RQs,
                properties   = Props,
                payload      = Payload}.

log(text, P, Record) ->
    Fmt = "~n~s~n~s: Message ~s~n~n"
        "Node:         ~s~nConnection:   ~s~n"
        "Virtual host: ~s~nUser:         ~s~n"
        "Channel:      ~p~nExchange:     ~s~n"
        "Routing keys: ~p~n" ++
        case Record#log_record.queue of
            none -> "";
            _    -> "Queue:        ~s~n"
        end ++
        case Record#log_record.routed_queues of
            none -> "";
            _    -> "Routed queues: ~p~n"
        end ++
        "Properties:   ~p~nPayload: ~n~s~n",
    Args =
        [string:copies("=", 80),    Record#log_record.timestamp,
         Record#log_record.type,
         Record#log_record.node,    Record#log_record.connection,
         Record#log_record.vhost,   Record#log_record.username,
         Record#log_record.channel, Record#log_record.exchange,
         Record#log_record.routing_keys] ++
        case Record#log_record.queue of
            none -> [];
            Q    -> [Q]
        end ++
        case Record#log_record.routed_queues of
            none -> [];
            RQs  -> [RQs]
        end ++
        [Record#log_record.properties, Record#log_record.payload],
    P(Fmt, Args);

log(json, P, Record) ->
    P("~s~n", [mochijson2:encode(
                 [{timestamp,    Record#log_record.timestamp},
                  {type,         Record#log_record.type},
                  {node,         Record#log_record.node},
                  {connection,   Record#log_record.connection},
                  {vhost,        Record#log_record.vhost},
                  {user,         Record#log_record.username},
                  {channel,      Record#log_record.channel},
                  {exchange,     Record#log_record.exchange},
                  {queue,        Record#log_record.queue},
                  {routed_queues, Record#log_record.routed_queues},
                  {routing_keys, Record#log_record.routing_keys},
                  {properties,   rabbit_mgmt_format:amqp_table(
                                   Record#log_record.properties)},
                  {payload,      base64:encode(Record#log_record.payload)}])]).
