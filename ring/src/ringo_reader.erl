-module(ringo_reader).

-export([fold/3, read_external/3]).
-include("ringo_store.hrl").

-define(NI, :32/little).
-record(iter, {z, db, f, prev, prev_head, acc}).

fold(F, Acc0, DBName) ->
        {ok, DB} = file:open(DBName, [read, raw, binary]),
        Z = zlib:open(),
        try
                read_item(#iter{z = Z, db = DB, f = F, 
                        prev = {0, 0}, prev_head = 0, acc = Acc0})
        catch
                {eof, #iter{acc = Acc}} ->
                        zlib:close(Z),
                        file:close(DB),
                        Acc
        end.

read_item(#iter{f = F, prev = Prev, acc = Acc} = Q) ->
        {Time, EntryID, Flags, Key, Val, Entry} = read_entry(Q),
        ID = {Time, EntryID},
        % skip duplicate items
        if Prev == EntryID ->
                AccN = Acc;
        true ->
                % callback function may throw(eof) if it wants
                % to stop iterating
                AccN = F(Key, Val, parse_flags(Flags), ID, Entry, Acc)
        end,
        read_item(Q#iter{prev = EntryID, acc = AccN}).

read_entry(Q) ->
        read_head(Q, read(Q, 8)).

% If reading an entry fails, we have no guarantee on how many bytes
% actually belong to this entry (in the extreme case only the magic head
% is valid), so we have to backtrack to the field head and continue
% seeking for the next magic head from there. Hence we need to
% record position of the latest entry head below.
read_head(#iter{db = DB} = Q, <<?MAGIC_HEAD?NI, HeadCRC?NI>> = PHead) ->
        {ok, Pos} = file:position(DB, cur),
        NQ = Q#iter{prev_head = Pos},
        Head = read(NQ, 7 * 4),
        read_body(NQ, Head, check(NQ, Head, HeadCRC), PHead);

read_head(Q, _) ->
        seek_magic(Q).

read_body(Q, _, false, _) ->
        seek_magic(Q);

read_body(Q, <<Time?NI, EntryID?NI, Flags?NI, KeyCRC?NI, 
                KeyLen?NI, ValCRC?NI, ValLen?NI>> = Head, true, PHead) ->

        <<Key:KeyLen/binary, Val:ValLen/binary, End:4/binary>> = Body =
                read(Q, KeyLen + ValLen + 4),
        Entry = <<PHead/binary, Head/binary, Body/binary>>,
        validate(Q, {Time, EntryID, Flags, Key, Val, Entry},
                check(Q, Key, KeyCRC), check(Q, Val, ValCRC), End).

validate(_, Ret, true, true, ?MAGIC_TAIL_B) -> Ret;
validate(Q, _, _, _, _) -> seek_magic(Q).
        
check(#iter{z = Z}, Val, CRC) ->
        zlib:crc32(Z, Val) == CRC.

seek_magic(#iter{db = DB, prev_head = 0} = Q) ->
        {ok, _} = file:position(DB, {bof, 1}),
        seek_magic(Q, read(Q, 8));

seek_magic(#iter{db = DB, prev_head = Pos} = Q) ->
        {ok, _} = file:position(DB, {bof, Pos - 7}),
        seek_magic(Q, read(Q, 8)).

% Found a potentially valid entry head
seek_magic(Q, <<?MAGIC_HEAD?NI, _?NI>> = D) ->
        read_head(Q, D);

% Skip a byte, continue seeking
seek_magic(Q, <<_:1/binary, D/binary>>) ->
        E = read(Q, 1),
        seek_magic(Q, <<D/binary, E/binary>>).

read(#iter{db = DB} = Q, N) ->
        case file:read(DB, N) of
                {ok, D} -> D;
                eof -> throw({eof, Q});
                Error -> throw(Error)
        end.

parse_flags(Flags) ->
        [S || {S, F} <- ?FLAGS, Flags band F > 0].

read_external(Home, Z, <<CRC:32, ExtFile/binary>>) ->
        ExtPath = filename:join(Home, binary_to_list(ExtFile)),
        case file:read_file(ExtPath) of
                {error, Reason} -> {io_error, Reason};
                {ok, Value} ->
                        V = zlib:crc32(Z, Value),
                        if V == CRC -> {ok, Value};
                        true -> corrupted_file
                        end
        end.
