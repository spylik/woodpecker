PROJECT = woodpecker

ERLC_COMPILE_OPTS= "+{parse_transform, lager_transform}"

DEPS = gun

dep_gun = git https://github.com/ninenines/gun master

include erlang.mk
