%% Copyright (c) 2016, Loïc Hoguin <essen@ninenines.eu>
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

-module(gun_http2).

-export([check_options/1]).
-export([name/0]).
-export([init/4]).
-export([handle/2]).
-export([close/1]).
-export([keepalive/1]).
-export([request/7]).
-export([request/8]).
-export([data/4]).
-export([cancel/2]).
-export([down/1]).

-record(stream, {
	id :: non_neg_integer(),
	ref :: reference(),
	%% Whether we finished sending data.
	local = nofin :: cowboy_stream:fin(),
	%% Whether we finished receiving data.
	remote = nofin :: cowboy_stream:fin()
}).

-record(http2_state, {
	owner :: pid(),
	socket :: inet:socket() | ssl:sslsocket(),
	transport :: module(),
	buffer = <<>> :: binary(),

	%% @todo local_settings, next_settings, remote_settings

	streams = [] :: [#stream{}],
	stream_id = 1 :: non_neg_integer(),

	%% HPACK decoding and encoding state.
	decode_state = cow_hpack:init() :: cow_hpack:state(),
	encode_state = cow_hpack:init() :: cow_hpack:state()
}).

check_options(Opts) ->
	do_check_options(maps:to_list(Opts)).

do_check_options([]) ->
	ok;
do_check_options([{keepalive, K}|Opts]) when is_integer(K), K > 0 ->
	do_check_options(Opts);
do_check_options([Opt|_]) ->
	{error, {options, {http2, Opt}}}.

name() -> http2.

init(Owner, Socket, Transport, _Opts) ->
	%% Send the HTTP/2 preface.
	Transport:send(Socket, [
		<< "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n">>,
		cow_http2:settings(#{}) %% @todo Settings.
	]),
	#http2_state{owner=Owner, socket=Socket, transport=Transport}.

handle(Data, State=#http2_state{buffer=Buffer}) ->
	parse(<< Buffer/binary, Data/binary >>, State#http2_state{buffer= <<>>}).

parse(Data0, State=#http2_state{buffer=Buffer}) ->
	%% @todo Parse states: Preface. Continuation.
	Data = << Buffer/binary, Data0/binary >>,
	case cow_http2:parse(Data) of
		{ok, Frame, Rest} ->
			parse(Rest, frame(Frame, State));
		{stream_error, StreamID, Reason, Human, Rest} ->
			parse(Rest, stream_reset(State, StreamID, {stream_error, Reason, Human}));
		Error = {connection_error, _, _} ->
			terminate(State, Error);
		more ->
			State#http2_state{buffer=Data}
	end.

%% DATA frame.
frame({data, StreamID, IsFin, Data}, State=#http2_state{owner=Owner}) ->
	case get_stream_by_id(StreamID, State) of
		Stream = #stream{ref=StreamRef, remote=nofin} ->
			Owner ! {gun_data, self(), StreamRef, IsFin, Data},
			remote_fin(Stream, State, IsFin);
		_ ->
			%% @todo protocol_error if not existing
			stream_reset(State, StreamID, {stream_error, stream_closed,
				'DATA frame received for a closed or non-existent stream. (RFC7540 6.1)'})
	end;
%% Single HEADERS frame headers block.
frame({headers, StreamID, IsFin, head_fin, HeaderBlock},
		State=#http2_state{owner=Owner, decode_state=DecodeState0}) ->
	case get_stream_by_id(StreamID, State) of
		Stream = #stream{ref=StreamRef, remote=nofin} ->
			try cow_hpack:decode(HeaderBlock, DecodeState0) of
				{Headers0, DecodeState} ->
					case lists:keytake(<<":status">>, 1, Headers0) of
						{value, {_, Status}, Headers} ->
							Owner ! {gun_response, self(), StreamRef, IsFin, parse_status(Status), Headers},
							remote_fin(Stream, State#http2_state{decode_state=DecodeState}, IsFin);
						false ->
							stream_reset(State, StreamID, {stream_error, protocol_error,
								'Malformed response; missing :status in HEADERS frame. (RFC7540 8.1.2.4)'})
					end
			catch _:_ ->
				terminate(State, {connection_error, compression_error,
					'Error while trying to decode HPACK-encoded header block. (RFC7540 4.3)'})
			end;
		_ ->
			stream_reset(State, StreamID, {stream_error, stream_closed,
				'DATA frame received for a closed or non-existent stream. (RFC7540 6.1)'})
	end;
%% @todo HEADERS frame starting a headers block. Enter continuation mode.
%frame(State, {headers, StreamID, IsFin, head_nofin, HeaderBlockFragment}) ->
%	State#http2_state{parse_state={continuation, StreamID, IsFin, HeaderBlockFragment}};
%% @todo Single HEADERS frame headers block with priority.
%frame(State, {headers, StreamID, IsFin, head_fin,
%		_IsExclusive, _DepStreamID, _Weight, HeaderBlock}) ->
%	%% @todo Handle priority.
%	stream_init(State, StreamID, IsFin, HeaderBlock);
%% @todo HEADERS frame starting a headers block. Enter continuation mode.
%frame(State, {headers, StreamID, IsFin, head_nofin,
%		_IsExclusive, _DepStreamID, _Weight, HeaderBlockFragment}) ->
%	%% @todo Handle priority.
%	State#http2_state{parse_state={continuation, StreamID, IsFin, HeaderBlockFragment}};
%% @todo PRIORITY frame.
%frame(State, {priority, _StreamID, _IsExclusive, _DepStreamID, _Weight}) ->
%	%% @todo Validate StreamID?
%	%% @todo Handle priority.
%	State;
%% @todo RST_STREAM frame.
frame({rst_stream, StreamID, Reason}, State) ->
	stream_reset(State, StreamID, {stream_error, Reason, 'Stream reset by server.'});
%% SETTINGS frame.
frame({settings, _Settings}, State=#http2_state{socket=Socket, transport=Transport}) ->
	%% @todo Apply SETTINGS.
	Transport:send(Socket, cow_http2:settings_ack()),
	State;
%% Ack for a previously sent SETTINGS frame.
frame(settings_ack, State) -> %% @todo =#http2_state{next_settings=_NextSettings}) ->
	%% @todo Apply SETTINGS that require synchronization.
	State;
%% PUSH_PROMISE frame.
%% @todo Continuation.
%frame({push_promise, StreamID, head_fin, PromisedStreamID, HeaderBlock}, State) ->
%	%% @todo
%	State;
%% PING frame.
frame({ping, Opaque}, State=#http2_state{socket=Socket, transport=Transport}) ->
	Transport:send(Socket, cow_http2:ping_ack(Opaque)),
	State;
%% Ack for a previously sent PING frame.
%%
%% @todo Might want to check contents but probably a waste of time.
frame({ping_ack, _Opaque}, State) ->
	State;
%% GOAWAY frame.
frame(Frame={goaway, _, _, _}, State) ->
	terminate(State, {stop, Frame, 'Client is going away.'});
%% Connection-wide WINDOW_UPDATE frame.
frame({window_update, _Increment}, State) ->
	%% @todo control flow
	State;
%% Stream-specific WINDOW_UPDATE frame.
frame({window_update, _StreamID, _Increment}, State) ->
	%% @todo stream-specific control flow
	State;
%% Unexpected CONTINUATION frame.
frame({continuation, _, _, _}, State) ->
	terminate(State, {connection_error, protocol_error,
		'CONTINUATION frames MUST be preceded by a HEADERS frame. (RFC7540 6.10)'}).

parse_status(Status) ->
	<< Code:3/binary, _/bits >> = Status,
	list_to_integer(binary_to_list(Code)).

close(#http2_state{owner=Owner, streams=Streams}) ->
	close_streams(Owner, Streams).

close_streams(_, []) ->
	ok;
close_streams(Owner, [#stream{ref=StreamRef}|Tail]) ->
	Owner ! {gun_error, self(), StreamRef, {closed,
		"The connection was lost."}},
	close_streams(Owner, Tail).

keepalive(State=#http2_state{socket=Socket, transport=Transport}) ->
	Transport:send(Socket, cow_http2:ping(<< 0:64 >>)),
	State.

%% @todo Shouldn't always be HTTPS scheme. We need to properly keep track of it.
request(State=#http2_state{socket=Socket, transport=Transport, encode_state=EncodeState0,
		stream_id=StreamID}, StreamRef, Method, Host, Port, Path, Headers) ->
	{HeaderBlock, EncodeState} = prepare_headers(EncodeState0, Method, Host, Port, Path, Headers),
	IsFin = case (false =/= lists:keyfind(<<"content-type">>, 1, Headers))
			orelse (false =/= lists:keyfind(<<"content-length">>, 1, Headers)) of
		true -> nofin;
		false -> fin
	end,
	Transport:send(Socket, cow_http2:headers(StreamID, IsFin, HeaderBlock)),
	new_stream(StreamID, StreamRef, nofin, IsFin,
		State#http2_state{stream_id=StreamID + 2, encode_state=EncodeState}).

%% @todo Handle Body > 16MB. (split it out into many frames)
%% @todo Shouldn't always be HTTPS scheme. We need to properly keep track of it.
request(State=#http2_state{socket=Socket, transport=Transport, encode_state=EncodeState0,
		stream_id=StreamID}, StreamRef, Method, Host, Port, Path, Headers0, Body) ->
	Headers = lists:keystore(<<"content-length">>, 1, Headers0,
		{<<"content-length">>, integer_to_binary(iolist_size(Body))}),
	{HeaderBlock, EncodeState} = prepare_headers(EncodeState0, Method, Host, Port, Path, Headers),
	Transport:send(Socket, [
		cow_http2:headers(StreamID, nofin, HeaderBlock),
		cow_http2:data(StreamID, fin, Body)
	]),
	new_stream(StreamID, StreamRef, nofin, fin,
		State#http2_state{stream_id=StreamID + 2, encode_state=EncodeState}).

prepare_headers(EncodeState, Method, Host, Port, Path, Headers0) ->
	%% @todo We also must remove any header found in the connection header.
	Headers1 =
		lists:keydelete(<<"host">>, 1,
		lists:keydelete(<<"connection">>, 1,
		lists:keydelete(<<"keep-alive">>, 1,
		lists:keydelete(<<"proxy-connection">>, 1,
		lists:keydelete(<<"transfer-encoding">>, 1,
		lists:keydelete(<<"upgrade">>, 1, Headers0)))))),
	Headers = [
		{<<":method">>, Method},
		{<<":scheme">>, <<"https">>},
		{<<":authority">>, [Host, $:, integer_to_binary(Port)]},
		{<<":path">>, Path}
	|Headers1],
	cow_hpack:encode(Headers, EncodeState).

data(State=#http2_state{socket=Socket, transport=Transport},
		StreamRef, IsFin, Data) ->
	case get_stream_by_ref(StreamRef, State) of
		#stream{local=fin} ->
			error_stream_closed(State, StreamRef);
		S = #stream{} ->
			Transport:send(Socket, cow_spdy:data(S#stream.id, IsFin, Data)),
			local_fin(S, State, IsFin);
		false ->
			error_stream_not_found(State, StreamRef)
	end.

cancel(State=#http2_state{socket=Socket, transport=Transport},
		StreamRef) ->
	case get_stream_by_ref(StreamRef, State) of
		#stream{id=StreamID} ->
			Transport:send(Socket, cow_http2:rst_stream(StreamID, cancel)),
			delete_stream(StreamID, State);
		false ->
			error_stream_not_found(State, StreamRef)
	end.

%% @todo Add unprocessed streams when GOAWAY handling is done.
down(#http2_state{streams=Streams}) ->
	KilledStreams = [Ref || #stream{ref=Ref} <- Streams],
	{KilledStreams, []}.

terminate(#http2_state{owner=Owner}, Reason) ->
	Owner ! {gun_error, self(), Reason},
	%% @todo Send GOAWAY frame.
	%% @todo LastGoodStreamID
	close.

stream_reset(State=#http2_state{owner=Owner, socket=Socket, transport=Transport,
		streams=Streams0}, StreamID, StreamError={stream_error, Reason, _}) ->
	Transport:send(Socket, cow_http2:rst_stream(StreamID, Reason)),
	case lists:keytake(StreamID, #stream.id, Streams0) of
		{value, #stream{ref=StreamRef}, Streams} ->
			Owner ! {gun_error, self(), StreamRef, StreamError},
			State#http2_state{streams=Streams};
		false ->
			%% @todo Unknown stream. Not sure what to do here. Check again once all
			%% terminate calls have been written.
			State
	end.

error_stream_closed(State=#http2_state{owner=Owner}, StreamRef) ->
	Owner ! {gun_error, self(), StreamRef, {badstate,
		"The stream has already been closed."}},
	State.

error_stream_not_found(State=#http2_state{owner=Owner}, StreamRef) ->
	Owner ! {gun_error, self(), StreamRef, {badstate,
		"The stream cannot be found."}},
	State.

%% Streams.
%% @todo probably change order of args and have state first?

new_stream(StreamID, StreamRef, Remote, Local,
		State=#http2_state{streams=Streams}) ->
	New = #stream{id=StreamID, ref=StreamRef, remote=Remote, local=Local},
	State#http2_state{streams=[New|Streams]}.

get_stream_by_id(StreamID, #http2_state{streams=Streams}) ->
	lists:keyfind(StreamID, #stream.id, Streams).

get_stream_by_ref(StreamRef, #http2_state{streams=Streams}) ->
	lists:keyfind(StreamRef, #stream.ref, Streams).

delete_stream(StreamID, State=#http2_state{streams=Streams}) ->
	Streams2 = lists:keydelete(StreamID, #stream.id, Streams),
	State#http2_state{streams=Streams2}.

remote_fin(_, State, nofin) ->
	State;
remote_fin(S=#stream{local=fin}, State, fin) ->
	delete_stream(S#stream.id, State);
remote_fin(S, State=#http2_state{streams=Streams}, IsFin) ->
	Streams2 = lists:keyreplace(S#stream.id, #stream.id, Streams,
		S#stream{remote=IsFin}),
	State#http2_state{streams=Streams2}.

local_fin(_, State, nofin) ->
	State;
local_fin(S=#stream{remote=fin}, State, fin) ->
	delete_stream(S#stream.id, State);
local_fin(S, State=#http2_state{streams=Streams}, IsFin) ->
	Streams2 = lists:keyreplace(S#stream.id, #stream.id, Streams,
		S#stream{local=IsFin}),
	State#http2_state{streams=Streams2}.
