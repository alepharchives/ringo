
% TODO:
% 1. Put with replicas works
% 2. Simple syncing works (small items)
% 3. Syncing works (large items)
% 4. New replica node from the scratch 
% 5. New node, owner redirect (invalid domain)
% 6. Simple chunking: close, open a new chunk, redirect request
% 7. Put with a closed chunk
% 8. Syncing a closed chunk


% motto:
% in the worst case data will be lost. Aim at a good average case and try to
% ensure that it is possible to salvage data by hand after a catastrophic
% failure. 
%
% Losing one data item is annoying. Losing all your data is a catastrophy.
% It makes sense to minimize probability of the latter event.
%
% Don't try to make the worst case (catastrophic failure) disappear. Try to
% minimize its effects instead.

% opportunistic replication:
% 1. replicate, wait for replies
% 2. if no replies are received in Q secods, send the request again with
%    duplicate bit on (ring may have changed / healed during the past Q
%    seconds)
% 3. if the step 2 repeats C times, request fails and data is (possibly) lost



% - Why sync_inbox is needed:
%
% Sync_put is called by a replica after owner has requested an entry,
% that is missing from the owner's DB, from the replica. The missing
% entry isn't added to the DB immediately as we cannot be sure that the
% entry is _really_ missing from the DB: Since put requests are allowed
% any time _during_ the Merkle tree construction, this entry might have
% just missed the previous tree. Hence, the entry goes to a sync buffer
% to wait for the tree to be updated.
%
% If the new updated tree is still missing this entry, we can safely add
% it to the DB and update the new tree accordingly.
%
% - Why sync_outbox is needed:
%
% Collecting entries from the DB is expensive. Outbox is used to buffer
% requests from several replicas so that they can be served with a single 
% scan over the DB file.
%

% what if the domain is closed (don't make the DB read-only)

% What happens with duplicate SyncIDs? -- Collisions should be practically
% impossible when using 64bit SyncIDs (Time + Random). However, a duplicate
% syncid doesn't break anything, it just prevents re-syncing from succeeding.
%
% Note that duplicate SyncIDs doesn't matter per se. They become an issue
% only if an entry with an already existing SyncID wasn't replicated correctly
% and it must be re-synced afterwards. If it's replicated ok, everything's ok.


-module(ringo_store).
-behaviour(gen_server).

-export([start/3, resync/1, global_resync/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, 
        terminate/2, code_change/3]).

-include("ringo_store.hrl").
-include_lib("kernel/include/file.hrl").

-define(DOMAIN_CHUNK_MAX, 104857600). % 100MB
-define(SYNC_BUF_MAX_WORDS, 1000000).

-define(MAX_RING_SIZE, 1000000).
-define(RESYNC_INTERVAL, 30000). % make this longer!
-define(GLOBAL_RESYNC_INTERVAL, 30000). % make this longer!

% replication
-define(NREPLICAS, 3).
-define(MAX_TRIES, 3).
-define(REPL_TIMEOUT, 2000).

start(Home, DomainID, IsOwner) ->
        case gen_server:start(ringo_domain, 
                [Home, DomainID, IsOwner], [{debug, [trace, log]}]) of
                {ok, Server} -> {ok, Server};
                {error, {already_started, Server}} -> {ok, Server}
        end.

init([Home, DomainID, IsOwner]) ->
        {A1, A2, A3} = now(),
        random:seed(A1, A2, A3),
        Inbox = ets:new(sync_inbox, []),
        Outbox = ets:new(sync_outbox, [bag]),
        erlang:monitor(process, ringo_node),
        Path = filename:join(Home, "rdomain-" ++ DomainID),

        Domain = #domain{this = self(),
                         owner = IsOwner,
                         home = Path, 
                         dbname = filename:join(Home, "data"),
                         host = net_adm:localhost(),
                         id = DomainID, 
                         z = zlib:open(),
                         db = none,
                         full = false,
                         sync_tree = none, 
                         sync_ids = none,
                         sync_inbox = Inbox,
                         sync_outbox = Outbox},

        RTime = round(?RESYNC_INTERVAL +
                        random:uniform(?RESYNC_INTERVAL * 0.5)),
        {ok, _} = timer:apply_interval(RTime, ringo_domain, resync, [Domain]),
        if IsOwner ->
                GTime = round(?GLOBAL_RESYNC_INTERVAL + 
                                random:uniform(?GLOBAL_RESYNC_INTERVAL * 0.5)),
                {ok, _} = timer:apply_interval(GTime, ringo_domain,
                                global_resync, [Domain]);
        true -> ok
        end,
        {ok, Domain}.
        


%%%
%%% Basic domain operations: Create, put, get 
%%%

handle_call({new_domain, Name, Chunk, NReplicas}, _From, 
        #domain{home = Path} = D) ->
        
        InfoFile = filename:join(Path, "info"),
        ok = file:make_dir(Path),
        ok = file:write_file(InfoFile,
                [integer_to_list(NReplicas), 32, 
                 integer_to_list(Chunk), 32, Name]),
        ok = file:write_file_info(InfoFile, #file_info{mode = ?RDONLY}),
        {reply, ok, open_domain(D)};

% DB not open
handle_call({put, _, _, _} = R, From, #domain{db = none,
        owner = true, full = false} = D) ->

        case catch open_domain(D) of
                NewD when is_record(NewD, domain) ->
                        handle_call(R, From, NewD);
                invalid_domain -> {stop, normal, invalid_domain(R), D}
        end;

handle_call({put, Key, Value, Flags}, _From,
        #domain{size = Size, owner = true, full = false} = D) ->

        EntryID = random:uniform(4294967295),
        Entry = ringo_writer:make_entry(D, EntryID, Key, Value, Flags),
        case replicate(D, Entry) of
                chunk_full -> chunk_full(D),
                        {reply, ok, D#domain{full = true}};
                _ -> {reply, ok, D#domain{size = Size +
                        ringo_writer:entry_size(Entry)}}
        end;

handle_call({put, _, _, _}, _From, #domain{full = true} = D) ->
        % redirect to the next chunk
        {reply, ok, D};
        


%%%
%%% Sync_tree matches a replica's Merkle tree to the owner's.
%%% Called by a replica in merkle_sync.
%%%

handle_call({sync_tree, _, _}, _, #domain{sync_tree = none} = D) ->
        {reply, not_ready, D};

handle_call({sync_tree, H, Level}, _,
        #domain{sync_tree = OTree, owner = true} = D) ->        
        {reply, {ok, ringo_sync:diff_parents(H, Level, OTree)}, D};

%%%
%%% For internal use -- used by synchronization processes (resync)
%%%

% Dump inbox or outbox
handle_call({flush_syncbox, Box}, _From,
        #domain{sync_inbox = Inbox, sync_outbox = Outbox} = D) ->

        Tid = case Box of
                sync_inbox -> Inbox;
                sync_outbox -> Outbox
        end,
        L = ets:tab2list(Tid),
        ets:delete_all_objects(Tid),
        {reply, {ok, L}, D};

handle_call({update_sync_data, Tree, LeafIDs}, _, #domain{owner = true} = D) ->
        {reply, ok, D#domain{sync_tree = Tree, sync_ids = LeafIDs}};

handle_call({update_sync_data, Tree, _}, _, D) ->
        {reply, ok, D#domain{sync_tree = Tree, sync_ids = none}}.


%%%
%%% Maintenance
%%%

handle_cast({write_entry, _Entry}, #domain{db = none} = D) ->
        {noreply, D};

handle_cast({write_entry, Entry}, #domain{db = DB, size = Size} = D) ->
        do_write(DB, Entry, Size, oldentry),
        {noreply, D#domain{size = Size + ringo_writer:entry_size(Entry)}};

handle_cast({kill_domain, Reason}, D) ->
        error_logger:info_report({"Domain killed: ", Reason}),
        {stop, domain_killed, D};

handle_cast({find_owner, Node, N}, #domain{id = DomainID, owner = true} = D) ->
        Node ! {DomainID, {node(), self()}, N},
        {noreply, D};

% N < MAX_RING_SIZE prevents theoretical infinite loops
handle_cast({find_owner, Node, N}, #domain{owner = false, id = DomainID} = D)
        when N < ?MAX_RING_SIZE ->

        {ok, Next} = gen_server:call(ringo_node, get_next),
        gen_server:cast({ringo_node, Next},
                {{domain, DomainID}, {find_owner, Node, N + 1}}),
        % kill the domain server immediately if the domain doesn't exist
        case catch open_domain(D) of
                NewD when is_record(NewD, domain) -> {noreply, NewD};
                invalid_domain -> {stop, normal, D}
        end;

%%%
%%% Replication
%%%

% back to the owner
handle_cast({repl_put, _, {_, ONode, _}, _}, D) when ONode == node() ->
        error_logger:warning_report(
                {"A replication request came back to the owner!"}),
        {noreply, D};

% replica on the same physical node as the owner, skip over this node
handle_cast({repl_put, _, {OHost, _, _}, _} = R, #domain{host = Host} = D)
        when OHost == Host ->
        
        {ok, Prev} = gen_server:call(ringo_node, get_previous),
        gen_server:cast({ringo_node, Prev}, R),
        {noreply, D};

% XXX: FIXME! domain not open
handle_cast({repl_put, _, {_, ONode, OPid}, _} = R, #domain{db = none} = D) ->
        case catch open_domain(D) of 
                NewD when is_record(NewD, domain) -> handle_cast(R, NewD);
                _ -> {ONode, OPid} ! {repl_reply_CHANGME, resync},
                     {noreply, D}
        end;

% normal case
handle_cast({repl_put, Entry, {_, ONode, OPid} = Owner, N},
        #domain{db = DB} = D) ->

        if N > 1 ->
                {ok, Prev} = gen_server:call(ringo_node, get_previous),
                gen_server:cast({ringo_node, Prev},
                        {repl_put, Entry, Owner, N - 1});
        true -> ok
        end,
        ok = ringo_writer:write_entry(DB, Entry),
        {ONode, OPid} ! {repl_reply, ok},
        {noreply, D};

%%%
%%% Synchronization
%%%


handle_cast({sync_put, SyncID, Entry}, #domain{owner = true,
        sync_inbox = Inbox} = D) ->

        M = ets:info(Inbox, memory),
        if M > ?SYNC_BUF_MAX_WORDS ->
                error_logger:warning_report({"Sync buffer full (", M,
                        " words). Entry ignored."});
        true ->
                ets:insert(Inbox, {SyncID, Entry})
        end,
        {noreply, D};

handle_cast({sync_get, Owner, Requests}, #domain{owner = false,
        sync_outbox = Outbox, this = This, dbname = DBName} = D) ->

        ets:insert(Outbox, [{SyncID, Owner} || SyncID <- Requests]),
        spawn_link(fun() -> flush_sync_outbox(This, DBName) end),
        {noreply, D};        

handle_cast({sync_external, _DstDir}, D) ->
        error_logger:info_report("launch rsync etc"),
        {noreply, D};

handle_cast({sync_pack, From, Pack, Distance},
        #domain{sync_ids = LeafIDs, sync_outbox = Outbox, owner = true} = D) ->

        Requests = lists:foldl(fun({Leaf, RSyncIDs}, RequestList) ->
                
                OSyncIDs = bin_util:to_list32(dict:fetch(Leaf, LeafIDs)),

                SendTo = OSyncIDs -- RSyncIDs,
                if SendTo == [] -> ok;
                true ->
                        ets:insert(Outbox,
                                [{SyncID, From} || SyncID <- SendTo])
                end,

                RequestFrom = RSyncIDs -- OSyncIDs,
                RequestFrom ++ RequestList
        end, [], Pack),

        if Requests == [], Distance > ?NREPLICAS ->
                gen_server:cast(From, {kill_domain, "Distant domain"});
        Requests == [] -> ok;
        true ->
                gen_server:cast(From, {sync_get, {node(), self()}, Requests})
        end,
        {noreply, D}.

%%%
%%% Random messages
%%%

% ignore late replication replies
handle_info({repl_reply, _}, D) ->
        {noreply, D};

handle_info({'DOWN', _, _, _, _}, R) ->
        error_logger:info_report("Ringo_node down, domain dies too"),
        {stop, node_down, R}.


%%%
%%% Domain maintenance
%%%

open_domain(#domain{home = Home} = D) ->
        case file:read_file_info(Home) of
                {ok, _} -> open_db(D);
                _ -> throw(invalid_domain)
        end.

open_db(#domain{home = Home, dbname = DBName} = D) ->
        % This will crash if there's a second instance of this domain
        % already running on this node. Note that it is crucial that
        % this function is called *after* we have ensured that the domain
        % really exists on this node. Otherwise someone could pollute
        % out non-gc'ed atom tables with random domain names.
        %register(list_to_atom("ringo_domain-" ++ integer_to_list(DomainID)),
        %        self()),
        Full = case file:read_file_info(file:join(Home, "closed")) of
                {ok, _} -> true;
                _ -> false
        end,
        {ok, DB} = file:open(DBName, [append, raw]),
        D#domain{db = DB, size = domain_size(Home), full = Full}.

domain_size(Home) ->
        [Size, _] = string:tokens(os:cmd(["du -b ", Home, " |tail -1"]), "\t"),
        list_to_integer(Size).

close_domain(Home, DB) ->
        ok = file:sync(DB),
        %DFile = file:join(Home, "data"),
        %ok = file:write_file_info(DFile, #file_info{mode = ?RDONLY}),
        CFile = file:join(Home, "closed"),
        ok = file:write_file(CFile, <<>>), 
        ok = file:write_file_info(CFile, #file_info{mode = ?RDONLY}).

invalid_domain(_Request) -> no_fun.
        % push backwards

closed_chunk(_Request) -> no_fun.
        % forward to the next chunk

chunk_full(#domain{home = Home, db = DB}) ->
        close_domain(Home, DB).
        % create a new domain chunk

%
% opportunistic replication: If at least one replica succeeds, we are happy
% (and assume that quite likely more than one have succeeded)
%

%%%
%%% Put with replication
%%%

replicate(#domain{db = DB, size = Size, id = DomainID}, Entry) ->
        case do_write(DB, Entry, Size, new_entry) of
                chunk_full -> chunk_full;
                _ -> replicate(DomainID, Entry, 0)
        end.

replicate(_, _Entry, ?MAX_TRIES) ->
        error_logger:warning_report({"Replication failed!"}),
        failed;

replicate(DomainID, Entry, Tries) ->
        Me = {net_adm:localhost(), node(), self()},
        {ok, Prev} = gen_server:call(ringo_node, get_previous),
        gen_server:cast({ringo_node, Prev},
                {{domain, DomainID}, {repl_put, Entry, Me, ?NREPLICAS}}),
        receive
                {repl_reply, ok} -> ok
        after ?REPL_TIMEOUT ->
                replicate(DomainID, Entry, Tries + 1)
        end.

do_write(_, Entry, CurrentSize, new_entry)
        when size(Entry) + CurrentSize > ?DOMAIN_CHUNK_MAX ->
                chunk_full;

% should we prevent replica or sync entries to be added if the resulting
% chunk would exceed the maximum size? If yes, spontaneously corrupted entries
% can't be fixed. If no, a chunk may grow infinitely large. In this case, it is
% possible that a nasty bug causes a large amounts of sync entries to be sent
% which would eventually fill the disk.

%do_write(_, Entry, CurrentSize, _)
%        when size(Entry) + CurrentSize > ?DOMAIN_CHUNK_MAX * 1.2 ->
%                chunk_full;

do_write(DB, Entry, _CurrentSize, _) ->
        ringo_writer:write_entry(DB, Entry).

% Premises about resync:
%
% - We can't know for sure on which nodes all replicas of this domain exist. Nodes may
%   have disappeared, new nodes may have been added etc. Hence, we have to go
%   through the whole ring to find the replicas.
%
% - Since the ring may contain any arbitrary collection of nodes at any point of
%   time



        
%%%
%%% Synchronization 
%%%

% Owner-end in synchronization -- just update the tree
resync(#domain{this = This, dbname = DBName, owner = true}) ->
        register(resync, self()),
        update_sync_tree(This, DBName),
        flush_sync_outbox(This, DBName);

% Replica-end in synchronization -- the active party
resync(#domain{home = Home, this = This, host = Host,
        id = DomainID, dbname = DBName}) ->

        register(resync, self()),
        [[Root]|Tree] = update_sync_tree(This, DBName),
        {ok, Owner, Distance} = find_owner(DomainID),
        DiffLeaves = merkle_sync(Owner, [{0, Root}], 1, Tree),
        if DiffLeaves == [] -> ok;
        true ->
                SyncIDs = ringo_sync:collect_leaves(DiffLeaves, DBName),
                gen_server:cast(Owner, {sync_pack, SyncIDs, This, Distance}),
                gen_server:cast(Owner, {sync_external, Host ++ ":" ++ Home})
        end.

% merkle_sync compares the replica's Merkle tree to the owner's

% Trees are in sync
merkle_sync(_Owner, [], 2, _Tree) -> [];

merkle_sync(Owner, Level, H, Tree) ->
        {ok, Diff} = gen_server:call({sync_tree, H, Level}),
        if H < length(Tree) ->
                merkle_sync(Owner, ringo_sync:pick_children(H + 1, Diff, Tree),
                        H + 1, Tree);
        true ->
                Diff
        end.

% update_sync_tree scans entries in this DB, collects all entry IDs and
% computes the leaf hashes. Entries in the inbox that don't exist in the DB
% already are written to disk. Finally Merkle tree is re-built.
update_sync_tree(This, DBName) ->
        Inbox = gen_server:call(This, {flush_syncbox, sync_inbox}),
        {LeafHashes, LeafIDs} = ringo_sync:make_leaf_hashes_and_ids(DBName),
        Entries = lists:filter(fun({SyncID, _}) ->
                not ringo_sync:in_leaves(LeafIDs, SyncID)
        end, Inbox),
        Z = zlib:open(),
        {LeafHashesX, LeafIDsX} = flush_sync_inbox(This, Z, Entries,
                LeafHashes, LeafIDs),
        zlib:close(Z),
        Tree = ringo_sync:build_merkle_tree(LeafHashesX),
        ets:delete(LeafHashesX),
        gen_server:call(This, {update_sync_data, Tree, LeafIDsX}),
        Tree.

% flush_sync_inbox writes entries that have been sent to this replica
% (or owner) to disk and updates the leaf hashes accordingly
flush_sync_inbox(_, _, [], LeafHashes, LeafIDs) -> {LeafHashes, LeafIDs};

flush_sync_inbox(This, Z, [{SyncID, Entry}|Rest], LeafHashes, LeafIDs) ->
        ringo_sync:update_leaf_hashes(Z, LeafHashes, SyncID),
        LeafIDsX = ringo_sync:update_leaf_ids(Z, LeafIDs, SyncID),
        gen_server:cast(This, {write_entry, Entry}),
        flush_sync_inbox(This, Z, Rest, LeafHashes, LeafIDsX).

% flush_sync_outbox sends entries that exists on this replica or owner to
% another node that requested the entry
flush_sync_outbox(This, DBName) ->
        {ok, Outbox} = gen_server:call(This, {flush_syncbox, sync_outbox}),
        flush_sync_outbox_1(DBName, Outbox).

flush_sync_outbox_1(_, []) -> ok;
flush_sync_outbox_1(DBName, Outbox) ->
        Q = ets:new(x, [bag]),
        ets:insert(Q, Outbox),
        ringo_reader:foreach(fun(_, _, _, {Time, EntryID}, Entry, _) ->
                {_, SyncID} = ringo_sync:sync_id(EntryID, Time),
                case ets:lookup(Q, SyncID) of
                        [] -> ok;
                        L -> Msg = {sync_put, SyncID, Entry},
                             [gen_server:cast(To, Msg) || {_, To} <- L]
                end
        end, DBName, ok),
        ets:delete(Q).

%%%
%%% Global resync
%%% 
%%% In the normal case N replica nodes that precede the domain owner
%%% are responsible for re-syncing themselves with the owner. However,
%%% if the ring goes through a major re-organization, there may be
%%% replicas for this domain further away in the ring as well.
%%%
%%% Global_resync is activated periodically by the domain owner. It
%%% initiates the find_owner operation, that finds the owner node for
%%% the given DomainID. Since find_owner is started by the owner
%%% itself, it has to circulate through the whole ring before reaching
%%% back to this node.
%%%
%%% On its way, it instantiates a domain server for this domain on every
%%% node. Servers on nodes that don't contain a replica of this domain
%%% die away immediately. The others stay alive and start the normal
%%% re_sync process (above) which eventually connects to the owner and
%%% goes through the standard synchronization procedure.
%%%
%%% If a distant replica contains entries that are missing from the
%%% owner, they are sent to it as usual. Otherwise, sync_pack-handler
%%% recognizes the distant replica and kills it.
%%%
global_resync(DomainID) ->
        find_owner(DomainID).

find_owner(DomainID) ->
        {ok, Next} = gen_server:call(ringo_node, get_next),
        gen_server:cast({ringo_node, Next},
                {{domain, DomainID}, {find_owner, {node(), self()}, 1}}),
        receive
                {owner, DomainID, Owner, Distance} -> {ok, Owner, Distance}
        after 10000 ->
                error_logger:warning_report({
                        "Replica resync couldn't find the owner for domain",
                                DomainID}),
                timeout
        end.        


%%% callback stubs


terminate(_Reason, #domain{db = none}) -> {};
terminate(_Reason, #domain{db = DB}) ->
        file:close(DB).

code_change(_OldVsn, State, _Extra) -> {ok, State}.

