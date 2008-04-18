-module(handle_ring).
-export([handle/2]).

-define(HTTP_HEADER, "HTTP/1.1 200 OK\n"
                     "Status: 200 OK\n"
                     "Content-type: text/plain\n\n").

op("nodes", _Query) ->
        V = (catch is_process_alive(whereis(check_node_status))),
        if V -> ok;
        true -> spawn(fun check_node_status/0)
        end,
        case catch ets:tab2list(node_status_table) of 
                {'EXIT', _} -> {ok, []};
                L -> {ok, check_ring(ringo_util:group_pairs(L))}
        end.


handle(Socket, Msg) ->
        {value, {_, Script}} = lists:keysearch("SCRIPT_NAME", 1, Msg),
        {value, {_, Query}} = lists:keysearch("QUERY_STRING", 1, Msg),
        
        Op = lists:last(string:tokens(Script, "/")),
        {ok, Res} = op(Op, httpd:parse_query(Query)),
        gen_tcp:send(Socket, [?HTTP_HEADER, json:encode(Res)]).


check_node_status() ->
        catch register(check_node_status, self()),
        ets:new(tmptable, [named_table, bag]),
        
        Nodes = ringo_util:ringo_nodes(),
       
        {OkNodes, BadNodes} = gen_server:multi_call(Nodes,
                ringo_node, get_neighbors, 2000),
        
        ets:insert(tmptable, [{N, {neighbors, {Prev, Next}}} ||
                {N, {ok, Prev, Next}} <- OkNodes]),
        ets:insert(tmptable, [{N, {neighbors, timeout}} || N <- BadNodes]),
        
        lists:foreach(fun(Node) ->
                spawn(Node, ringo_util, node_status, [self()])
        end, Nodes),
        ok = collect_results(),

        % We have an obvious race condition here: Check_node_status process may
        % delete node_status_table while a query handler is accessing it. We
        % just assume that this is an infrequent event and it doesn't matter if
        % a query fails occasionally as it is unlikely that many consequent
        % update requests would fail.
        catch ets:delete(node_status_table),
        ets:rename(tmptable, node_status_table),
        check_node_status().

collect_results() ->
        receive
                {node_results, NodeStatus} ->
                        ets:insert(tmptable, NodeStatus),
                        collect_results();
                _ -> collect_results()
        after 10000 -> ok
        end.

check_ring(Nodes) ->
        % First sort the nodes according to ascending node ID
        {_, Sorted} = lists:unzip(lists:keysort(1, lists:map(fun({N, _} = T) ->
                [_, X1] = string:tokens(atom_to_list(N), "-"),
                [ID, _] = string:tokens(X1, "@"),
                {erlang:list_to_integer(ID, 16), T}
        end, Nodes))),
        % Obtain the last node's information, which will be check against the
        % first one.
        [Last|_] = lists:reverse(Sorted),
        {_, {LastNode, LastNext}} = check_node(Last, {false, false}),
        % Check validity of each node's position in the ring, that is 
        % prev and next entries match, and construct a JSON object as the
        % result.
        {Ret, _} = lists:mapfoldl(fun check_node/2,
                {LastNode, LastNext}, Sorted),
        Ret.

check_node({Node, Attr}, {PrevNode, PrevNext}) ->
        case lists:keysearch(neighbors, 1, Attr) of
                {value, {neighbors, {Prev, Next}}} ->
                        V = (PrevNode == Prev) and (PrevNext == Node),
                        {{obj, [{node, Node}, {ok, V}|Attr]}, {Node, Next}};
                {value, {neighbors, timeout}} ->
                        {{obj, [{node, Node}, {ok, false}|Attr]}, {Node, Node}}
        end.

