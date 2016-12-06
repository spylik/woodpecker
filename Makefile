PROJECT = woodpecker

# --------------------------------------------------------------------
# Compilation.
# --------------------------------------------------------------------

# if ERLC_OPTS not defined in parent project, we going to define by our-self
ERLC_OPTS ?= +warn_export_all +warn_export_vars +warn_unused_import +warn_untyped_record +warn_missing_spec +warn_missing_spec_all -Werror

TEST_ERLC_OPTS += +'{parse_transform, lager_transform}' 
TEST_ERLC_OPTS += +'{parse_transform, erlroute_transform}'

# --------------------------------------------------------------------
# Dependencies.
# --------------------------------------------------------------------

# if we part of deps directory, we using $(CURDIR)../ as DEPS_DIR
ifeq ($(shell basename $(shell dirname $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST)))))), deps)
    DEPS_DIR ?= $(shell dirname $(CURDIR))
endif

DEPS 		= gun
TEST_DEPS	= cowboy teaser lager erlroute
SHELL_DEPS	= sync

# our deps
dep_teaser 		= git https://github.com/spylik/teaser 		master
dep_erlroute 	= git https://github.com/spylik/erlroute	master
# 3-rd party deps
dep_gun 		= git https://github.com/ninenines/gun		master
dep_cowboy 		= git https://github.com/ninenines/cowboy	master

# use with travis
ifeq ($(USER),travis)
    TEST_DEPS += covertool
    dep_covertool = git https://github.com/idubrov/covertool
endif

# use with jenkins
ifeq ($(USER),jenkins)
    TEST_DEPS += covertool
    dep_covertool = git https://github.com/idubrov/covertool
endif


# --------------------------------------------------------------------
# Development enviroment ("make shell" to run it).
# --------------------------------------------------------------------

SHELL_OPTS = -config ${DEPS_DIR}/teaser/sys.config +c true +C multi_time_warp -pa ebin/ test/ -eval 'lager:start(), mlibs:discover()' -env ERL_LIBS deps -run mlibs autotest_on_compile

# --------------------------------------------------------------------
# We using erlang.mk 
# --------------------------------------------------------------------

include erlang.mk
