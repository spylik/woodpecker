PROJECT = woodpecker

#ERLC_COMPILE_OPTS= "+{parse_transform, lager_transform}"

dep_teaser = git https://github.com/spylik/teaser develop

SHELL_DEPS = sync teaser lager

DEPS = gun

dep_gun = git https://github.com/ninenines/gun master

SHELL_OPTS = +c true +C multi_time_warp -pa ebin/ test/ -eval 'lager:start(), mlibs:discover()' -env ERL_LIBS deps -run mlibs autotest_on_compile

include erlang.mk
