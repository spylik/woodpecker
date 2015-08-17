PROJECT = woodpecker

ERLC_COMPILE_OPTS= "+{parse_transform, lager_transform}"

DEPS = lager gun

dep_lager = git https://github.com/basho/lager master
dep_gun = git https://github.com/ninenines/gun master

include erlang.mk
