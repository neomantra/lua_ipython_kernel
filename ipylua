#!/bin/bash
how=$1
if [[ -z $how ]]; then how="console"; fi
ipython $how --profile=IPyLua --colors=Linux --ConsoleWidget.font_size=12
pid=$(pgrep -f "lua5.2.*profile_IPyLua.*")
if [[ ! -z $pid ]]; then kill -9 $pid; fi
