PROJECT = woodpecker

TEST_ERLC_OPTS += +warn_export_vars +warn_shadow_vars +warn_obsolete_guard +debug_info
TEST_ERLC_OPTS += +'{parse_transform, lager_transform}'

ERLC_OPTS += +warn_export_vars +warn_shadow_vars +warn_obsolete_guard +warn_missing_spec #-Werror

dep_gun = git https://github.com/ninenines/gun master
dep_teaser = git https://github.com/spylik/teaser master
dep_cowboy = git https://github.com/ninenines/cowboy master

DEPS = gun
TEST_DEPS = cowboy teaser lager
SHELL_DEPS = sync

ifeq ($(USER),travis)
    ERLC_OPTS += +warn_export_vars +warn_shadow_vars +warn_obsolete_guard +warn_missing_spec -Werror
    TEST_DEPS += covertool
    dep_covertool = git https://github.com/idubrov/covertool
endif

SHELL_OPTS = -config deps/teaser/sys.config +c true +C multi_time_warp -pa ebin/ test/ -eval 'lager:start(), mlibs:discover()' -env ERL_LIBS deps -run mlibs autotest_on_compile

include erlang.mk
