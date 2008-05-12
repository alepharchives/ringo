-module(ringogw_util).
-export([chunked_reply/2]).

chunked_reply(Sender, ReplyGen) ->
        case catch ReplyGen() of
                {entry, Entry} ->
                        Sender(encode_chunk(Entry, <<"ok">>)),
                        chunked_reply(Sender, ReplyGen);
                done ->
                        Sender(encode_chunk(done));
                timeout ->
                        Sender(encode_chunk(<<>>, <<"timeout">>)),
                        Sender(encode_chunk(done));
                {'EXIT', Error} ->
                        error_logger:error_report(
                                {"Chunked result generator failed", Error}),
                        Sender(encode_chunk(<<>>, <<"error">>)),
                        Sender(encode_chunk(done))
        end.

% last chunk
encode_chunk(done) -> <<"0\r\n\r\n">>.
encode_chunk(Data, Code) ->
        error_logger:info_report({"Dum", Data}),
        Prefixed = [io_lib:format("~b ", [size(Data)]), Code, " ", Data],
        error_logger:info_report({"E", iolist_size}),
        [io_lib:format("~.16b\r\n", [iolist_size(Prefixed)]),  Prefixed, "\r\n"].
