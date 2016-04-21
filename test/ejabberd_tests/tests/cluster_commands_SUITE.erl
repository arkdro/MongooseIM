%%==============================================================================
%% Copyright 2014 Erlang Solutions Ltd.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%==============================================================================

-module(cluster_commands_SUITE).
-compile(export_all).

-import(distributed_helper, [add_node_to_cluster/1, rpc/5,
        remove_node_from_cluster/1, is_sm_distributed/0]).
-import(ejabberdctl_helper, [ejabberdctl/3, rpc_call/3]).
-import(ejabberd_node_utils, [mim/0, mim2/0, fed/0]).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-define(LOCAL_NODE, mim()).
-define(eq(Expected, Actual), ?assertEqual(Expected, Actual)).
-define(ne(A, B), ?assertNot(A == B)).

%%--------------------------------------------------------------------
%% Suite configuration
%%--------------------------------------------------------------------

all() ->
    [
%%        {group, clustered},
%%        {group, ejabberdctl},
%%        {group, clustering_two},
        {group, clustering_theree}].
groups() ->
    [
%%        {clustered, [], [one_to_one_message]},
%%        {clustering_two, [],
%%            [join_successful,
%%            leave_successful,
%%            join_unsuccessful,
%%            leave_unsuccessful,
%%            leave_but_no_cluster,
%%            join_twice,
%%            leave_twice]},
        {clustering_theree, [shuffle],
            [cluster_of_theree, leave_the_theree,
             remove_dead_from_cluster]}
%%        ,
%%        {ejabberdctl, [], [set_master_test]}
    ].
suite() ->
    require_all_nodes() ++
    escalus:suite().

require_all_nodes() ->
    [{require, mim_node, {hosts, mim, node}},
     {require, mim_node2, {hosts, mim2, node}},
     {require, fed_node, {hosts, fed, node}}].

%%--------------------------------------------------------------------
%% Init & teardown
%%--------------------------------------------------------------------

init_per_suite(Config) ->
    Node1 = mim(),
    Node2 = mim2(),
    Node3 = fed(),
    Config1 = ejabberd_node_utils:init(Node1, Config),
    Config2 = ejabberd_node_utils:init(Node2, Config1),
    Config3 = ejabberd_node_utils:init(Node3, Config2),
    ejabberd_node_utils:backup_config_file(Node2, Config3),
    ejabberd_node_utils:backup_config_file(Node3, Config3),
    MainDomain = ct:get_config({hosts, mim, domain}),
    Ch = [{hosts, "[\"" ++ binary_to_list(MainDomain) ++ "\"]"}],
    ejabberd_node_utils:modify_config_file(Node2, "reltool_vars/node2_vars.config", Ch, Config3),
    ejabberd_node_utils:call_ctl(Node2, reload_local, Config2),
    ejabberd_node_utils:modify_config_file(Node3, "reltool_vars/fed1_vars.config", Ch, Config3),
    ejabberd_node_utils:call_ctl(Node3, reload_local, Config2),
    NodeCtlPath = distributed_helper:ctl_path(Node1, Config3),
    Node2CtlPath = distributed_helper:ctl_path(Node2, Config3),
    Node3CtlPath = distributed_helper:ctl_path(Node3, Config3),
    escalus:init_per_suite([{ctl_path_atom(Node1), NodeCtlPath},
        {ctl_path_atom(Node2), Node2CtlPath},
        {ctl_path_atom(Node3), Node3CtlPath}]
    ++ Config3).

end_per_suite(Config) ->
    Node2 = mim2(),
    Node3 = fed(),
    ejabberd_node_utils:restore_config_file(Node2, Config),
    ejabberd_node_utils:restore_config_file(Node3, Config),
    ejabberd_node_utils:restart_application(Node2, ejabberd),
    ejabberd_node_utils:restart_application(Node3, ejabberd),
    escalus:end_per_suite(Config).

init_per_group(Group, Config) when Group == clustered orelse Group == ejabberdctl ->
    Config1 = add_node_to_cluster(Config),
    case is_sm_distributed() of
        true ->
            escalus:create_users(Config1, escalus:get_users([alice, clusterguy]));
        {false, Backend} ->
            ct:pal("Backend ~p doesn't support distributed tests", [Backend]),
            remove_node_from_cluster(Config1),
            {skip, nondistributed_sm}
    end;

init_per_group(Group, _Config) when Group == clustering_two orelse Group == clustering_theree ->
    case is_sm_distributed() of
        true ->
            ok;
        {false, Backend} ->
            ct:pal("Backend ~p doesn't support distributed tests", [Backend]),
            {skip, nondistributed_sm}
    end;

init_per_group(_GroupName, Config) ->
    escalus:create_users(Config).

end_per_group(Group, Config) when Group == clustered orelse Group == ejabberdctl ->
    escalus:delete_users(Config, escalus:get_users([alice, clusterguy])),
    remove_node_from_cluster(Config);

%% Users are gone after mnesia cleaning
%% hence there is no need to delete them manually
end_per_group(Group, _Config) when Group == clustering_two orelse Group == clustering_theree ->
    ok;
end_per_group(_GroupName, Config) ->
    escalus:delete_users(Config).

init_per_testcase(CaseName, Config) ->
    escalus:init_per_testcase(CaseName, Config).

end_per_testcase(cluster_of_theree, Config) ->
    Timeout = timer:seconds(60),
    Node2 = mim2(),
    Node3 = fed(),
    ok = rpc(Node2, mongoose_cluster, leave, [], Timeout),
    ok = rpc(Node3, mongoose_cluster, leave, [], Timeout),
    escalus:end_per_testcase(cluster_of_theree, Config);

end_per_testcase(remove_dead_from_cluster, Config) ->
    Timeout = timer:seconds(60),
    Node = mim2(),
    start_node(Node, Config),
    ok = rpc(Node, mongoose_cluster, leave, [], Timeout),
    escalus:end_per_testcase(cluster_of_theree, Config);

end_per_testcase(CaseName, Config) when CaseName == join_successful
                                   orelse CaseName == leave_unsuccessful
                                   orelse CaseName == join_twice ->
    remove_node_from_cluster(Config),
    escalus:end_per_testcase(CaseName, Config);

end_per_testcase(CaseName, Config) ->
    escalus:end_per_testcase(CaseName, Config).

%%--------------------------------------------------------------------
%% Message tests
%%--------------------------------------------------------------------

one_to_one_message(ConfigIn) ->
    %% Given Alice connected to node one and ClusterGuy connected to node two
    Metrics = [{[data, dist], [{recv_oct, '>'}, {send_oct, '>'}]}],
    Config = [{mongoose_metrics, Metrics} | ConfigIn],
    escalus:story(Config, [{alice, 1}, {clusterguy, 1}], fun(Alice, ClusterGuy) ->
        %% When Alice sends a message to ClusterGuy
        Msg1 = escalus_stanza:chat_to(ClusterGuy, <<"Hi!">>),
        escalus:send(Alice, Msg1),
        %% Then he receives it
        Stanza1 = escalus:wait_for_stanza(ClusterGuy, 5000),
        escalus:assert(is_chat_message, [<<"Hi!">>], Stanza1),

        %% When ClusterGuy sends a response
        Msg2 = escalus_stanza:chat_to(Alice, <<"Oh hi!">>),
        escalus:send(ClusterGuy, Msg2),
        %% Then Alice also receives it
        Stanza2 = escalus:wait_for_stanza(Alice, 5000),
        escalus:assert(is_chat_message, [<<"Oh hi!">>], Stanza2)
    end).
%%--------------------------------------------------------------------
%% Ejabberdctl tests
%%--------------------------------------------------------------------

set_master_test(ConfigIn) ->
    TableName = passwd,
    NodeList = nodes(),
    ejabberdctl("set_master", ["self"], ConfigIn),
    [MasterNode] = rpc_call(mnesia, table_info, [TableName, master_nodes]),
    true = lists:member(MasterNode, NodeList),
    RestNodesList = lists:delete(MasterNode, NodeList),
    OtherNode = hd(RestNodesList),
    ejabberdctl("set_master", [atom_to_list(OtherNode)], ConfigIn),
    [OtherNode] = rpc_call(mnesia, table_info, [TableName, master_nodes]),
    ejabberdctl("set_master", ["self"], ConfigIn),
    [MasterNode] = rpc_call(mnesia, table_info, [TableName, master_nodes]).

join_successful(Config) ->
    %% given
    Node2 = mim2(),
    %% when
    {_, OpCode} = ejabberdctl_interactive("join_cluster", [atom_to_list(Node2)], "yes\n", Config),
    %% then
    distributed_helper:verify_result(add),
    ?eq(0, OpCode).

leave_successful(Config) ->
    %% given
    add_node_to_cluster(Config),
    %% when
    {_, OpCode} = ejabberdctl_interactive("leave_cluster", [], "yes\n", Config),
    %% then
    distributed_helper:verify_result(remove),
    ?eq(0, OpCode).

join_unsuccessful(Config) ->
    %% when
    {_, OpCode} = ejabberdctl_interactive("join_cluster", [], "no\n", Config),
    %% then
    distributed_helper:verify_result(remove),
    ?ne(0, OpCode).

leave_unsuccessful(Config) ->
    %% given
    add_node_to_cluster(Config),
    %% when
    {_, OpCode} = ejabberdctl_interactive("leave_cluster", [], "no\n", Config),
    %% then
    distributed_helper:verify_result(add),
    ?ne(0, OpCode).

leave_but_no_cluster(Config) ->
    %% when
    {_, OpCode} = ejabberdctl_interactive("leave_cluster", [], "yes\n", Config),
    %% then
    distributed_helper:verify_result(remove),
    ?ne(0, OpCode).

join_twice(Config) ->
    %% given
    Node2 = mim2(),
    %% when
    {_, OpCode1} = ejabberdctl_interactive("join_cluster", [atom_to_list(Node2)], "yes\n", Config),
    {_, OpCode2} = ejabberdctl_interactive("join_cluster", [atom_to_list(Node2)], "yes\n", Config),
    %% then
    distributed_helper:verify_result(add),
    ?eq(0, OpCode1),
    ?ne(0, OpCode2).

leave_twice(Config) ->
    %% given
    add_node_to_cluster(Config),
    %% when
    {_, OpCode1} = ejabberdctl_interactive("leave_cluster", [], "yes\n", Config),
    {_, OpCode2} = ejabberdctl_interactive("leave_cluster", [], "yes\n", Config),
    %% then
    distributed_helper:verify_result(remove),
    ?eq(0, OpCode1),
    ?ne(0, OpCode2).

cluster_of_theree(Config) ->
    %% given
    ClusterMember = mim(),
    Node2 = mim2(),
    Node3 = fed(),
    %% when
    {_, OpCode1} = ejabberdctl_interactive(Node2, "join_cluster", [atom_to_list(ClusterMember)], "yes\n", Config),
    {_, OpCode2} = ejabberdctl_interactive(Node3, "join_cluster", [atom_to_list(ClusterMember)], "yes\n", Config),
    %% then
    ?eq(0, OpCode1),
    ?eq(0, OpCode2),
    nodes_clustered(Node2, ClusterMember, true),
    nodes_clustered(Node3, ClusterMember, true),
    nodes_clustered(Node2, Node3, true).

leave_the_theree(Config) ->
    %% given
    Timeout = timer:seconds(60),
    ClusterMember = mim(),
    Node2 = mim2(),
    Node3 = fed(),
    ok = rpc(Node2, mongoose_cluster, join, [ClusterMember], Timeout),
    ok = rpc(Node3, mongoose_cluster, join, [ClusterMember], Timeout),
    %% when
    {_, OpCode1} = ejabberdctl_interactive(Node2, "leave_cluster", [], "yes\n", Config),
    nodes_clustered(Node2, ClusterMember, false),
    nodes_clustered(Node3, ClusterMember, true),
    {_, OpCode2} = ejabberdctl_interactive(Node3, "leave_cluster", [], "yes\n", Config),
    %% then
    nodes_clustered(Node3, ClusterMember, false),
    nodes_clustered(Node2, Node3, false),
    ?eq(0, OpCode1),
    ?eq(0, OpCode2).

remove_dead_from_cluster(Config) ->
    % given
    Timeout = timer:seconds(60),
    Node1 = mim(),
    Node2 = mim2(),
    Node3 = fed(),
    ok = rpc(Node2, mongoose_cluster, join, [Node1], Timeout),
    ok = rpc(Node3, mongoose_cluster, join, [Node1], Timeout),
    %% when
    stop_node(Node2, Config),
    {_, OpCode1} = ejabberdctl_helper:ejabberdctl("remove_from_cluster", [atom_to_list(Node2)], Config),
    %% then
    nodes_clustered(Node1, Node3, true),
    nodes_clustered(Node1, Node2, false),
    nodes_clustered(Node3, Node2, false),
    ?eq(0, OpCode1).


%% Helpers
ejabberdctl_interactive(C, A, R, Config) ->
    DefaultNode = mim(),
    ejabberdctl_interactive(DefaultNode, C, A, R, Config).
ejabberdctl_interactive(Node, Cmd, Args, Response, Config) ->
    CtlCmd = escalus_config:get_config(ctl_path_atom(Node), Config),
    run_interactive(string:join([CtlCmd, Cmd | normalize_args(Args)], " "), Response).

ctl_path_atom(NodeName) ->
    CtlString = atom_to_list(NodeName) ++ "_ctl",
    list_to_atom(CtlString).
normalize_args(Args) ->
    lists:map(fun
                  (Arg) when is_binary(Arg) ->
                      binary_to_list(Arg);
                  (Arg) when is_list(Arg) ->
                      Arg
              end, Args).

%% Long timeout for mnesia and ejabberd app restart
run_interactive(Cmd, Response) ->
    run_interactive(Cmd, Response, timer:seconds(30)).

run_interactive(Cmd, Response, Timeout) ->
    Port = erlang:open_port({spawn, Cmd}, [exit_status]),
    %% respond to interactive question (yes/no)
    Port ! {self(), {command, Response}},
    loop(Port, [], Timeout).

loop(Port, Data, Timeout) ->
    receive
        {Port, {data, NewData}} -> loop(Port, Data ++ NewData, Timeout);
        {Port, {exit_status, ExitStatus}} -> {Data, ExitStatus}
    after Timeout ->
        throw(timeout)
    end.

nodes_clustered(Node1, Node2, ShouldBe) ->
    DbNodes1 = distributed_helper:rpc(Node1, mnesia, system_info, [running_db_nodes]),
    DbNodes2 = distributed_helper:rpc(Node2, mnesia, system_info, [running_db_nodes]),
    Pairs = [{Node1, DbNodes2, ShouldBe},
        {Node2, DbNodes1, ShouldBe},
        {Node1, DbNodes1, true},
        {Node2, DbNodes2, true}],
    [?assertEqual(ShouldBelong, lists:member(Element, List))
        || {Element, List, ShouldBelong} <- Pairs].

start_node(Config, Node) ->
    ejabberdctl_helper:ejabberdctl(Node, "start", [], Config).

stop_node(Config, Node) ->
    ejabberdctl_helper:ejabberdctl(Node, "stop", [], Config).
