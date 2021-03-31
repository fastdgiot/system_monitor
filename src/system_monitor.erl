%% -*- erlang-indent-level: 2 -*-
%%%-------------------------------------------------------------------
%%% File    : system_monitor.erl
%%% Description : Monitor for some system parameters.
%%%
%%% Created : 20 Dec 2011 by Thomas Jarvstrand <>
%%%-------------------------------------------------------------------
%% @private
-module(system_monitor).

-behaviour(gen_server).

%%--------------------------------------------------------------------
%% Include files
%%--------------------------------------------------------------------

-include_lib("system_monitor/include/system_monitor.hrl").

-include_lib("hut/include/hut.hrl").

%% API
-export([start_link/0]).

-export([reset/0]).

-export([ report_full_status/1
        , check_process_count/0
        , self_monitor/0
        , suspect_procs/0
        , erl_top_to_str/1
        , start_top/0
        , stop_top/0
        ]).

%% gen_server callbacks
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        ]).

-include_lib("hut/include/hut.hrl").

-define(SERVER, ?MODULE).
-define(TICK_INTERVAL, 1000).

-record(state, { monitors = []
               , timer_ref
               , callback_state = []
               }).

%% System monitor is started early, some application may be
%% unavalable
-define(MAYBE(Prog), try Prog catch _:_ -> undefined end).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% @doc Starts the server
%%--------------------------------------------------------------------
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() -> gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%--------------------------------------------------------------------
%% @doc Start printing erlang top to console
%%--------------------------------------------------------------------
-spec start_top() -> ok.
start_top() ->
  application:set_env(?APP, top_printing, group_leader()).

%%--------------------------------------------------------------------
%% @doc Stop printing erlang top to console
%%--------------------------------------------------------------------
-spec stop_top() -> ok.
stop_top() ->
  application:set_env(?APP, top_printing, false).

%%--------------------------------------------------------------------
%% @doc Reset monitors
%%--------------------------------------------------------------------
-spec reset() -> ok.
reset() ->
  gen_server:cast(?SERVER, reset).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
  {ok, Timer} = timer:send_interval(?TICK_INTERVAL, {self(), tick}),
  CallbackState = system_monitor_callback:start(),
  {ok, #state{ monitors = init_monitors(CallbackState)
             , timer_ref = Timer
             , callback_state = CallbackState
             }}.

handle_call(_Request, _From, State) ->
  {reply, {error, unknown_call}, State}.

handle_cast(reset, #state{callback_state = CallbackState} = State) ->
  {noreply, State#state{monitors = init_monitors(CallbackState)}};
handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info({Self, tick}, State) when Self =:= self() ->
  Monitors = [case Ticks - 1 of
                0 ->
                  try
                    apply(Module, Function, Args)
                  catch
                    EC:Error:Stack ->
                      error_logger:warning_msg(
                        "system_monitor ~p crashed:~n~p:~p~nStacktrace: ~p~n",
                        [{Module, Function}, EC, Error, Stack])
                  end,
                  {Module, Function, Args, Bool, TicksReset, TicksReset};
                TicksDecremented ->
                  {Module, Function, Args, Bool, TicksReset, TicksDecremented}
              end || {Module, Function, Args,
                      Bool, TicksReset, Ticks} <- State#state.monitors],
  {noreply, State#state{monitors = Monitors}};
handle_info(_Info, State) ->
  {noreply, State}.

-spec terminate(term(), #state{}) -> any().
terminate(_Reason, State) ->
  %% Possibly, one last check.
  [apply(?MODULE, Monitor, []) ||
    {Monitor, true, _TicksReset, _Ticks} <- State#state.monitors].

%%==============================================================================
%% Internal functions
%%==============================================================================

%%------------------------------------------------------------------------------
%% @doc Returns the list of initiated monitors.
%%------------------------------------------------------------------------------
-spec init_monitors(any()) -> [{module(), function(), any(), boolean(),
                                       pos_integer(), pos_integer()}].
init_monitors(CallbackState) ->
  [{Module, Function, Args, Bool, Ticks, Ticks} ||
    {Module, Function, Args, Bool, Ticks} <- monitors(CallbackState)].

%%------------------------------------------------------------------------------
%% @doc Returns the list of monitors. The format is
%%      {FunctionName, RunMonitorAtTerminate, NumberOfTicks}.
%%      RunMonitorAtTerminate determines whether the monitor is to be run in
%%      the terminate gen_server callback.
%%      ... and NumberOfTicks is the number of ticks between invocations of
%%      the monitor in question. So, if NumberOfTicks is 3600, the monitor is
%%      to be run once every hour, as there is a tick every second.
%%------------------------------------------------------------------------------
-spec monitors(any()) -> [{module(), function(), any(), boolean(), pos_integer()}].
monitors(CallbackState) ->
  {ok, AdditionalMonitors} = application:get_env(system_monitor, status_checks),
  {ok, TopInterval} = application:get_env(?APP, top_sample_interval),
  [{?MODULE, check_process_count, [], true, 2},
   {?MODULE, self_monitor, [], false, 5},
   {?MODULE, suspect_procs, [], true, 5},
   {?MODULE, report_full_status, [CallbackState], false, TopInterval div 1000}]
  ++ AdditionalMonitors.

%%------------------------------------------------------------------------------
%% @doc
%% Monitor mailbox size of system_monitor_kafka process
%%
%% Check message queue length of this process and kill it when it's growing
%% uncontrollably. It is needed because this process doesn't have backpressure
%% by design
%% @end
%%------------------------------------------------------------------------------
self_monitor() ->
  message_queue_sentinel(system_monitor_kafka, 3000).

-spec message_queue_sentinel(atom() | pid(), integer()) -> ok.
message_queue_sentinel(Name, Limit) when is_atom(Name) ->
  case whereis(Name) of
    Pid when is_pid(Pid) ->
      message_queue_sentinel(Pid, Limit);
    _ ->
      ok
  end;
message_queue_sentinel(Pid, Limit) when is_pid(Pid) ->
  case process_info(Pid, [message_queue_len, current_function]) of
    [{message_queue_len, Len}, {current_function, Fun}] when Len >= Limit ->
      ?log( warning
          , "Abnormal message queue length (~p). "
            "Process ~p (~p) will be terminated."
          , [Len, Pid, Fun]
          , #{domain => [system_monitor]}
          ),
      exit(Pid, kill);
    _ ->
      ok
  end.

%%------------------------------------------------------------------------------
%% Monitor for number of processes
%%------------------------------------------------------------------------------

%%------------------------------------------------------------------------------
%% @doc Check the number of processes and log an aggregate summary of the
%%      process info if the count is above Threshold.
%%------------------------------------------------------------------------------
-spec check_process_count() -> ok.
check_process_count() ->
  {ok, MaxProcs} = application:get_env(?APP, top_max_procs),
  case erlang:system_info(process_count) of
    Count when Count > MaxProcs div 5 ->
      ?log( warning
          , "Abnormal process count (~p).~n"
          , [Count]
          , #{domain => [system_monitor]}
          );
    _ -> ok
  end.


%%------------------------------------------------------------------------------
%% Monitor for processes with suspect stats
%%------------------------------------------------------------------------------
suspect_procs() ->
  {_TS, ProcTop} = system_monitor_top:get_proc_top(),
  Env = fun(Name) -> application:get_env(?APP, Name, undefined) end,
  Conf =
    {Env(suspect_procs_max_memory),
     Env(suspect_procs_max_message_queue_len),
     Env(suspect_procs_max_total_heap_size)},
  SuspectProcs = lists:filter(fun(Proc) -> is_suspect_proc(Proc, Conf) end, ProcTop),
  lists:foreach(fun log_suspect_proc/1, SuspectProcs).

is_suspect_proc(Proc, {MaxMemory, MaxMqLen, MaxTotalHeapSize}) ->
  #erl_top{memory = Memory,
           message_queue_len = MessageQueueLen,
           total_heap_size = TotalHeapSize} =
    Proc,
  GreaterIfDef =
    fun ({undefined, _}) ->
          false;
        ({Comp, Value}) ->
          Value >= Comp
    end,
  ToCompare =
    [{MaxMemory, Memory}, {MaxMqLen, MessageQueueLen}, {MaxTotalHeapSize, TotalHeapSize}],
  lists:any(GreaterIfDef, ToCompare).

log_suspect_proc(Proc) ->
  ErlTopStr = erl_top_to_str(Proc),
  Format = "Suspect Proc~n~s",
  ?log(warning, Format, [ErlTopStr], #{domain => [system_monitor]}).

%%------------------------------------------------------------------------------
%% @doc Report top processes
%%------------------------------------------------------------------------------
-spec report_full_status(any()) -> ok.
report_full_status(CallbackState) ->
  %% `TS' variable should be used consistently in all following
  %% reports for this time interval, so it can be used as a key to
  %% lookup the relevant events
  {TS, ProcTop} = system_monitor_top:get_proc_top(),
  system_monitor_callback:produce(ProcTop, CallbackState),
  report_app_top(TS, CallbackState),
  %% Node status report goes last, and it "seals" the report for this
  %% time interval:
  NodeReport =
    case application:get_env(?APP, node_status_fun) of
      {ok, {Module, Function}} ->
        try Module:Function()
        catch _:_ -> <<>> end;
      _ ->
        <<>>
    end,
  system_monitor_callback:produce([{node_role, node(), TS, iolist_to_binary(NodeReport)}], CallbackState).

%%------------------------------------------------------------------------------
%% @doc Calculate reductions per application.
%%------------------------------------------------------------------------------
-spec report_app_top(erlang:timestamp(), any()) -> ok.
report_app_top(TS, CallbackState) ->
  AppReds  = system_monitor_top:get_abs_app_top(),
  present_results(app_top, reductions, AppReds, TS, CallbackState),
  AppMem   = system_monitor_top:get_app_memory(),
  present_results(app_top, memory, AppMem, TS, CallbackState),
  AppProcs = system_monitor_top:get_app_processes(),
  present_results(app_top, processes, AppProcs, TS, CallbackState),
  #{ current_function := CurrentFunction
   , initial_call := InitialCall
   } = system_monitor_top:get_function_top(),
  present_results(fun_top, current_function, CurrentFunction, TS, CallbackState),
  present_results(fun_top, initial_call, InitialCall, TS, CallbackState),
  ok.

%%--------------------------------------------------------------------
%% @doc Push app_top or fun_top information to kafka
%%--------------------------------------------------------------------
present_results(Record, Tag, Values, TS, CallbackState) ->
  {ok, Thresholds} = application:get_env(?APP, top_significance_threshold),
  Threshold = maps:get(Tag, Thresholds, 0),
  Node = node(),
  L = lists:filtermap(fun ({Key, Val}) when Val > Threshold ->
                            {true, {Record, Node, TS, Key, Tag, Val}};
                          (_) ->
                            false
                      end,
                      Values),
  system_monitor_callback:produce(L, CallbackState).

%%--------------------------------------------------------------------
%% @doc logs "the interesting parts" of erl_top
%%--------------------------------------------------------------------
erl_top_to_str(Proc) ->
  #erl_top{registered_name = RegisteredName,
           pid = Pid,
           initial_call = InitialCall,
           memory = Memory,
           message_queue_len = MessageQueueLength,
           stack_size = StackSize,
           heap_size = HeapSize,
           total_heap_size = TotalHeapSize,
           current_function = CurrentFunction,
           current_stacktrace = CurrentStack} =
    Proc,
  WordSize = erlang:system_info(wordsize),
  Format =
    "registered_name=~p~n"
    "offending_pid=~s~n"
    "initial_call=~s~n"
    "memory=~p (~s)~n"
    "message_queue_len=~p~n"
    "stack_size=~p~n"
    "heap_size=~p (~s)~n"
    "total_heap_size=~p (~s)~n"
    "current_function=~s~n"
    "current_stack:~n~s",
  Args =
    [RegisteredName,
     Pid,
     fmt_mfa(InitialCall),
     Memory, fmt_mem(Memory),
     MessageQueueLength,
     StackSize,
     HeapSize, fmt_mem(WordSize * HeapSize),
     TotalHeapSize, fmt_mem(WordSize * TotalHeapSize),
     fmt_mfa(CurrentFunction),
     fmt_stack(CurrentStack)],
  io_lib:format(Format, Args).

fmt_mem(Mem) ->
  Units = [{1, "Bytes"}, {1024, "KB"}, {1024 * 1024, "MB"}, {1024 * 1024 * 1024, "GB"}],
  MemIsSmallEnough = fun({Dividor, _UnitStr}) -> Mem =< Dividor * 1024 end,
  {Dividor, UnitStr} =
    find_first(MemIsSmallEnough, Units, {1024 * 1024 * 1024 * 1024, "TB"}),
  io_lib:format("~.1f ~s", [Mem / Dividor, UnitStr]).

fmt_stack(CurrentStack) ->
  [[fmt_mfa(MFA), "\n"] || MFA <- CurrentStack].

fmt_mfa({Mod, Fun, Arity, Prop}) ->
  case proplists:get_value(line, Prop, undefined) of
    undefined ->
      fmt_mfa({Mod, Fun, Arity});
    Line ->
      io_lib:format("~s:~s/~p (Line ~p)", [Mod, Fun, Arity, Line])
  end;
fmt_mfa({Mod, Fun, Arity}) ->
  io_lib:format("~s:~s/~p", [Mod, Fun, Arity]);
fmt_mfa(L) ->
  io_lib:format("~p", [L]).

-spec find_first(fun((any()) -> boolean()), [T], Default) -> T | Default.
find_first(Pred, List, Default) ->
  case lists:search(Pred, List) of
    {value, Elem} -> Elem;
    false -> Default
  end.
