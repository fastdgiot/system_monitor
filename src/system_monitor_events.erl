%%--------------------------------------------------------------------------------
%% Copyright 2022 k32
%% Copyright 2020 Klarna Bank AB
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
%%--------------------------------------------------------------------------------
%%% @doc
%%% Print BEAM VM events to the logs
%%%
%%% @end
-module(system_monitor_events).

-behaviour(gen_server).

-include("system_monitor.hrl").
-include_lib("kernel/include/logger.hrl").

-export([start_link/0]).

%% gen_server callbacks
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        ]).

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%% @end
%%--------------------------------------------------------------------
-spec start_link() -> {ok, pid()}.
start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
  setup_system_monitor(),
  {ok, {}}.

handle_call(_Request, _From, State) ->
  {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info({monitor, PidOrPort, EventKind, Info}, State) ->
  ReferenceData = data_for_reference(PidOrPort),
  InfoTxt = format_system_event_info(Info),
  ?LOG_INFO( "sysmon type=~p reference=~p~n~s~n~s"
           , [EventKind, PidOrPort, InfoTxt, ReferenceData]
           , #{domain => [system_monitor]}
           ),
  case application:get_env(?APP, external_monitoring) of
    {ok, Mod} -> Mod:system_monitor_event(EventKind, Info);
    undefined -> ok
  end,
  {noreply, State};
handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

%%==============================================================================
%% Internal functions
%%==============================================================================

%%--------------------------------------------------------------------
%% @doc: Set the current process as the receiver of the BEAM system
%%       events
%%--------------------------------------------------------------------
-spec setup_system_monitor() -> ok.
setup_system_monitor() ->
  {ok, Opts} = application:get_env(?APP, beam_events),
  erlang:system_monitor(self(), Opts),
  ok.

data_for_reference(Proc) when is_pid(Proc) orelse is_atom(Proc) ->
  case system_monitor:get_proc_info(Proc) of
    false      -> "Proc not in top";
    ProcErlTop -> system_monitor:erl_top_to_str(ProcErlTop)
  end;
data_for_reference(_Port) ->
  "".

-spec format_system_event_info(term()) -> io_lib:chars().
format_system_event_info(Info) when is_list(Info) ->
  lists:foldl(
    fun({Key, Value}, Acc) ->
        [io_lib:format("~p=~p ", [Key, Value])|Acc];
       (Value, Acc) ->
        [io_lib:format("~p ", [Value])|Acc]
    end,
    [],
    Info);
format_system_event_info(Port) when is_port(Port) ->
  format_system_event_info([{port, Port}]);
format_system_event_info(Pid) when is_pid(Pid) ->
  format_system_event_info([{pid_2, Pid}]);
format_system_event_info(Term) ->
  format_system_event_info([{info, Term}]).

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
