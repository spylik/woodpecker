PROJECT = woodpecker

TEST_ERLC_OPTS += +warn_export_vars +warn_shadow_vars +warn_obsolete_guard +debug_info
TEST_ERLC_OPTS += +'{parse_transform, lager_transform}'

#ERLC_OPTS += +warn_export_vars +warn_shadow_vars +warn_obsolete_guard +warn_missing_spec #-Werror

# --------------------------------------------------------------------
# Dependencies.
# --------------------------------------------------------------------

# if we part of deps directory, we using $(CURDIR)../ as DEPS_DIR
ifeq ($(shell basename $(shell dirname $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST)))))), deps)
    DEPS_DIR ?= $(shell dirname $(CURDIR))
endif

# our deps
dep_teaser = git https://github.com/spylik/teaser master
dep_erlroute = git https://github.com/spylik/erlroute master

# 3-rd party deps
dep_gun = git https://github.com/ninenines/gun master
dep_cowboy = git https://github.com/ninenines/cowboy master

DEPS = gun
TEST_DEPS = cowboy teaser lager erlroute
SHELL_DEPS = sync

ifeq ($(USER),travis)
    ERLC_OPTS += +warn_export_vars +warn_shadow_vars +warn_obsolete_guard +warn_missing_spec -Werror
    TEST_DEPS += covertool
    dep_covertool = git https://github.com/idubrov/covertool
endif

# --------------------------------------------------------------------
# Development enviroment ("make shell" to run it).
# --------------------------------------------------------------------

SHELL_OPTS = -config deps/teaser/sys.config +c true +C multi_time_warp -pa ebin/ test/ -eval 'lager:start(), mlibs:discover()' -env ERL_LIBS deps -run mlibs autotest_on_compile

# --------------------------------------------------------------------
# We using erlang.mk 
# --------------------------------------------------------------------

include erlang.mk
