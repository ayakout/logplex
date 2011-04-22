%% Copyright (c) 2010 Jacob Vorreuter <jacob.vorreuter@gmail.com>
%% 
%% Permission is hereby granted, free of charge, to any person
%% obtaining a copy of this software and associated documentation
%% files (the "Software"), to deal in the Software without
%% restriction, including without limitation the rights to use,
%% copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the
%% Software is furnished to do so, subject to the following
%% conditions:
%% 
%% The above copyright notice and this permission notice shall be
%% included in all copies or substantial portions of the Software.
%% 
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
%% EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
%% OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
%% NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
%% HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
%% WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
%% FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
%% OTHER DEALINGS IN THE SOFTWARE.
-module(logplex_drain).
-behaviour(gen_server).

%% gen_server callbacks
-export([start_link/0, init/1, handle_call/3, handle_cast/2, 
	     handle_info/2, terminate/2, code_change/3]).

-export([create/3, delete/3, clear_all/1, lookup/1]).

-include_lib("logplex.hrl").

%% API functions
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

create(ChannelId, Host, Port) when is_integer(ChannelId), is_binary(Host), (is_integer(Port) orelse Port == undefined) ->
    case lookup(ChannelId, Host, Port) of
        [_] ->
            {error, already_exists};
        [] ->
            case logplex_utils:resolve_host(Host) of
                undefined ->
                    error_logger:error_msg("invalid drain: ~p:~p~n", [Host, Port]),
                    {error, invalid_drain};
                _Ip ->
                    case redis_helper:drain_index() of
                        DrainId when is_integer(DrainId) ->
                            redis_helper:create_drain(DrainId, ChannelId, Host, Port),
                            DrainId;
                        Error ->
                            Error
                    end
            end
    end.

delete(ChannelId, Host, Port) when is_integer(ChannelId), is_binary(Host) ->
    Port1 = if Port == "" -> undefined; true -> list_to_integer(Port) end,
    case lookup(ChannelId, Host, Port1) of
        [#drain{id=DrainId}|_] ->
            redis_helper:delete_drain(DrainId);
        _ ->
            {error, not_found}
    end.

clear_all(ChannelId) when is_integer(ChannelId) ->
    List = logplex_channel:drains(ChannelId),
    [begin
        redis_helper:delete_drain(DrainId)
    end || #drain{id=DrainId} <- List],
    ok.

lookup(DrainId) when is_integer(DrainId) ->
    redis_helper:lookup_drain(DrainId).

lookup(ChannelId, Host, Port) ->
    case nsync_helper:tab_drains() of
	undefined ->
	    [];
	DrainsTab ->
	    lookup(DrainsTab, ChannelId, Host, Port)
    end.
lookup(DrainsTab, ChannelId, Host, Port) ->
    lists:foldl(fun({Drain, Dict}, Acc) -> 
			case {dict:fetch(<<"ch">>, Dict) == list_to_binary(integer_to_list(ChannelId)),
			      dict:fetch(<<"host">>, Dict) == Host,
			      dict:fetch(<<"port">>, Dict) == Port} of 
			    {true, true, true} -> 
				[#drain{id = list_to_binary(string:sub_word(binary_to_list(Drain), 2, $:)),
					channel_id = ChannelId,
					host = Host,
					port = list_to_integer(binary_to_list(Port)),
					resolved_host = logplex_utils:resolve_host(Host)
				       } | Acc];
			    _ -> 
				Acc 
			end 
		end, [], ets:tab2list(DrainsTab)).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%% @hidden
%%--------------------------------------------------------------------
init([]) ->
	{ok, []}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%% @hidden
%%--------------------------------------------------------------------
handle_call(_Msg, _From, State) ->
    {reply, {error, invalid_call}, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%% @hidden
%%--------------------------------------------------------------------
handle_cast({delete_channel, ChannelId}, State) ->
    ets:match_delete(?MODULE, #drain{id='_', channel_id=ChannelId, resolved_host='_', host='_', port='_'}),
    {noreply, State};

handle_cast({create_drain, DrainId, ChannelId, ResolvedHost, Host, Port}, State) ->
    ets:insert(?MODULE, #drain{id=DrainId, channel_id=ChannelId, resolved_host=ResolvedHost, host=Host, port=Port}),
    {noreply, State};

handle_cast({delete_drain, DrainId}, State) ->
    ets:delete(?MODULE, DrainId),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%% @hidden
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%% @hidden
%%--------------------------------------------------------------------
terminate(_Reason, _State) -> 
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%% @hidden
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
populate_cache() ->
    Data = lists:foldl(
        fun(#drain{host=Host}=Drain, Acc) ->
            case logplex_utils:resolve_host(Host) of
                undefined -> Acc;
                Ip -> [Drain#drain{resolved_host=Ip}|Acc]
            end
        end, [], redis_helper:lookup_drains()),
    length(Data) > 0 andalso ets:insert(?MODULE, Data).
