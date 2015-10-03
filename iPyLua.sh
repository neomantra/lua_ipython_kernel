#!/bin/bash
how=$1
if [[ -z $how ]]; then how="console"; fi
ipython $how --profile=iPyLua --colors=Linux
pid=$(pgrep -f "lua5.2 .*iPyLua/iPyLuaKernel")
if [[ ! -z $pid ]]; then kill -9 $pid; fi
