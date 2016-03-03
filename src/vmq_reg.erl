%% Copyright 2014 Erlio GmbH Basel Switzerland (http://erl.io)
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(vmq_reg).
-include("vmq_server.hrl").
-behaviour(gen_server).
-export([dpe/1]).
%% API
-export([
         %% used in mqtt fsm handling
         subscribe/4,
         unsubscribe/4,
         register_subscriber/2,
         delete_subscriptions/1,
         %% used in mqtt fsm handling
         publish/1,

         %% used in :get_info/2
         get_session_pids/1,
         get_queue_pid/1,

         %% used in vmq_server_utils
         total_subscriptions/0,
         retained/0,

         stored/1,
         status/1,

         migrate_offline_queues/1,
         fix_dead_queues/2

        ]).

%% gen_server
-export([start_link/0,
         init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

%% called by vmq_cluster_com
-export([publish/2]).

%% used from plugins
-export([direct_plugin_exports/1]).
%% used by reg views
-export([subscribe_subscriber_changes/0,
         fold_subscriptions/2,
         fold_subscribers/2]).
%% used by vmq_mqtt_fsm list_sessions
-export([fold_sessions/2]).

%% exported because currently used by netsplit tests
-export([subscriptions_for_subscriber_id/1]).

-define(SUBSCRIBER_DB, {vmq, subscriber}).
-define(TOMBSTONE, '$deleted').
-define(NR_OF_REG_RETRIES, 10).

-spec subscribe(flag(), username() | plugin_id(), subscriber_id(),
                [{topic(), qos()}]) -> ok | {error, not_allowed
                                             | overloaded
                                             | not_ready}.

subscribe(false, User, SubscriberId, Topics) ->
    %% trade availability for consistency
    vmq_cluster:if_ready(fun subscribe_/3, [User, SubscriberId, Topics]);
subscribe(true, User, SubscriberId, Topics) ->
    %% trade consistency for availability
    subscribe_(User, SubscriberId, Topics).

subscribe_(User, SubscriberId, Topics) ->
    case vmq_plugin:all_till_ok(auth_on_subscribe,
                                [User, SubscriberId, Topics]) of
        ok ->
            subscribe_op(User, SubscriberId, Topics);
        {ok, NewTopics} when is_list(NewTopics) ->
            subscribe_op(User, SubscriberId, NewTopics);
        {error, _} ->
            {error, not_allowed}
    end.

subscribe_op(User, SubscriberId, Topics) ->
    rate_limited_op(
      fun() ->
              add_subscriber(Topics, SubscriberId)
      end,
      fun(_) ->
              _ = [begin
                       _ = vmq_exo:incr_subscription_count(),
                       deliver_retained(SubscriberId, T, QoS)
                   end || {T, QoS} <- Topics],
              vmq_plugin:all(on_subscribe, [User, SubscriberId, Topics]),
              ok
      end).

-spec unsubscribe(flag(), username() | plugin_id(),
                  subscriber_id(), [topic()]) -> ok | {error, overloaded
                                                       | not_ready}.
unsubscribe(false, User, SubscriberId, Topics) ->
    %% trade availability for consistency
    vmq_cluster:if_ready(fun unsubscribe_op/3, [User, SubscriberId, Topics]);
unsubscribe(true, User, SubscriberId, Topics) ->
    %% trade consistency for availability
    unsubscribe_op(User, SubscriberId, Topics).

unsubscribe_op(User, SubscriberId, Topics) ->
    TTopics =
    case vmq_plugin:all_till_ok(on_unsubscribe, [User, SubscriberId, Topics]) of
        ok ->
            Topics;
        {ok, [[W|_]|_] = NewTopics} when is_binary(W) ->
            NewTopics;
        {error, _} ->
            Topics
    end,
    rate_limited_op(
      fun() ->
              del_subscriptions(TTopics, SubscriberId)
      end,
      fun(_) ->
              _ = [vmq_exo:decr_subscription_count() || _ <- TTopics],
              ok
      end).

delete_subscriptions(SubscriberId) ->
    del_subscriber(SubscriberId).

-spec register_subscriber(subscriber_id(), map()) ->
    {ok, pid()} | {error, _}.
register_subscriber(SubscriberId, #{allow_multiple_sessions := false} = QueueOpts) ->
    %% we don't allow multiple sessions using same subscriber id
    %% allow_multiple_sessions is needed for session balancing
    case jobs:ask(plumtree_queue) of
        {ok, JobId} ->
            try
                vmq_reg_leader:register_subscriber(self(), SubscriberId, QueueOpts)
            after
                jobs:done(JobId)
            end;
        {error, rejected} ->
            {error, overloaded}
    end;
register_subscriber(SubscriberId, #{allow_multiple_sessions := true} = QueueOpts) ->
    %% we allow multiple sessions using same subscriber id
    %%
    %% !!! CleanSession is disabled if multiple sessions are in use
    %%
    case jobs:ask(plumtree_queue) of
        {ok, JobId} ->
            try
                register_session(SubscriberId, QueueOpts)
            after
                jobs:done(JobId)
            end;
        {error, rejected} ->
            {error, overloaded}
    end.

-spec register_subscriber(pid() | undefined,
                            subscriber_id(), map(),
                            non_neg_integer()) -> {'ok', pid()}.
register_subscriber(_, _, _, 0) ->
    exit(register_subscriber_retry_exhausted);
register_subscriber(SessionPid, SubscriberId, QueueOpts, N) ->
    % remap subscriber... enabling that new messages will eventually
    % reach the new queue.
    maybe_remap_subscriber(SessionPid, SubscriberId, QueueOpts),
    % wont create new queue in case it already exists
    {ok, QPid} = vmq_queue_sup:start_queue(SubscriberId),
    case vmq_cluster:nodes() -- [node()] of
        [] ->
            ok;
        Nodes ->
            %% TODO: make this more efficient, currently we have to multi_call
            %% REMARK: migrate_session makes sure that offline messages located at
            %% one or more remote queues are migrated to this Queue,
            %% if the last session attached to this queue was using clean_session=true
            %% migrate_session will instead drop all stored messages before teardown
            %% the queue
            Req = {migrate_session, SubscriberId, QPid},
            case gen_server:multi_call(Nodes, ?MODULE, Req) of
                {Replies, []} ->
                    rethrow_error(Replies);
                {Replies, BadNodes} ->
                    rethrow_error(Replies),
                    lager:error("can't migrate session for subscriber ~p on nodes ~p",
                                [SubscriberId, BadNodes]),
                    exit(cant_reach_nodes_during_migration)
            end
    end,
    case SessionPid of
        undefined ->
            %% SessionPid can be 'undefined' in case an offline session gets
            %% forcefully migrated
            lager:info("created 'offline' queue ~p for ~p", [SubscriberId, QPid]),
            {ok, QPid};
        _ ->
            case catch vmq_queue:add_session(QPid, SessionPid, QueueOpts) of
                {'EXIT', {normal, _}} ->
                    %% queue went down in the meantime, retry
                    register_subscriber(SessionPid, SubscriberId, QueueOpts, N -1);
                {'EXIT', {noproc, _}} ->
                    timer:sleep(100),
                    %% queue was stopped in the meantime, retry
                    register_subscriber(SessionPid, SubscriberId, QueueOpts, N -1);
                {'EXIT', Reason} ->
                    exit(Reason);
                ok ->
                    {ok, QPid}
            end
    end.

rethrow_error([{_, {error, Reason}}|_]) -> exit(Reason);
rethrow_error([{_, ok}|Replies]) ->
    rethrow_error(Replies);
rethrow_error([]) -> ok.

-spec register_session(subscriber_id(), map()) -> {ok, pid()}.
register_session(SubscriberId, QueueOpts) ->
    %% register_session allows to have multiple subscribers connected
    %% with the same session_id (as oposed to register_subscriber)
    SessionPid = self(),
    {ok, QPid} = vmq_queue_sup:start_queue(SubscriberId), % wont create new queue in case it already exists
    ok = vmq_queue:add_session(QPid, SessionPid, QueueOpts),
    {ok, QPid}.

-spec publish(msg()) -> 'ok' | {'error', _}.
publish(#vmq_msg{trade_consistency=true,
                 reg_view=RegView,
                 mountpoint=MP,
                 routing_key=Topic,
                 payload=Payload,
                 retain=IsRetain} = Msg) ->
    %% trade consistency for availability
    %% if the cluster is not consistent at the moment, it is possible
    %% that subscribers connected to other nodes won't get this message
    case IsRetain of
        true when Payload == <<>> ->
            %% retain delete action
            vmq_retain_srv:delete(MP, Topic);
        true ->
            %% retain set action
            vmq_retain_srv:insert(MP, Topic, Payload),
            RegView:fold(MP, Topic, fun publish/2, Msg#vmq_msg{retain=false}),
            ok;
        false ->
            RegView:fold(MP, Topic, fun publish/2, Msg),
            ok
    end;
publish(#vmq_msg{trade_consistency=false,
                 reg_view=RegView,
                 mountpoint=MP,
                 routing_key=Topic,
                 payload=Payload,
                 retain=IsRetain} = Msg) ->
    %% don't trade consistency for availability
    case vmq_cluster:is_ready() of
        true when (IsRetain == true) and (Payload == <<>>) ->
            %% retain delete action
            vmq_retain_srv:delete(MP, Topic);
        true when (IsRetain == true) ->
            %% retain set action
            vmq_retain_srv:insert(MP, Topic, Payload),
            RegView:fold(MP, Topic, fun publish/2, Msg#vmq_msg{retain=false}),
            ok;
        true ->
            RegView:fold(MP, Topic, fun publish/2, Msg),
            ok;
        false ->
            {error, not_ready}
    end.

%% publish/2 is used as the fold function in RegView:fold/4
publish({SubscriberId, QoS}, Msg) ->
    publish(Msg, QoS, get_queue_pid(SubscriberId));
publish(Node, Msg) ->
    case vmq_cluster:publish(Node, Msg) of
        ok ->
            Msg;
        {error, Reason} ->
            lager:warning("can't publish to remote node ~p due to '~p'", [Node, Reason]),
            Msg
    end.

publish(Msg, _, not_found) -> Msg;
publish(Msg, QoS, QPid) ->
    ok = vmq_queue:enqueue(QPid, {deliver, QoS, Msg}),
    Msg.

-spec deliver_retained(subscriber_id(), topic(), qos()) -> 'ok'.
deliver_retained({MP, _} = SubscriberId, Topic, QoS) ->
    QPid = get_queue_pid(SubscriberId),
    vmq_retain_srv:match_fold(
      fun ({T, Payload}, _) ->
              Msg = #vmq_msg{routing_key=T,
                             payload=Payload,
                             retain=true,
                             qos=QoS,
                             dup=false,
                             mountpoint=MP,
                             msg_ref=vmq_mqtt_fsm:msg_ref()},
              vmq_queue:enqueue(QPid, {deliver, QoS, Msg})
      end, ok, MP, Topic).

subscriptions_for_subscriber_id(SubscriberId) ->
    plumtree_metadata:get(?SUBSCRIBER_DB, SubscriberId, [{default, []}]).

migrate_offline_queues([]) -> exit(no_target_available);
migrate_offline_queues(Targets) ->
    {_, NrOfQueues, TotalMsgs} = vmq_queue_sup:fold_queues(fun migrate_offline_queue/3, {Targets, 0, 0}),
    lager:info("MIGRATION SUMMARY: ~p queues migrated, ~p messages", [NrOfQueues, TotalMsgs]),
    ok.

migrate_offline_queue(SubscriberId, QPid, {[Target|Targets], AccQs, AccMsgs} = Acc) ->
    try vmq_queue:status(QPid) of
        {_, _, _, _, true} ->
            %% this is a queue belonging to a plugin.. ignore it.
            Acc;
        {offline, _, TotalStoredMsgs, _, _} ->
            OldNode = node(),
            %% Remap Subscriptions, taking into account subscriptions
            %% on other nodes by only remapping subscriptions on 'OldNode'
            case plumtree_metadata:get(?SUBSCRIBER_DB, SubscriberId) of
                undefined ->
                    ignore;
                [] ->
                    ignore;
                Subs ->
                    NewSubs =
                    lists:foldl(
                      fun({Topic, QoS, Node}, SubsAcc) when Node == OldNode ->
                              [{Topic, QoS, Target}|SubsAcc];
                         (Sub, SubsAcc) ->
                              [Sub|SubsAcc]
                      end, [], Subs),
                    plumtree_metadata:put(?SUBSCRIBER_DB, SubscriberId, lists:usort(NewSubs))
            end,
            QueueOpts = vmq_queue:get_opts(QPid),
            Req = {migrate_offline_queue, SubscriberId,
                   maps:put(clean_session, false, QueueOpts)},
            case gen_server:call({?MODULE, Target}, Req, infinity) of
                ok ->
                    MRef = monitor(process, QPid),
                    receive
                        {'DOWN', MRef, process, QPid, _} ->
                            ok
                    end,
                    {Targets ++ [Target], AccQs + 1, AccMsgs + TotalStoredMsgs};
                {error, not_ready} ->
                    timer:sleep(100),
                    {Targets ++ [Target], AccQs, AccMsgs}
            end;
        _ ->
            Acc
    catch
        _:_ ->
            %% queue stopped in the meantime, that's ok.
            Acc
    end.

fix_dead_queues(_, []) -> exit(no_target_available);
fix_dead_queues(DeadNodes, AccTargets) ->
    %% DeadNodes must be a list of offline VerneMQ nodes
    %% Targets must be a list of online VerneMQ nodes
    {_, _, N} = fold_subscribers(fun fix_dead_queue/3, {DeadNodes, AccTargets, 0}, false),
    lager:info("FIX DEAD QUEUES SUMMARY: ~p queues fixed", [N]).

fix_dead_queue(SubscriberId, Subs, {DeadNodes, [Target|Targets], N}) ->
    %%% Why not use maybe_remap_subscriber/3:
    %%%  it is possible that the original subscriber has used
    %%%  allow_multiple_sessions=true
    %%%
    %%%  we only remap the subscriptions on dead nodes
    %%%  and ensure that a queue exist for such subscriptions.
    %%%  In case allow_multiple_sessions=false (default) all
    %%%  subscriptions will be remapped
    {NewSubs, HasChanged} =
    lists:foldl(
      fun({Topic, QoS, Node} = S, {AccSubs, Changed}) ->
              case lists:member(Node, DeadNodes) of
                  true ->
                      {[{Topic, QoS, Target}|AccSubs], true};
                  false ->
                      {[S|AccSubs], Changed}
              end
      end, {[], false}, Subs),
    case HasChanged of
        true ->
            plumtree_metadata:put(?SUBSCRIBER_DB, SubscriberId, lists:usort(NewSubs)),
            QueueOpts = vmq_queue:default_opts(),
            Req = {migrate_offline_queue, SubscriberId, QueueOpts},
            case gen_server:call({?MODULE, Target}, Req, infinity) of
                ok ->
                    lager:info("MIGRATE QUEUE for subscriber ~p to node ~p", [SubscriberId, Target]),
                    {DeadNodes, Targets ++ [Target], N + 1};
                {error, not_ready} ->
                    {DeadNodes, Targets ++ [Target], N}
            end;
        false ->
            {DeadNodes, Targets, N}
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% GEN_SERVER,
%%%
%%%  this gen_server is mainly used to allow remote control over local
%%%  registry entries.. alternatively the rpc module could have been
%%%  used, however this allows us more control over how such remote
%%%  calls are handled. (in fact version prior to 0.12.0 used rpc directly.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    {ok, maps:new()}.

handle_call({migrate_session, SubscriberId, OtherQPid}, From, Waiting) ->
    %% Initiates Queue migration of the local Queue to the
    %% Queue at 'OtherQPid'
    case get_queue_pid(SubscriberId) of
        not_found ->
            {reply, ok, Waiting};
        QPid ->
            {MigratePid, MRef} = spawn_monitor(vmq_queue, migrate, [QPid, OtherQPid]),
            {noreply, maps:put(MRef, {MigratePid, From}, Waiting)}
    end;
handle_call({finish_register_subscriber_by_leader, SessionPid, SubscriberId, QueueOpts}, From, Waiting) ->
    %% called by vmq_reg_leader process
    {Pid, MRef} = spawn_monitor(
                    fun() ->
                            register_subscriber(SessionPid, SubscriberId,
                                                QueueOpts, ?NR_OF_REG_RETRIES)
                    end),
    {noreply, maps:put(MRef, {Pid, From}, Waiting)};
handle_call({migrate_offline_queue, SubscriberId, QueueOpts}, From, Waiting) ->
    %% only called when a cluster node leaves and the 'old' offline
    %% queues have to be migrated to 'this' node.
    %%
    %% calling register_subscriber/2 will ensure that the Queue exists
    %% on this node, as well as it will migrate all offline stored messages
    %% to this new queue.
    %% Moreover, register_subscriber/2 is synchronized via vmq_reg_leader,
    %% allowing a consistent state over the migration process.
    %%
    %% REMARK: this mechanism ignores new subscribers with the
    %% allow_multiple_sessions=true. In such a case the new queue process,
    %% containing offline messages, will stay around until a subscribers
    %% connects to this node or a subscriber connects with
    %% allow_multiple_sessions=off
    %%
    %% TODO: provide a way that subscribers with allow_multiple_sessions=on
    %% can synchronize their offline messages.
    case vmq_cluster:is_ready() of
        true ->
            {RegisterPid, MRef} = spawn_monitor(vmq_reg_leader, register_subscriber,
                                                [undefined, SubscriberId, QueueOpts]),
            {noreply, maps:put(MRef, {RegisterPid, From}, Waiting)};
        false ->
            {reply, {error, not_ready}, Waiting}
    end.

handle_cast(_Req, State) ->
    {noreply, State}.

handle_info({'DOWN', MRef, process, Pid, Reason}, Waiting) ->
    {Pid, From} = maps:get(MRef, Waiting),
    case Reason of
        normal ->
            gen_server:reply(From, ok);
        _ ->
            gen_server:reply(From, {error, Reason})
    end,
    {noreply, maps:remove(MRef, Waiting)}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


-spec wait_til_ready() -> 'ok'.
wait_til_ready() ->
    case catch vmq_cluster:if_ready(fun() -> true end, []) of
        true ->
            ok;
        _ ->
            timer:sleep(100),
            wait_til_ready()
    end.

-spec direct_plugin_exports(module()) -> {function(), function(), {function(), function()}} | {error, invalid_config}.
direct_plugin_exports(Mod) when is_atom(Mod) ->
    %% This Function exports a generic Register, Publish, and Subscribe
    %% Fun, that a plugin can use if needed. Currently all functions
    %% block until the cluster is ready.
    case {vmq_config:get_env(trade_consistency, false),
          vmq_config:get_env(default_reg_view, vmq_reg_trie)} of
        {TradeConsistency, DefaultRegView}
              when is_boolean(TradeConsistency)
                   and is_atom(DefaultRegView) ->
            MountPoint = "",
            ClientId = fun(T) ->
                               list_to_binary(
                                 base64:encode_to_string(
                                   integer_to_binary(
                                     erlang:phash2(T)
                                    )
                                  ))
                       end,
            CallingPid = self(),
            SubscriberId = {MountPoint, ClientId(CallingPid)},
            User = {plugin, Mod, CallingPid},

            RegisterFun =
            fun() ->
                    PluginPid = self(),
                    wait_til_ready(),
                    PluginSessionPid = spawn_link(
                                         fun() ->
                                                 monitor(process, PluginPid),
                                                 plugin_queue_loop(PluginPid, Mod)
                                         end),
                    QueueOpts = maps:merge(vmq_queue:default_opts(),
                                           #{clean_session => true,
                                             is_plugin => true}),
                    {ok, _} = register_subscriber(PluginSessionPid, SubscriberId,
                                                  QueueOpts, ?NR_OF_REG_RETRIES),
                    ok
            end,

            PublishFun =
            fun([W|_] = Topic, Payload) when is_binary(W) and is_binary(Payload) ->
                    wait_til_ready(),
                    Msg = #vmq_msg{routing_key=Topic,
                                   mountpoint=MountPoint,
                                   payload=Payload,
                                   msg_ref=vmq_mqtt_fsm:msg_ref(),
                                   dup=false,
                                   retain=false,
                                   trade_consistency=TradeConsistency,
                                   reg_view=DefaultRegView
                                  },
                    publish(Msg)
            end,

            SubscribeFun =
            fun([W|_] = Topic) when is_binary(W) ->
                    wait_til_ready(),
                    CallingPid = self(),
                    User = {plugin, Mod, CallingPid},
                    subscribe(TradeConsistency, User,
                              {MountPoint, ClientId(CallingPid)}, [{Topic, 0}]);
               (_) ->
                    {error, invalid_topic}
            end,

            UnsubscribeFun =
            fun([W|_] = Topic) when is_binary(W) ->
                    wait_til_ready(),
                    CallingPid = self(),
                    User = {plugin, Mod, CallingPid},
                    unsubscribe(TradeConsistency, User,
                                {MountPoint, ClientId(CallingPid)}, [Topic]);
               (_) ->
                    {error, invalid_topic}
            end,
            {RegisterFun, PublishFun, {SubscribeFun, UnsubscribeFun}};
        _ ->
            {error, invalid_config}
    end.

-spec dpe(module()) -> {function()} | {error}.
dpe(Mod) when is_atom(Mod) ->
    %% This Function exports a generic Register, Publish, and Subscribe
    %% Fun, that a plugin can use if needed. Currently all functions
    %% block until the cluster is ready.
    case {vmq_config:get_env(trade_consistency, false),
          vmq_config:get_env(default_reg_view, vmq_reg_trie)} of
        {TradeConsistency, DefaultRegView}
              when is_boolean(TradeConsistency)
                   and is_atom(DefaultRegView) ->
            MountPoint = "",
			PublishFun1 =
            fun([W|_] = Topic, Payload,Qos,Retain) when is_binary(W) and is_binary(Payload) ->
                    wait_til_ready(),
                    Msg = #vmq_msg{routing_key=Topic,
                                   mountpoint=MountPoint,
                                   payload=Payload,
								   qos=Qos,
                                   msg_ref=vmq_mqtt_fsm:msg_ref(),
                                   dup=false,
                                   retain=Retain,
                                   trade_consistency=TradeConsistency,
                                   reg_view=DefaultRegView
                                  },
                    publish(Msg)
            end,
			{PublishFun1};
	_ ->
		{error}
 end.
		
plugin_queue_loop(PluginPid, PluginMod) ->
    receive
        {vmq_mqtt_fsm, {mail, QPid, new_data}} ->
            vmq_queue:active(QPid),
            plugin_queue_loop(PluginPid, PluginMod);
        {vmq_mqtt_fsm, {mail, QPid, Msgs, _, _}} ->
            lists:foreach(fun({deliver, QoS, #vmq_msg{
                                                routing_key=RoutingKey,
                                                payload=Payload,
                                                retain=IsRetain,
                                                dup=IsDup}}) ->
                                  PluginPid ! {deliver, RoutingKey,
                                               Payload,
                                               QoS,
                                               IsRetain,
                                               IsDup};
                             (Msg) ->
                                  lager:warning("drop message ~p for plugin ~p", [Msg, PluginMod]),
                                  ok
                          end, Msgs),
            vmq_queue:notify(QPid),
            plugin_queue_loop(PluginPid, PluginMod);
        {info_req, {Ref, CallerPid}, _} ->
            CallerPid ! {Ref, {error, i_am_a_plugin}},
            plugin_queue_loop(PluginPid, PluginMod);
        disconnect ->
            ok;
        {'DOWN', _MRef, process, PluginPid, Reason} ->
            case (Reason == normal) or (Reason == shutdown) of
                true ->
                    ok;
                false ->
                    lager:warning("Plugin Queue Loop for ~p stopped due to ~p", [PluginMod, Reason])
            end;
        Other ->
            exit({unknown_msg_in_plugin_loop, Other})
    end.


subscribe_subscriber_changes() ->
    plumtree_metadata_manager:subscribe(?SUBSCRIBER_DB),
    fun
        ({deleted, ?SUBSCRIBER_DB, _, Val})
          when (Val == ?TOMBSTONE) or (Val == undefined) ->
            ignore;
        ({deleted, ?SUBSCRIBER_DB, SubscriberId, Subscriptions}) ->
            {delete, SubscriberId, Subscriptions};
        ({updated, ?SUBSCRIBER_DB, SubscriberId, OldVal, NewSubs})
          when (OldVal == ?TOMBSTONE) or (OldVal == undefined) ->
            {update, SubscriberId, [], NewSubs};
        ({updated, ?SUBSCRIBER_DB, SubscriberId, OldSubs, NewSubs}) ->
            {update, SubscriberId, OldSubs -- NewSubs, NewSubs -- OldSubs};
        (_) ->
            ignore
    end.


fold_subscriptions(FoldFun, Acc) ->
    Node = node(),
    fold_subscribers(
      fun ({MP, _} = SubscriberId, Subs, AccAcc) ->
              lists:foldl(
                fun({Topic, QoS, N}, AccAccAcc) when Node == N ->
                        FoldFun({MP, Topic, {SubscriberId, QoS, undefined}},
                                        AccAccAcc);
                   ({Topic, _, N}, AccAccAcc) ->
                        FoldFun({MP, Topic, N}, AccAccAcc)
                end, AccAcc, Subs)
      end, Acc, false).

fold_subscribers(FoldFun, Acc) ->
    fold_subscribers(FoldFun, Acc, true).

fold_subscribers(FoldFun, Acc, CompactResult) ->
    plumtree_metadata:fold(
      fun ({_, ?TOMBSTONE}, AccAcc) -> AccAcc;
          ({SubscriberId, Subs}, AccAcc) when CompactResult ->
              FoldFun(SubscriberId, subscriber_nodes(Subs), AccAcc);
          ({SubscriberId, Subs}, AccAcc) ->
              FoldFun(SubscriberId, Subs, AccAcc)
      end, Acc, ?SUBSCRIBER_DB,
      [{resolver, lww}]).

%% returns the nodes a subscriber was active
subscriber_nodes(Subs) ->
    subscriber_nodes(Subs, []).
subscriber_nodes([], Nodes) -> Nodes;
subscriber_nodes([{_, _, Node}|Rest], Nodes) ->
    case lists:member(Node, Nodes) of
        true ->
            subscriber_nodes(Rest, Nodes);
        false ->
            subscriber_nodes(Rest, [Node|Nodes])
    end.

fold_sessions(FoldFun, Acc) ->
    vmq_queue_sup:fold_queues(
      fun(SubscriberId, QPid, AccAcc) ->
              lists:foldl(
                fun(SessionPid, AccAccAcc) ->
                        FoldFun(SubscriberId, SessionPid, AccAccAcc)
                end, AccAcc, vmq_queue:get_sessions(QPid))
      end, Acc).

-spec add_subscriber([{topic(), qos()}], subscriber_id()) -> ok.
add_subscriber(Topics, SubscriberId) ->
    NewSubs =
    case plumtree_metadata:get(?SUBSCRIBER_DB, SubscriberId) of
        undefined ->
            [{Topic, QoS, node()} || {Topic, QoS} <- Topics];
        Subs ->
            lists:foldl(fun({Topic, QoS}, NewSubsAcc) ->
                                NewSub = {Topic, QoS, node()},
                                case lists:member(NewSub, NewSubsAcc) of
                                    true -> NewSubsAcc;
                                    false ->
                                        [NewSub|NewSubsAcc]
                                end
                        end, Subs, Topics)
    end,
    plumtree_metadata:put(?SUBSCRIBER_DB, SubscriberId, NewSubs).


-spec del_subscriber(subscriber_id()) -> ok.
del_subscriber(SubscriberId) ->
    plumtree_metadata:delete(?SUBSCRIBER_DB, SubscriberId).

-spec del_subscriptions([topic()], subscriber_id()) -> ok.
del_subscriptions(Topics, SubscriberId) ->
    Subs = plumtree_metadata:get(?SUBSCRIBER_DB, SubscriberId, [{default, []}]),
    NewSubs =
    lists:foldl(fun({Topic, _, Node} = Sub, NewSubsAcc) ->
                        case Node == node() of
                            true ->
                                case lists:member(Topic, Topics) of
                                    true ->
                                        NewSubsAcc;
                                    false ->
                                        [Sub|NewSubsAcc]
                                end;
                            false ->
                                [Sub|NewSubsAcc]
                        end
                end, [], Subs),
    plumtree_metadata:put(?SUBSCRIBER_DB, SubscriberId, NewSubs).

maybe_remap_subscriber(undefined, _, _) ->
    %% coming via queue migration, remaping was done inside
    %% migrate_offline_queue or fix_dead_queues
    ok;
maybe_remap_subscriber(_, SubscriberId, #{clean_session := true}) ->
    %% no need to remap, we can delete this subscriber
    del_subscriber(SubscriberId);
maybe_remap_subscriber(_, SubscriberId, _) ->
    Subs = plumtree_metadata:get(?SUBSCRIBER_DB, SubscriberId, [{default, []}]),
    Node = node(),
    {NewSubs, HasChanged} =
    lists:foldl(fun({Topic, QoS, N}, {Acc, _}) when N =/= Node ->
                        {[{Topic, QoS, Node}|Acc], true};
                   (Sub, {Acc, Changed}) ->
                        {[Sub|Acc], Changed}
                end, {[], false}, Subs),
    case HasChanged of
        true ->
            plumtree_metadata:put(?SUBSCRIBER_DB, SubscriberId, lists:usort(NewSubs));
        false ->
            ignore
    end,
    ok.

-spec get_session_pids(subscriber_id()) ->
    {'error','not_found'} | {'ok', pid(), [pid()]}.
get_session_pids(SubscriberId) ->
    case get_queue_pid(SubscriberId) of
        not_found ->
            {error, not_found};
        QPid ->
            Pids = vmq_queue:get_sessions(QPid),
            {ok, QPid, Pids}
    end.

-spec get_queue_pid(subscriber_id()) -> pid() | not_found.
get_queue_pid(SubscriberId) ->
    vmq_queue_sup:get_queue_pid(SubscriberId).

total_subscriptions() ->
    Total = plumtree_metadata:fold(
              fun ({_, ?TOMBSTONE}, Acc) -> Acc;
                  ({_, Subs}, Acc) ->
                      Acc + length(Subs)
              end, 0, ?SUBSCRIBER_DB,
              [{resolver, lww}]),
    [{total, Total}].

-spec retained() -> non_neg_integer().
retained() ->
    vmq_retain_srv:size().

stored(SubscriberId) ->
    case get_queue_pid(SubscriberId) of
        not_found -> 0;
        QPid ->
            {_, _, Queued, _, _} = vmq_queue:status(QPid),
            Queued
    end.

status(SubscriberId) ->
    case get_queue_pid(SubscriberId) of
        not_found -> {error, not_found};
        QPid ->
            {ok, vmq_queue:status(QPid)}
    end.

-spec rate_limited_op(fun(() -> any()),
                      fun((any()) -> any())) -> any() | {error, overloaded}.
rate_limited_op(OpFun, SuccessFun) ->
    case jobs:ask(plumtree_queue) of
        {ok, JobId} ->
            try
                SuccessFun(OpFun())
            after
                jobs:done(JobId)
            end;
        {error, rejected} ->
            {error, overloaded}
    end.
