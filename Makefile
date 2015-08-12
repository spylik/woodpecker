PROJECT = woodpecker

ERLC_COMPILE_OPTS= "+{parse_transform, lager_transform}"
ERLC_OPTS += $(ERLC_COMPILE_OPTS)
TEST_ERLC_OPTS += $(ERLC_COMPILE_OPTS)

DEPS = gun poolboy

dep_gun = git https://github.com/ninenines/gun master
dep_poolboy = git https://github.com/devinus/poolboy master

include erlang.mk
