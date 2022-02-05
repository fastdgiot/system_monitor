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
-ifndef(SYSTEM_MONITOR_HRL).
-define(SYSTEM_MONITOR_HRL, true).

-define(APP, system_monitor).

-type function_top() :: [{mfa(), number()}].

-record(erl_top,
        { node                :: node()
        , ts                  :: integer()
        , pid                 :: string()
        , dreductions         :: integer()
        , dmemory             :: integer()
        , reductions          :: integer()
        , memory              :: integer() %% bytes
        , message_queue_len   :: integer()
        , current_function    :: mfa()
        , initial_call        :: mfa()
        , registered_name     :: atom() | []
        , stack_size          :: integer()
        , heap_size           :: integer() %% words
        , total_heap_size     :: integer() %% words
        , current_stacktrace  :: list()
        , group_leader        :: string()
        }).

-record(app_top,
        { app                 :: atom()
        , red_abs             :: integer()
        , red_rel             :: float()
        , memory              :: integer()
        , processes           :: integer()
        }).

-endif.
